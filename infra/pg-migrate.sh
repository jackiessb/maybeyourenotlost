#!/usr/bin/env bash
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

# MODE=data-only (default, non-destructive) or MODE=clean (drops and recreates objects)
cmd_restore() {
  local mode="${MODE:-data-only}" flags
  case "$mode" in
    data-only) flags="--data-only" ;;
    clean)     flags="--clean --if-exists" ;;
    *) die "MODE must be data-only or clean" ;;
  esac

  warn "restoring with $flags (MODE=$mode)"
  [[ "$mode" == clean ]] && warn "this DROPS existing objects in the target databases"

  local role token
  role=$(pg_role_for "$NEW_SUB" "$NEW_RG" "$NEW_SRV")
  token=$(token_for "$NEW_SUB")
  for db in "${DBS[@]}"; do
    [[ -f "$OUT/$db.dump" ]] || die "missing $OUT/$db.dump -- run '$0 dump' first"
    say "restoring $db into $NEW_SRV (as $role)"
    # --no-owner/--no-privileges: role names differ between subscriptions.
    # Not --exit-on-error: a data-only restore reports benign per-table noise, and
    # the row counts below are the real signal.
    pg "$token" pg_restore -h "$NEW_SRV.postgres.database.azure.com" \
      -U "$role" -d "$db" --no-owner --no-privileges $flags -v "/out/$db.dump" \
      2>&1 | grep -iE 'error|warning|already exists' | head -20 || true
  done

  say "verifying row counts landed"
  for db in "${DBS[@]}"; do
    printf '  %-14s ' "$db:"
    pg "$token" psql -h "$NEW_SRV.postgres.database.azure.com" \
      -U "$role" -d "$db" -At -c "
        select coalesce(string_agg(relname || '=' || n_live_tup, ', ' order by relname), '(none)')
        from pg_stat_user_tables;"
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
  cleanup) cmd_cleanup ;;
  *) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
