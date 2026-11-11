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
# Three things make this more awkward than a normal dump/restore, all discovered
# the hard way:
#
#  1. Both servers are Entra-only -- passwordAuth is Disabled -- so the password is
#     a short-lived access token, not a secret.
#  2. The servers trust *different tenants*. The old one only accepts tokens from
#     e22c9007 (memjkt@gmail.com); the new one only from aac88807
#     (jackson@maybeyourenotlost.com). Each token must be minted under the matching
#     `az account` context, so this script switches contexts rather than assuming one.
#  3. Out of the box neither server has a *human* Entra admin -- only the APIs'
#     managed identities -- so no user can connect at all until `prereqs` runs.
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

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }

# Dumps contain real submissions and contact phone numbers. Keep them local.
mkdir -p "$OUT"
chmod 700 "$OUT"

# Run psql/pg_dump/pg_restore in a container. The token arrives via PGPASSWORD in
# the environment rather than on the command line, so it stays out of `ps` output.
pg() {
  local token="$1"; shift
  docker run --rm -i \
    -e PGPASSWORD="$token" \
    -e PGSSLMODE=require \
    -v "$OUT:/out" \
    "$IMAGE" "$@"
}

# Switch az context and echo back a token for that tenant's servers.
token_for() {
  local sub="$1"
  az account set --subscription "$sub"
  az account get-access-token --resource "$PG_RESOURCE" --query accessToken -o tsv
}

upn_for() {
  local sub="$1"
  az account set --subscription "$sub"
  az ad signed-in-user show --query userPrincipalName -o tsv
}

my_ip() { curl -fsS https://api.ipify.org; }

cmd_prereqs() {
  local ip; ip=$(my_ip)
  say "opening the firewall for $ip on both servers"
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  az postgres flexible-server firewall-rule create --subscription "$OLD_SUB" \
    -g "$OLD_RG" -s "$OLD_SRV" -n "pgmigrate-$stamp" \
    --start-ip-address "$ip" --end-ip-address "$ip" -o none
  az postgres flexible-server firewall-rule create --subscription "$NEW_SUB" \
    -g "$NEW_RG" -s "$NEW_SRV" -n "pgmigrate-$stamp" \
    --start-ip-address "$ip" --end-ip-address "$ip" -o none

  # Without this no human can log in: both servers list only the APIs' managed
  # identities as Entra admins, and password auth is disabled.
  say "granting Entra admin on the OLD server (tenant e22c9007)"
  az account set --subscription "$OLD_SUB"
  local old_id old_upn
  old_id=$(az ad signed-in-user show --query id -o tsv)
  old_upn=$(az ad signed-in-user show --query userPrincipalName -o tsv)
  warn "as $old_upn ($old_id)"
  az postgres flexible-server microsoft-entra-admin create \
    --subscription "$OLD_SUB" -g "$OLD_RG" -s "$OLD_SRV" \
    --object-id "$old_id" --display-name "$old_upn" --type User -o none

  say "granting Entra admin on the NEW server (tenant aac88807)"
  az account set --subscription "$NEW_SUB"
  local new_id new_upn
  new_id=$(az ad signed-in-user show --query id -o tsv)
  new_upn=$(az ad signed-in-user show --query userPrincipalName -o tsv)
  warn "as $new_upn ($new_id)"
  az postgres flexible-server microsoft-entra-admin create \
    --subscription "$NEW_SUB" -g "$NEW_RG" -s "$NEW_SRV" \
    --object-id "$new_id" --display-name "$new_upn" --type User -o none

  say "done -- both servers now reachable and admin-able by you"
  warn "run '$0 cleanup' when finished to revoke both grants"
}

# Row counts plus the EF migration each database is on. The migration comparison is
# the thing that decides how 'restore' has to work: the new databases are NOT empty,
# because both APIs applied InitialCreate on first start.
cmd_inspect() {
  local q="
    select 'rows: ' || coalesce(string_agg(relname || '=' || n_live_tup, ', ' order by relname), '(none)')
    from pg_stat_user_tables;
    select 'migrations: ' || coalesce(string_agg(\"MigrationId\", ', ' order by \"MigrationId\"), '(none)')
    from \"__EFMigrationsHistory\";"

  local old_token new_token old_upn new_upn
  old_upn=$(upn_for "$OLD_SUB"); old_token=$(token_for "$OLD_SUB")
  for db in "${DBS[@]}"; do
    say "OLD $OLD_SRV / $db"
    pg "$old_token" psql -h "$OLD_SRV.postgres.database.azure.com" \
      -U "$old_upn" -d "$db" -At -c "$q"
  done

  new_upn=$(upn_for "$NEW_SUB"); new_token=$(token_for "$NEW_SUB")
  for db in "${DBS[@]}"; do
    say "NEW $NEW_SRV / $db"
    pg "$new_token" psql -h "$NEW_SRV.postgres.database.azure.com" \
      -U "$new_upn" -d "$db" -At -c "$q"
  done

  say "compare the migration lists above"
  warn "identical  -> 'restore' can use --data-only, the least destructive option"
  warn "different  -> use --clean --if-exists so the dump's own schema wins"
}

cmd_dump() {
  local upn token
  upn=$(upn_for "$OLD_SUB"); token=$(token_for "$OLD_SUB")
  for db in "${DBS[@]}"; do
    say "dumping $db from $OLD_SRV"
    # -Fc custom format so 'restore' can choose --data-only vs --clean later without
    # re-dumping. Single-threaded: the source B1ms caps at 50 connections.
    pg "$token" pg_dump -h "$OLD_SRV.postgres.database.azure.com" \
      -U "$upn" -d "$db" --no-owner --no-privileges -Fc -f "/out/$db.dump"
    ls -lh "$OUT/$db.dump"
  done
  say "dumps written to $OUT"
  warn "these contain real submissions and phone numbers -- do not commit them"
}

# MODE=data-only (default, non-destructive) or MODE=clean (drops and recreates objects)
cmd_restore() {
  local mode="${MODE:-data-only}"
  local flags
  case "$mode" in
    data-only) flags="--data-only" ;;
    clean)     flags="--clean --if-exists" ;;
    *) echo "MODE must be data-only or clean" >&2; exit 2 ;;
  esac

  warn "restoring with $flags (MODE=$mode)"
  [[ "$mode" == clean ]] && warn "this DROPS existing objects in the target databases"

  local upn token
  upn=$(upn_for "$NEW_SUB"); token=$(token_for "$NEW_SUB")
  for db in "${DBS[@]}"; do
    [[ -f "$OUT/$db.dump" ]] || { echo "missing $OUT/$db.dump -- run 'dump' first" >&2; exit 1; }
    say "restoring $db into $NEW_SRV"
    # --no-owner/--no-privileges: role names differ between subscriptions.
    # Not --exit-on-error: a data-only restore reports benign conflicts per table
    # and the summary below is the real signal.
    pg "$token" pg_restore -h "$NEW_SRV.postgres.database.azure.com" \
      -U "$upn" -d "$db" --no-owner --no-privileges $flags -v "/out/$db.dump" \
      2>&1 | grep -iE 'error|warning|already exists' | head -20 || true
  done

  say "verifying row counts landed"
  for db in "${DBS[@]}"; do
    printf '  %s: ' "$db"
    pg "$token" psql -h "$NEW_SRV.postgres.database.azure.com" \
      -U "$upn" -d "$db" -At -c "
        select coalesce(string_agg(relname || '=' || n_live_tup, ', ' order by relname), '(none)')
        from pg_stat_user_tables;"
  done
}

cmd_cleanup() {
  say "revoking Entra admins"
  az account set --subscription "$OLD_SUB"
  local old_id; old_id=$(az ad signed-in-user show --query id -o tsv)
  az postgres flexible-server microsoft-entra-admin delete --subscription "$OLD_SUB" \
    -g "$OLD_RG" -s "$OLD_SRV" --object-id "$old_id" --yes -o none || true
  az account set --subscription "$NEW_SUB"
  local new_id; new_id=$(az ad signed-in-user show --query id -o tsv)
  az postgres flexible-server microsoft-entra-admin delete --subscription "$NEW_SUB" \
    -g "$NEW_RG" -s "$NEW_SRV" --object-id "$new_id" --yes -o none || true

  say "removing pgmigrate-* and rehearsal-* firewall rules"
  for spec in "$OLD_SUB:$OLD_RG:$OLD_SRV" "$NEW_SUB:$NEW_RG:$NEW_SRV"; do
    IFS=: read -r sub rg srv <<<"$spec"
    az postgres flexible-server firewall-rule list --subscription "$sub" \
      -g "$rg" -s "$srv" --query "[?starts_with(name,'pgmigrate-') || starts_with(name,'rehearsal-')].name" -o tsv \
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
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
