#!/usr/bin/env bash
#
# RETIRED -- kept for the record, not runnable.
#
# The source this script reads from no longer exists: postgres-yudlalf6hmivo and the
# old subscription's rg-dev / rg-dev-b were deleted at the end of the migration
# (step 22). Every phase below that touches OLD_* will fail on a missing resource.
#
# It is kept because the constraints it encodes were expensive to discover and apply to
# any future cross-tenant Postgres move: Entra-only servers need a token as the
# password, a *human* Entra admin has to be granted before any user can connect at all,
# two servers in different tenants need their tokens minted per subscription, a B2B
# guest's Postgres role name is the mangled `#EXT#` form so it must be read back from
# the server rather than guessed, and a data-only restore needs the target truncated
# first and __EFMigrationsHistory excluded. See
# docs/plans/subscription-migration.md.
#
# Postgres dump/restore across the subscription migration.
#
# Used twice: once as a rehearsal while both stacks are live (Phase 4 step 8), and
# again for real during the cutover (Phase 5 steps 11-12). See
# docs/plans/subscription-migration.md.
#
#   ./infra/pg-migrate.sh prereqs    grant Entra admin + open the firewall, both servers
#   ./infra/pg-migrate.sh inspect    row counts and migration history on both servers
#   ./infra/pg-migrate.sh dump       pg_dump both databases out of the OLD server
#   ./infra/pg-migrate.sh restore    restore those dumps into the NEW server
#   ./infra/pg-migrate.sh verify     compare row counts on both servers, side by side
#   ./infra/pg-migrate.sh cleanup    revoke the Entra admins and firewall rules
#
# Run `prereqs` first. Without it every other phase fails on authentication, because
# out of the box neither server has a *human* Entra admin -- only the APIs' managed
# identities -- and `passwordAuth` is Disabled on both, so no user can connect at all.
#
# Two further things make this more awkward than a normal dump/restore:
#
#  1. Both servers are Entra-only, so the password is a short-lived access token
#     rather than a secret.
#  2. The servers trust *different tenants*. The old one accepts tokens only from
#     e22c9007 (memjkt@gmail.com, a B2B guest whose role name is the mangled
#     `..._gmail.com#EXT#@...onmicrosoft.com` form); the new one only from aac88807
#     (jackson@maybeyourenotlost.com). Tokens are therefore minted per subscription.
#
# Because that guest UPN is easy to get wrong by hand, connections do not guess it:
# the Postgres role name is read back from whatever `microsoft-entra-admin list`
# actually registered on each server.
#
# pg_dump/psql run in a postgres:16 container, which guarantees a client version
# matching both servers without installing anything.

set -euo pipefail

OLD_SUB=c1a7d305-fc17-4bba-a6a9-bcb3cad99751
OLD_RG=rg-dev                      # holds production until the RGs are renamed
OLD_SRV=postgres-yudlalf6hmivo

NEW_SUB=20aad6af-afbd-4c72-a48d-59ae01ca2cb2
NEW_RG=rg-prod
NEW_SRV=postgres-jcykdmvrxadbu

DBS=(encouragement contacts)
IMAGE=postgres:16
OUT="${PG_MIGRATE_OUT:-$(pwd)/.pg-migrate}"
PG_RESOURCE=https://ossrdbms-aad.database.windows.net

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

# `az ad signed-in-user show` takes no --subscription, so `prereqs` has to switch the
# CLI's active subscription to read the old tenant's identity. Leaving it switched is
# genuinely dangerous here -- any later command without an explicit --subscription
# would hit the *old production* subscription -- so always put it back.
ORIG_SUB="$(az account show --query id -o tsv 2>/dev/null || true)"
restore_sub() {
  [[ -n "$ORIG_SUB" ]] || return 0
  local now; now="$(az account show --query id -o tsv 2>/dev/null || true)"
  [[ "$now" == "$ORIG_SUB" ]] && return 0
  az account set --subscription "$ORIG_SUB" >/dev/null 2>&1 || true
  warn "restored active subscription to $ORIG_SUB"
}
trap restore_sub EXIT

# Dumps contain real submissions and contact phone numbers. Keep them local.
mkdir -p "$OUT"
chmod 700 "$OUT"

# Run psql/pg_dump/pg_restore in a container. The token arrives via PGPASSWORD in the
# environment rather than on the command line, so it stays out of `ps` output.
pg() {
  local token="$1"; shift
  docker run --rm -i \
    -e PGPASSWORD="$token" \
    -e PGSSLMODE=require \
    -v "$OUT:/out" \
    "$IMAGE" "$@"
}

# A token for the tenant that owns $1. --subscription avoids mutating the CLI context.
token_for() {
  az account get-access-token --subscription "$1" \
    --resource "$PG_RESOURCE" --query accessToken -o tsv
}

# The Postgres role name to log in as: whatever is registered as a *User* Entra admin
# on that server. Read back rather than derived, because the old tenant's account is a
# B2B guest and its role name is the `#EXT#` form, which is easy to mistype.
pg_role_for() {
  local sub="$1" rg="$2" srv="$3" name
  name=$(az postgres flexible-server microsoft-entra-admin list \
            --subscription "$sub" -g "$rg" -s "$srv" -o json 2>/dev/null \
         | python3 -c '
import sys, json
admins = json.load(sys.stdin)
users = [a for a in admins if (a.get("principalType") or "") == "User"]
print(users[0]["principalName"] if users else "")
' 2>/dev/null || true)
  [[ -n "$name" ]] || die "no human Entra admin on $srv -- run '$0 prereqs' first"
  printf '%s' "$name"
}

cmd_prereqs() {
  local ip stamp
  ip=$(curl -fsS https://api.ipify.org)
  stamp=$(date +%Y%m%d-%H%M%S)

  say "opening the firewall for $ip on both servers"
  az postgres flexible-server firewall-rule create --subscription "$OLD_SUB" \
    -g "$OLD_RG" -s "$OLD_SRV" -n "pgmigrate-$stamp" \
    --start-ip-address "$ip" --end-ip-address "$ip" -o none
  az postgres flexible-server firewall-rule create --subscription "$NEW_SUB" \
    -g "$NEW_RG" -s "$NEW_SRV" -n "pgmigrate-$stamp" \
    --start-ip-address "$ip" --end-ip-address "$ip" -o none

  local sub rg srv oid upn label
  for spec in "$OLD_SUB:$OLD_RG:$OLD_SRV:OLD (tenant e22c9007)" \
              "$NEW_SUB:$NEW_RG:$NEW_SRV:NEW (tenant aac88807)"; do
    IFS=: read -r sub rg srv label <<<"$spec"
    say "granting Entra admin on the $label server"

    # Switching context is unavoidable for `az ad signed-in-user`; the EXIT trap
    # puts it back even if the grant below fails.
    az account set --subscription "$sub"
    oid=$(az ad signed-in-user show --query id -o tsv)
    upn=$(az ad signed-in-user show --query userPrincipalName -o tsv)
    warn "as $upn"
    warn "object id $oid"

    az postgres flexible-server microsoft-entra-admin create \
      --subscription "$sub" -g "$rg" -s "$srv" \
      --object-id "$oid" --display-name "$upn" --type User -o none

    warn "registered role name: $(pg_role_for "$sub" "$rg" "$srv")"
  done

  restore_sub
  say "done -- both servers are now reachable and admin-able by you"
  warn "run '$0 cleanup' when finished to revoke both grants"
}

# Row counts plus the EF migration each database is on. The migration comparison is
# what decides how 'restore' has to work: the new databases are NOT empty, because
# both APIs applied InitialCreate on first start.
cmd_inspect() {
  local q="
    select 'rows:       ' || coalesce(string_agg(relname || '=' || n_live_tup, ', ' order by relname), '(none)')
    from pg_stat_user_tables;
    select 'migrations: ' || coalesce(string_agg(\"MigrationId\", ', ' order by \"MigrationId\"), '(none)')
    from \"__EFMigrationsHistory\";"

  local sub rg srv label role token
  for spec in "$OLD_SUB:$OLD_RG:$OLD_SRV:OLD" "$NEW_SUB:$NEW_RG:$NEW_SRV:NEW"; do
    IFS=: read -r sub rg srv label <<<"$spec"
    role=$(pg_role_for "$sub" "$rg" "$srv")
    token=$(token_for "$sub")
    for db in "${DBS[@]}"; do
      say "$label $srv / $db   (as $role)"
      pg "$token" psql -h "$srv.postgres.database.azure.com" \
        -U "$role" -d "$db" -At -c "$q"
    done
  done

  say "compare the migration lists above"
  warn "identical  -> 'restore' can use --data-only, the least destructive option"
  warn "different  -> MODE=clean, so the dump's own schema wins"
}

cmd_dump() {
  local role token
  role=$(pg_role_for "$OLD_SUB" "$OLD_RG" "$OLD_SRV")
  token=$(token_for "$OLD_SUB")
  for db in "${DBS[@]}"; do
    say "dumping $db from $OLD_SRV (as $role)"
    # -Fc custom format so 'restore' can choose --data-only vs --clean later without
    # re-dumping. Single-threaded: the source B1ms caps at 50 connections.
    pg "$token" pg_dump -h "$OLD_SRV.postgres.database.azure.com" \
      -U "$role" -d "$db" --no-owner --no-privileges -Fc -f "/out/$db.dump"
    ls -lh "$OUT/$db.dump"
  done
  say "dumps written to $OUT"
  warn "these contain real submissions and phone numbers -- do not commit them"
}

# MODE=data-only (default) keeps the EF-created schema and replaces the data.
# MODE=clean drops and recreates every object from the dump instead.
#
# Both are repeatable, and both discard whatever is currently in the target -- which is
# the point, since the target is a copy destination. Neither is safe to point at a
# database whose contents you want to keep.
cmd_restore() {
  local mode="${MODE:-data-only}" flags
  case "$mode" in
    data-only) flags="--data-only" ;;
    clean)     flags="--clean --if-exists" ;;
    *) die "MODE must be data-only or clean" ;;
  esac

  warn "restoring with $flags (MODE=$mode)"
  if [[ "$mode" == clean ]]; then
    warn "this DROPS and recreates every object in the target databases"
  else
    warn "this TRUNCATEs the target's tables first, then reloads them from the dump"
  fi

  local role token
  role=$(pg_role_for "$NEW_SUB" "$NEW_RG" "$NEW_SRV")
  token=$(token_for "$NEW_SUB")
  for db in "${DBS[@]}"; do
    [[ -f "$OUT/$db.dump" ]] || die "missing $OUT/$db.dump -- run '$0 dump' first"
    say "restoring $db into $NEW_SRV (as $role)"

    local toc_arg=()
    if [[ "$mode" == data-only ]]; then
      # A data-only restore is not idempotent: it assumes the target tables are
      # empty, so it works once and then fails every re-run on the primary key
      # ("Key (Id)=(1) already exists"). Clear the target's data first so the phase
      # can be run repeatedly -- during the rehearsal, and again at cutover when the
      # rehearsal's own data is still sitting there.
      #
      # CASCADE handles the foreign-key ordering. __EFMigrationsHistory is left alone
      # deliberately: it is EF's bookkeeping, the target's row is already correct, and
      # its data is excluded from the restore below.
      say "clearing existing data in $db (keeping the schema)"
      pg "$token" psql -h "$NEW_SRV.postgres.database.azure.com" \
        -U "$role" -d "$db" -v ON_ERROR_STOP=1 -q -c "
          do \$\$
          declare stmt text;
          begin
            select 'truncate table '
                   || string_agg(format('%I.%I', schemaname, relname), ', ')
                   || ' cascade'
              into stmt
              from pg_stat_user_tables
             where relname <> '__EFMigrationsHistory';
            if stmt is not null then
              execute stmt;
            end if;
          end \$\$;"

      # EF applied InitialCreate on the target when the API first started, so the
      # target's __EFMigrationsHistory already holds the row the dump also carries,
      # and COPY fails on its primary key. That row is identical bookkeeping, not
      # data, so skip just that one table's COPY via a filtered TOC. Everything else
      # restores normally and the error disappears rather than being tolerated.
      #
      # `inspect` is what justifies this: it only holds while both sides are on the
      # same migration. If they ever diverge, use MODE=clean instead.
      pg "$token" pg_restore -l "/out/$db.dump" > "$OUT/$db.toc"
      grep -v 'TABLE DATA.*__EFMigrationsHistory' "$OUT/$db.toc" > "$OUT/$db.toc.use"
      local skipped
      skipped=$(( $(wc -l < "$OUT/$db.toc") - $(wc -l < "$OUT/$db.toc.use") ))
      warn "excluded $skipped __EFMigrationsHistory TOC entry/entries"
      toc_arg=(-L "/out/$db.toc.use")
    fi

    # --no-owner/--no-privileges: role names differ between subscriptions.
    # --exit-on-error is safe now the one expected conflict is excluded, so a real
    # failure stops the run instead of scrolling past in a wall of output.
    pg "$token" pg_restore -h "$NEW_SRV.postgres.database.azure.com" \
      -U "$role" -d "$db" --no-owner --no-privileges --exit-on-error \
      $flags "${toc_arg[@]}" "/out/$db.dump"
    warn "$db restored with no errors"
  done

  cmd_verify
}

# Row counts from both servers side by side. This -- not pg_restore's exit code -- is
# the real success criterion for the cutover, and it is worth re-running after the
# final restore. Counts come from a live count(*) rather than pg_stat_user_tables,
# whose n_live_tup is an estimate that lags until autovacuum catches up and so can
# read as 0 on a freshly restored table.
cmd_verify() {
  local q="
    select string_agg(t || '=' || c, ', ' order by t) from (
      select relname as t,
             (xpath('/row/c/text()',
                    query_to_xml('select count(*) as c from ' || quote_ident(relname),
                                 false, true, '')))[1]::text::bigint as c
      from pg_stat_user_tables
      where relname <> '__EFMigrationsHistory'
    ) s;"

  local old_role new_role old_token new_token
  old_role=$(pg_role_for "$OLD_SUB" "$OLD_RG" "$OLD_SRV"); old_token=$(token_for "$OLD_SUB")
  new_role=$(pg_role_for "$NEW_SUB" "$NEW_RG" "$NEW_SRV"); new_token=$(token_for "$NEW_SUB")

  say "row counts, excluding __EFMigrationsHistory"
  local o n
  for db in "${DBS[@]}"; do
    o=$(pg "$old_token" psql -h "$OLD_SRV.postgres.database.azure.com" \
          -U "$old_role" -d "$db" -At -c "$q" | tr -d '\r')
    n=$(pg "$new_token" psql -h "$NEW_SRV.postgres.database.azure.com" \
          -U "$new_role" -d "$db" -At -c "$q" | tr -d '\r')
    printf '\n  %s\n    old: %s\n    new: %s\n' "$db" "${o:-(none)}" "${n:-(none)}"
    if [[ "$o" == "$n" ]]; then
      printf '    \033[1;32m-> match\033[0m\n'
    else
      printf '    \033[1;31m-> MISMATCH\033[0m\n'
    fi
  done

  # Identity sequences on the target. The restored rows carry explicit Id values, and
  # TRUNCATE does not reset the owning sequence -- pg_dump's setval entries are what
  # put it right. If one is left behind max(Id), the table looks perfect and then the
  # first insert after cutover fails on a duplicate key. Cheap to check, miserable to
  # debug later.
  local seq_q="
    select coalesce(string_agg(line, E'\n    ' order by line), '(no identity columns)') from (
      select t.relname || '.' || a.attname
             || '  seq=' || coalesce(ps.last_value::text, 'unset')
             || '  max=' || coalesce((xpath('/row/c/text()', query_to_xml(
                  format('select max(%I) as c from %I.%I', a.attname, n.nspname, t.relname),
                  false, true, '')))[1]::text, '0')
             || case
                  when coalesce((xpath('/row/c/text()', query_to_xml(
                         format('select max(%I) as c from %I.%I', a.attname, n.nspname, t.relname),
                         false, true, '')))[1]::text::bigint, 0) = 0 then '  (empty)'
                  when coalesce(ps.last_value, 0) >= coalesce((xpath('/row/c/text()', query_to_xml(
                         format('select max(%I) as c from %I.%I', a.attname, n.nspname, t.relname),
                         false, true, '')))[1]::text::bigint, 0) then '  OK'
                  else '  BEHIND -- next insert will collide'
                end as line
      from pg_class t
      join pg_namespace n on n.oid = t.relnamespace
      join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
      join pg_depend d on d.refobjid = t.oid and d.refobjsubid = a.attnum
                      and d.deptype in ('a','i')
      join pg_class sq on sq.oid = d.objid and sq.relkind = 'S'
      left join pg_sequences ps on ps.schemaname = n.nspname and ps.sequencename = sq.relname
      where t.relkind = 'r' and n.nspname = 'public'
    ) s;"

  say "identity sequences on the target"
  for db in "${DBS[@]}"; do
    printf '  %s\n    ' "$db"
    pg "$new_token" psql -h "$NEW_SRV.postgres.database.azure.com" \
      -U "$new_role" -d "$db" -At -c "$seq_q"
  done
}

cmd_cleanup() {
  local sub rg srv label oid
  for spec in "$OLD_SUB:$OLD_RG:$OLD_SRV:OLD" "$NEW_SUB:$NEW_RG:$NEW_SRV:NEW"; do
    IFS=: read -r sub rg srv label <<<"$spec"
    say "revoking Entra admin on the $label server"
    az account set --subscription "$sub"
    oid=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
    if [[ -n "$oid" ]]; then
      az postgres flexible-server microsoft-entra-admin delete --subscription "$sub" \
        -g "$rg" -s "$srv" --object-id "$oid" --yes -o none || true
    fi
  done
  restore_sub

  say "removing pgmigrate-* and rehearsal-* firewall rules"
  for spec in "$OLD_SUB:$OLD_RG:$OLD_SRV" "$NEW_SUB:$NEW_RG:$NEW_SRV"; do
    IFS=: read -r sub rg srv <<<"$spec"
    az postgres flexible-server firewall-rule list --subscription "$sub" \
      -g "$rg" -s "$srv" \
      --query "[?starts_with(name,'pgmigrate-') || starts_with(name,'rehearsal-')].name" -o tsv \
    | while read -r rule; do
        [[ -n "$rule" ]] || continue
        echo "    $srv: $rule"
        az postgres flexible-server firewall-rule delete --subscription "$sub" \
          -g "$rg" -s "$srv" -n "$rule" --yes -o none || true
      done
  done

  warn "dumps in $OUT are left in place -- delete them yourself when done"
}

case "${1:-}" in
  prereqs) cmd_prereqs ;;
  inspect) cmd_inspect ;;
  dump)    cmd_dump ;;
  restore) cmd_restore ;;
  verify)  cmd_verify ;;
  cleanup) cmd_cleanup ;;
  *) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
