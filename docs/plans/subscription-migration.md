# Plan: Migrating to the Microsoft 365 Tenant's Subscription

> **Status (2026-11-11). Phases 1-4 complete — ready for the Phase 5 cutover.** The
> full stack is up and verified in `Subscription 1` / `rg-prod`: Postgres `Ready` on
> GeneralPurpose `Standard_D2ds_v5` with both APIs connected by managed identity and
> their schemas migrated, all four container apps `Healthy`, and the dashboard
> enforcing Easy Auth against tenant `aac88807…`. Nothing is bound to a custom domain
> yet, by design.
>
> The dump/restore is rehearsed end to end and repeatable, with `Encouragements` 659
> and `Contacts` 371 matching on both servers; the rehearsal's grants and firewall
> rules have been cleaned up. Early sign-in validation is **deliberately skipped** —
> sign-in is tested after cutover.
>
> **The next action is step 11: the cutover.** It is the first user-visible step and the
> first that is not freely reversible. The live site and dashboard are still served
> entirely from the old subscription until then.
>
> **The working tree now holds only discardable edits** — the Postgres work is committed
> (`09c5e8e`, `deb5ebf`), so the earlier "stage selectively or lose it" hazard is gone.
> See [Uncommitted state](#uncommitted-state).

## Why and what's already done

The goal is for all infrastructure to live under the tenant that owns the Microsoft 365
instance, billed to the organization account, so the personal-account subscription can
be abandoned. See
[`entra-auth-as-code.md`](entra-auth-as-code.md#tenant-and-subscription-consolidation)
for why a directory transfer is the wrong mechanism — billing ownership doesn't follow
the directory, and a transfer breaks every identity-bound resource in the subscription.

**The identity layer has already moved.** The dashboard's app registration, service
principal, client secret, and app role assignments live in `aac88807…` and are verified
working in production. What remains is the Azure resource layer.

## The constraint that drives the ordering

**Key Vault references resolve only within the Container App's own tenant.** A managed
identity in one tenant cannot obtain a token for a vault in another. This is why
`kv-mynl-platform` sits in the old subscription today, and it means **the vault and the
Container Apps must move together**. There is no intermediate state where the apps are
in the new subscription and the vault is still in the old one.

Everything else is downstream of that.

## Current state

| | |
| --- | --- |
| Source subscription | `Jackson's Azure` — `c1a7d305-fc17-4bba-a6a9-bcb3cad99751` (tenant `e22c9007…`) |
| Target subscription | `Subscription 1` — `20aad6af-afbd-4c72-a48d-59ae01ca2cb2` (tenant `aac88807…`), Owner held. No longer empty: holds `rg-mynl-tfstate`, `rg-mynl-platform`, and a partially-built `rg-prod` |
| Entra tenant (already moved) | `aac88807…`, app registration `774f2175…` |
| DNS | **AWS Route 53**, zone `Z008615911AMS7RX4EF3I` (`maybeyourenotlost.com`, 11 records) — no Azure DNS zone. All records at **300s TTL**, short enough that no pre-lowering is needed |
| `customDomainVerificationId` | **Subscription-scoped**, so there is one per subscription: old `1174F191…7FD3`, new `17CFD1AA…B00F`. Both are already live on every `asuid.*` record |

### Environments and the naming inversion

Per [`environment.md`](../environment.md), the names diverged from when each was
created. Do not "fix" them.

| Aspire env | Azure RG | Managed environment | Default domain | Hostnames |
| --- | --- | --- | --- | --- |
| `production` | `rg-dev` | `cae-yudlalf6hmivo` | `blackmushroom-9b33cee3.eastus2.azurecontainerapps.io` | `love.`, `dash.` |
| `dev-b` | `rg-dev-b` | `cae-jgbowniw3fqck` | `jollydune-b8fbb161.eastus2.azurecontainerapps.io` | `dev.` |

### Stateful resources

| | |
| --- | --- |
| Postgres | `postgres-yudlalf6hmivo` (prod) and `postgres-jgbowniw3fqck` (dev) — v16, Standard_B1ms Burstable, 32 GB, HA disabled |
| Databases | `encouragement` and `contacts` on each |
| Token store blobs | Disposable cached tokens — nothing to migrate |
| Terraform state | Moved in Phase 1 to `rg-mynl-tfstate/stmynlstate` in the **new** subscription. The old `stmynltfstate` retains versioned backups until Phase 6 |

## DNS and certificates

Container Apps managed certificates can only be issued **after** the hostname's CNAME
already resolves to the target environment. But repointing that CNAME *is* the traffic
cutover. So the naive sequence produces a window where traffic has moved to an
environment that has no valid certificate for the hostname — TLS errors, not a graceful
degradation.

Two things make this much less bad than it first appears.

### Domain ownership can be pre-validated

Ownership validation uses a `TXT` record at `asuid.<subdomain>`, and **multiple TXT
values may coexist on one name**. Azure accepts the binding if *any* value matches. So
the new subscription's verification ID can be added alongside the existing one well
before cutover, with zero impact on the running site. That takes ownership validation
off the critical path entirely, leaving only certificate issuance on it.

### Certificate names are free-form

Production currently uses Azure's auto-generated names
(`mc-cae-yudlalf6hm-love-maybeyouren-7639`), which hardcode the environment's random
suffix into `appsettings.production.json` and break on every environment change. But
the dev environment proves arbitrary names work — it uses a plain `dev-cert`.

**Name the new certificates deterministically** (`love-cert`, `dash-cert`, `dev-cert`).
This removes the `mc-cae-yudlalf6hm-*` strings from source control permanently and makes
the parameters survive any future environment change.

### Closing the window

**Decided: accept the TLS window and use managed certificates.** Service downtime during
the migration is acceptable, so there is no need to bring a certificate of your own.
That removes the only genuinely awkward part of this migration — no Let's Encrypt
DNS-01 dance, no manual certificate to upload and later replace.

Azure's managed certificates cannot be exported, so the existing ones cannot be carried
across regardless; each new environment issues its own.

Records are already at 300s TTL, so no lead time is required. Dropping them to 60s
shortly before cutover is still worth doing — not for uptime, but because TTL is what
bounds how fast a rollback takes effect.

### Route 53 mechanics

The AWS CLI is installed and authenticated against account `731371835931`.

```sh
ZONE=Z008615911AMS7RX4EF3I   # maybeyourenotlost.com
```

Note the CLI is currently authenticated as the account **root** user. Worth replacing
with an IAM user or role scoped to Route 53 before relying on it routinely — root
credentials cannot be scoped or easily revoked.

Adding the new verification ID **alongside** the existing one — note that Route 53
models multiple TXT values as multiple `ResourceRecords` entries under one record set,
so this is an `UPSERT` carrying both values, not a second record:

```json
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{
  "Name":"asuid.dash.maybeyourenotlost.com","Type":"TXT","TTL":300,
  "ResourceRecords":[{"Value":"\"<OLD_ID>\""},{"Value":"\"<NEW_ID>\""}]}}]}
```

The cutover itself is an `UPSERT` of the CNAMEs to the new environments' default
domains. For Phase 5 that is **two** records, not three — `dev.` waits for step 21:

| Record | Cutover target | Rollback target |
| --- | --- | --- |
| `love.` | `frontend.proudcoast-d2445cec.eastus2.azurecontainerapps.io` | `frontend.blackmushroom-9b33cee3.…` |
| `dash.` | `dashboard.proudcoast-d2445cec.eastus2.azurecontainerapps.io` | `dashboard.blackmushroom-9b33cee3.…` |

Note the per-app prefix: the record points at `<container app name>.<env default
domain>`, so `dash.` targets `dashboard.…` and not `dash.…`. Write the rollback batch
at the same time as the cutover batch — recovery is a single `UPSERT` back to the old
environment, and it is much better to have the file ready than to compose it under
pressure. Apply either with:

```sh
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" \
  --change-batch file://cutover.json
```

`aws route53 wait resource-record-sets-changed --id <change-id>` blocks until the change
has propagated to all Route 53 nameservers, which is the right signal to proceed.

## Postgres data and the write window

A dump/restore is not atomic with the DNS flip, so any writes that land on the old
server after the final dump are lost. The app accepts public writes (encouragement
submissions and contact phone numbers), so this needs a deliberate answer rather than
hope.

Mechanics:

- v16 → v16, so `pg_dump`/`pg_restore` per database with no version concerns. The SKU
  does change — `Standard_B1ms`/Burstable to `Standard_D2ds_v5`/GeneralPurpose — but that
  is irrelevant to a logical dump and restore.
- **Authentication**: the servers use Entra auth and the APIs connect by managed
  identity, so there is no stored password to reuse. Authenticate `pg_dump` with an
  Entra access token as the password (`az account get-access-token --resource
  https://ossrdbms-aad.database.windows.net`), or enable password authentication
  temporarily (per [`environment.md`](../environment.md)).

  **⚠ A token alone is not enough — neither server has a human Entra admin.** Both list
  only the APIs' managed identities, and `passwordAuth` is `Disabled` on both, so *no
  user can connect at all* until one is added:

  ```sh
  az postgres flexible-server microsoft-entra-admin create -g <rg> -s <server> \
    --object-id "$(az ad signed-in-user show --query id -o tsv)" \
    --display-name "<upn>" --type User
  ```

  **And the two servers trust different tenants.** The old server accepts tokens only
  from `e22c9007…` (`memjkt@gmail.com`), the new one only from `aac88807…`
  (`jackson@maybeyourenotlost.com`), so each token has to be minted under the matching
  `az account set` context and the admin granted separately on each side. Both logins
  are already present in the CLI. Revoke both grants afterwards.

- **Firewall**: the running machine's IP must be in the server's allowlist, on both
  source and target. Neither carried the current address; the live prod rules covered
  two addresses from September plus `AllowAllAzureIps`.
- **Client tooling**: no `pg_dump`/`psql` is installed on this machine. Run them from a
  `postgres:16` container instead — Docker is available, and it guarantees a client
  version matching both servers without installing anything.

All of the above, plus the restore-mode choice below, is scripted in
[`infra/pg-migrate.sh`](../../infra/pg-migrate.sh) (`prereqs`, `inspect`, `dump`,
`restore`, `cleanup`), which is meant to be run once as a rehearsal and again for the
real cutover.
- **Connections**: the *source* `Standard_B1ms` caps at 50, so keep `pg_dump -j` modest.
  The GeneralPurpose target allows far more, so the restore side is not the constraint.
- **Managed identity grants on the new server** are handled by `aspire deploy`, which
  emits the `*-roles-postgres` modules — no manual grant needed.

**Decided: freeze writes.** Since downtime is acceptable, scale `encouragement-api` and
`contacts-api` to zero replicas for the duration of the final dump and restore. This is
strictly better than doing the cutover quickly and hoping — honest downtime instead of
silently losing a submission that lands in the gap.

```sh
OLD=c1a7d305-fc17-4bba-a6a9-bcb3cad99751
az containerapp update --subscription $OLD -g rg-dev -n encouragement-api \
  --min-replicas 0 --max-replicas 0
az containerapp update --subscription $OLD -g rg-dev -n contacts-api \
  --min-replicas 0 --max-replicas 0
```

`--subscription` is explicit because these target the **old** subscription while the CLI
will usually be pointed at the new one, and `rg-dev` holds production until the resource
groups are renamed.

Note these replica counts are also set in `AppHost.cs` (`MinReplicas = 1`,
`MaxReplicas = 3`), so the next `aspire deploy` restores them — no need to undo the
freeze by hand, but also don't expect it to persist across a deploy.

Still worth doing a **rehearsal dump and restore** in Phase 4 while everything is still
live, to size the real one and shake out authentication and firewall problems before
anything is frozen.

## Resource group naming

The current names are inverted — `rg-dev` holds production, `rg-dev-b` holds dev. The
migration corrects this to **`rg-prod` for production and `rg-dev` for dev**.

This is nearly free *because* of the migration. Azure cannot rename a resource group in
place; the alternative is creating new ones and moving resources, which not every
resource type supports. Creating them fresh in the new subscription sidesteps that
entirely.

**Do not change `AZURE_RESOURCE_GROUP` before the cutover.** The workflows read the
resource group from that environment secret, and azd creates what it does not find — so
pointing the old subscription at `rg-prod` would not fail, it would quietly provision a
second copy of production alongside the real one. The secret changes only when the deploy
target changes (step 17).

Note this also *swaps* what `rg-dev` means: today it holds production, afterwards it
holds dev. Any saved query, bookmark, or alert scoped to `rg-dev` wants re-checking.

The Aspire environment name `dev-b` is left alone — correcting it means renaming
`appsettings.dev-b.json` and the dev workflow's `ASPIRE_ENVIRONMENT`, which is a separate
change from the resource groups.

## Order of operations

The authoritative sequence from the current state to a decommissioned old subscription.
Phases 1-3 are done. Steps marked **⚠** must not be reordered — the note says what breaks.

### Resume Phase 4

1. ~~Add the GeneralPurpose `Sku` override to the Postgres `ConfigureInfrastructure`
   callback in `AppHost.cs`.~~ **Done** — `deb5ebf`.
2. ~~**⚠ Commit the Postgres changes on their own**, staging selectively so the temporary
   `const bool bind*Domain = false` flags do not ship.~~ **Done** — the availability-zone
   override is `09c5e8e` and the SKU override is `deb5ebf`, neither carrying the flags.
   The override no longer exists only in the working tree, so `git checkout` on
   `AppHost.cs` is now safe.
3. Leave the temporary flags and the emptied `appsettings.production.json` in place —
   both are still needed for the next step.
4. `aspire deploy` into `Subscription 1` / `rg-prod`. Expect Postgres and the four
   container apps to be created. **⚠ Verify in Azure, not by exit code** — `aspire
   deploy` has already exited 0 with a failed Postgres deployment.

   **Partially done.** Postgres is `Ready` on `Standard_D2ds_v5` with both databases,
   and `frontend` and `dashboard` exist. Two things still fail, both covered below:
   the `encouragement-api` and `contacts-api` image pushes, and the dashboard's auth
   config.

5. **⚠ Grant the dashboard's system-assigned identity read access to `kv-mynl`, then
   deploy again.** This cannot be done before step 4: the identity does not exist until
   the Container App does, and `kv-mynl` is RBAC-only, so Easy Auth cannot resolve
   either Key Vault reference without the role. Skipping it fails the deploy with
   `AuthConfigSecretRefNotFound: Secret with name 'aad-client-secret' is not found in
   configuration of container app 'dashboard'`, which reads like a missing secret rather
   than a missing permission.

   This is [`infra/terraform/README.md`](../../infra/terraform/README.md) step 4 and is
   already described in `platform/main.tf`; it was simply missing from this sequence.

   ```sh
   az containerapp show -g rg-prod -n dashboard --query identity.principalId -o tsv
   # put it in platform/terraform.tfvars as container_app_principal_ids, then apply
   ```

   **Done** for principal `1ce367a2-e784-4c33-a5fd-02b044932ba8` — it now holds
   `Key Vault Secrets User` on `kv-mynl`, matching what the old subscription's dashboard
   identity holds on `kv-mynl-platform`, and `container_app_grants_pending` is now
   `false`. Note `*.tfvars` is gitignored, so that edit is deliberately local-only.

   Until this lands **the dashboard serves unauthenticated** — no auth config at all and
   `/.auth/me` 404s. Harmless while the APIs are absent, the database is empty and
   `dash.` still points at the old environment, but it must not stay that way once data
   arrives.

6. Retry the two failed image pushes by re-running `aspire deploy`. The ACR push
   timeouts (`net/http: timeout awaiting response headers`) are **transient, not
   image-specific**: the first deploy lost `frontend` and `dashboard`, the second lost
   `encouragement-api` and `contacts-api` — the exact inverse — and both of the latter
   died on the same shared .NET base layer. Re-running picks up where it left off.
7. Verify the stack over the default `*.azurecontainerapps.io` hostnames —
   `proudcoast-d2445cec.eastus2.azurecontainerapps.io`.
8. Rehearse `pg_dump` / `pg_restore` while nothing is frozen, to size the real run and
   shake out authentication and firewall problems.

### Optional: validate dashboard sign-in before cutover — ~~skipped~~

**Decided: skip it.** Sign-in is tested after cutover instead. Everything up to the
final leg of the OAuth exchange is already verified on the new environment, downtime is
acceptable, and rollback is a DNS flip — so the second redirect URI is not worth adding
and removing. Steps 9 and 10 are retained below for the reasoning.

9. Sign-in cannot be exercised on the new environment's default hostname as-is: the only
   registered redirect URI is `https://dash.maybeyourenotlost.com/.auth/login/aad/callback`,
   so any other hostname fails with a redirect-URI mismatch. To test it early, add the
   new hostname as a second redirect URI in `infra/terraform/entra` and remove it in
   Phase 6.

   Confirmed in practice: the deployed dashboard redirects to
   `…/oauth2/v2.0/authorize?…&redirect_uri=https%3A%2F%2Fdashboard.proudcoast-d2445cec.eastus2.azurecontainerapps.io%2F.auth%2Flogin%2Faad%2Fcallback`,
   which is not registered. Everything up to the redirect is verified working — the
   tenant, client ID, secret resolution and token store are all correct — so what this
   step would add is only the final leg of the exchange.
10. Given that downtime is acceptable and rollback is a DNS flip, skipping this and
   testing after cutover is a reasonable trade. Decide deliberately rather than by
   default.

### Phase 5 — cutover

11. Freeze writes: scale `encouragement-api` and `contacts-api` to zero replicas **in the
   old subscription**.
12. Final `pg_dump` of `encouragement` and `contacts`; restore into the new server.

    **⚠ The target databases are no longer empty.** Both APIs applied their EF Core
    `InitialCreate` migrations on first start, so `encouragement` and `contacts` already
    hold the full schema plus an `__EFMigrationsHistory` table.

    **Rehearsed, and settled: `--data-only`, minus `__EFMigrationsHistory`.** Both
    servers are on the same single `InitialCreate` migration, so the target's schema
    already matches and `--data-only` is the least destructive option. The one snag is
    that the dump also carries the `__EFMigrationsHistory` row the target already has,
    so its `COPY` fails on the primary key:

    > `duplicate key value violates unique constraint "PK___EFMigrationsHistory"`
    > `Key ("MigrationId")=(20260817185224_InitialCreate) already exists`

    That conflict is benign — identical bookkeeping, not data, and every other table
    restores — but it is excluded rather than tolerated, by filtering that one entry
    out of the `pg_restore` TOC. `restore` in
    [`infra/pg-migrate.sh`](../../infra/pg-migrate.sh) does this and then runs with
    `--exit-on-error`, so the restore is clean and any *real* failure stops it.

    `MODE=clean` (`--clean --if-exists`) remains the fallback, and is the right answer
    if the two servers ever diverge on migrations — which is what `inspect` checks and
    should be re-checked at cutover rather than assumed, since the old server keeps
    running until then.

    **A data-only restore is not idempotent on its own**, which matters because the
    rehearsal has already left a copy of production data in these tables. It assumes
    empty targets, so a second run fails on `PK_Encouragements` instead of the
    migrations table. `restore` therefore `TRUNCATE`s the target's tables (CASCADE, so
    foreign-key order does not matter) before reloading, making it safe to run as many
    times as needed.

    **`pg_restore`'s exit code is not the success criterion** — run `verify`, which
    compares row counts on both servers side by side. It counts with `count(*)` rather
    than `pg_stat_user_tables.n_live_tup`, which is an estimate that lags autovacuum
    and can read `0` on a freshly restored table.

    `verify` also checks the **identity sequences**, which is the subtle one. The
    restored rows carry explicit `Id` values and `TRUNCATE` does not reset the owning
    sequence — `pg_dump`'s `setval` entries are what put it right. A sequence left
    behind `max(Id)` leaves the table looking perfect and then fails the *first write
    after cutover*. Both currently check out
    (`Encouragements` 659/659, `Contacts` 371/371).
13. **⚠ Repoint the `love.` and `dash.` CNAMEs at the new environment's default domain,
    and only then bind the domains.** A custom subdomain cannot be bound until its CNAME
    already resolves to the target environment. Traffic moves here and the TLS window
    opens. Wait with `aws route53 wait resource-record-sets-changed --id <change-id>`.

    **Leave `dev.` alone.** The dev environment is not rebuilt until step 21, so
    repointing `dev.` now would aim it at an environment that does not exist. It moves
    with the rebuild, off the critical path — which is the whole point of
    [decision 4](#decisions).
14. Restore the two `ConfigureCustomDomain` call sites to their unconditional form,
    discard the temporary flags, and set the real values in
    `appsettings.production.json`: the live hostnames, the **deterministic** certificate
    names (`love-cert` and `dash-cert` — not the old `mc-cae-yudlalf6hm-*` strings), and
    the `kv-mynl` Key Vault URIs. `dev-cert` belongs to step 21, not here.

    **Commit this on the branch but do not merge it yet** — step 17 has to repoint CI
    first, or a CI run would deploy this configuration to the old subscription.
15. `aspire deploy` again. This binds the custom domains and issues the managed
    certificates, closing the TLS window.
16. Smoke test: public site loads; dashboard sign-in completes with no `AADSTS` error and
    `/.auth/me` returns the user rather than 404ing; both APIs read and write.

### Phase 6 — decommission

17. **⚠ Repoint CI before merging the cutover commit.** Set
    `manage_github_actions = true` with `github_environments` mapping `production` to
    `rg-prod` and `dev` to `rg-dev`, and `cicd_subscription_id` to the new subscription.
    Merging the cutover commit while CI still targets the old subscription would deploy
    the new configuration there.
18. Merge to `main` so source control matches reality, and confirm a CI run lands in the
    new subscription.
19. Promote the client secret: drop `azurerm_key_vault_secret.client_secret` from the
    `entra` module and make `client_secret_target` the only one, via `terraform state mv`
    rather than destroy-and-recreate. Remove the `azurerm.target` alias and the
    `target_key_vault_*` variables.
20. Drop `secret_writer_principal_ids` and `EXTRA_STATE_PRINCIPALS` — both existed only
    while Entra and the infrastructure were in different tenants.
21. Rebuild the dev environment in the new subscription (empty, no data migration), then
    repoint the `dev.` CNAME and set its hostname and certificate name in
    `appsettings.dev-b.json`. Decide its Postgres SKU here — see
    [decision 7](#decisions).
22. **⚠ Only now delete the old subscription's resources**, and only after the new stack
    has been verified under real use. Until this step the old environments are the
    rollback target: repointing the CNAMEs back is the entire recovery procedure.
23. Remove the stale verification ID from the `asuid.*` TXT records, and raise the CNAME
    TTLs back to 300s if they were lowered.
24. Delete the old app registration `f32123ed`, the legacy
    `tfstate/platform-legacy-oldsub.tfstate`, and the `stmynltfstate` state account.

## Phases

**[Order of operations](#order-of-operations) is the authoritative sequence.** The
sections below carry status, rationale, and the detail behind each phase — not a second
ordering. If the two ever disagree, the order of operations is correct.

Phases 1–4 are fully reversible and invisible to users: they build the new stack
alongside the old one and change nothing about what serves traffic. Phase 5 is the
cutover.

### Phase 1 — Bootstrap the target subscription

**Done.**

```sh
STATE_ACCOUNT=stmynlstate ./infra/bootstrap-subscription.sh \
  20aad6af-afbd-4c72-a48d-59ae01ca2cb2 aac88807-ec5d-4c7a-8379-0f2baf8123e0
```

All eight providers were unregistered on the empty subscription and are now registered.
Before that, even `az storage account check-name` failed with `SubscriptionNotFound` —
which is what an unregistered `Microsoft.Storage` looks like, not a missing subscription.

`STATE_ACCOUNT` is overridden because storage account names are globally unique and
`stmynltfstate` is still held by the old subscription. The permanent name is
**`stmynlstate`** in `rg-mynl-tfstate`, versioning enabled.

Both state files were then migrated with `terraform init -migrate-state -force-copy`,
and both backends in `versions.tf` now point at the new account. The old state blobs
remain in `stmynltfstate` as versioned backups until Phase 6.

### Phase 2 — Platform layer in the target

**Done.** `rg-mynl-platform` / `kv-mynl` / `stmynltokens` now exist in `Subscription 1`,
with the token store container and SAS secret. 7 added, 0 changed, 0 destroyed.

The old deployment is **orphaned, not destroyed**: its resources keep running and keep
the live dashboard serving until the DNS cutover, and they die with the old subscription
in Phase 6. That turned out simpler than the Terraform workspace this plan originally
called for — no permanent `-var-file` discipline, and one clean state going forward.

How: the existing state blob was archived to `tfstate/platform-legacy-oldsub.tfstate`,
the original deleted, and `terraform init -reconfigure` started a fresh empty state at
`platform.tfstate`. Three copies of the old state exist (that archive, the pre-migration
blob still in `stmynltfstate`, and a local backup), so `terraform destroy` of the old
resources remains possible by restoring one.

Names had to differ from the old deployment's, since both are globally unique and still
in use. **`az keyvault check-name` is not trustworthy** — it reported
`kv-mynl-platform` as available while that vault demonstrably exists. Verify with DNS
instead:

```sh
dig +short kv-mynl-platform.vault.azure.net   # resolves => taken (the old vault)
dig +short kv-mynl.vault.azure.net            # no answer => free (what we used)
```

`secret_writer_principal_ids` is empty here and should stay that way. It existed only
because Entra and the infrastructure were in different tenants; in this subscription
both are `aac88807…`, so the identity running Terraform already has what it needs.

### Phase 3 — Write the client secret into the new vault

**Done.** The client secret now exists in **both** vaults. 1 added, 0 changed, 0
destroyed. The app registration did not change — same client ID `774f2175…`, same
assignments, same redirect URI. Only the secret's storage was extended.

This had to be additive, and **permission to take the dashboard down did not make the
simple version viable.** Repointing `key_vault_id` fails before it can plan: that field
is ForceNew, so Terraform must first refresh the existing secret at
`kv-mynl-platform.vault.azure.net`, and a provider repointed to `aac88807…` cannot get a
token a vault in `e22c9007…` will accept. The obstacle is token issuance, not caution.

So the module gained `azurerm.target`, a second provider alias, and a count-gated
`azurerm_key_vault_secret.client_secret_target`. The primary provider stays pinned to
whichever tenant currently holds the secret, because it has to keep refreshing it. The
alias falls back to mirroring the primary when the migration variables are unset, so it
is always validly configured even when nothing uses it.

The same constraint shows up from the CLI: reading the old vault while `az` is pointed
at the new tenant returns `AKV10032: Invalid issuer`, listing the tenants that vault will
accept. Switch `az account set` to an old-subscription context to inspect it by hand.

Phase 6 drops the original resource and promotes the target to be the only one.

### Phase 4 — Deploy the application stack, without custom domains

**In progress, and most of the way there.** `aspire deploy` has been run three times
against `Subscription 1` / `rg-prod`. The SKU blocker that stopped the first two is
resolved and committed; the third run provisioned Postgres successfully and brought up
two of the four container apps.

Created and healthy (resource token `jcykdmvrxadbu`):

| Resource | |
| --- | --- |
| `cae-jcykdmvrxadbu` | Container Apps environment, `Succeeded` |
| Default domain | `proudcoast-d2445cec.eastus2.azurecontainerapps.io` |
| `acrjcykdmvrxadbu` | Container registry |
| `law-jcykdmvrxadbu` | Log Analytics workspace |
| `mi-`, `encouragement_api_identity-`, `contacts_api_identity-` | Managed identities |
| `postgres-jcykdmvrxadbu` | `Standard_D2ds_v5` GeneralPurpose, v16, zone 3, `Ready`, with the `encouragement` and `contacts` databases |
| `frontend` | Container app, `Succeeded` |
| `dashboard` | Container app, `Succeeded` and running — but **no auth config**, see below |

Still missing: the `encouragement-api` and `contacts-api` container apps, whose image
pushes timed out, and the dashboard's Easy Auth configuration.

**Former blocker, now resolved: Postgres `SkuNotAvailable`.** The first two deploys
failed provisioning `Standard_B1ms` / `Burstable` in `eastus2`:

> Specified SKU is not supported in this region. Please choose a different SKU.

This is subscription-specific, not regional — the *old* subscription runs exactly that
SKU in exactly that region, and the region's capability API lists `Standard_B1ms` with
no restriction. A fresh Pay-As-You-Go subscription commonly cannot provision Burstable
until quota is granted.

A first hypothesis — that Aspire's pinned `availabilityZone: '1'` was at fault, since
zone numbers are logical per subscription and do not survive a move — was **wrong**. The
pin was removed and the error is unchanged. The fix is still worth keeping on its own
merits (see [findings](#findings-worth-keeping)), but it is not the cause.

**Resolved: move to GeneralPurpose.** `Standard_D2ds_v5` / `GeneralPurpose` — the
smallest current-generation GeneralPurpose SKU, listed as available in `eastus2` for this
subscription. Chosen over the alternatives (a different region, which would move the
whole stack for a cheaper SKU; or requesting Burstable quota through support and
waiting).

**Implemented and committed** (`deb5ebf`), alongside the availability-zone override on
the same `ConfigureInfrastructure` callback:

```csharp
server.Sku = new PostgreSqlFlexibleServerSku
{
    Name = "Standard_D2ds_v5",
    Tier = PostgreSqlFlexibleServerSkuTier.GeneralPurpose,
};
```

**How this was established.** Three throwaway servers were created directly in
`rg-prod` and deleted immediately — `Standard_B1ms`, `Standard_B2s` and
`Standard_D2ds_v5`. Both Burstable sizes failed with `SkuNotAvailable`; the
GeneralPurpose server reached `Ready` (v16, zone 3). This probe is the only trustworthy
signal available, since the capability API reports every Burstable size as unrestricted,
including the two that demonstrably fail. It costs cents and a few minutes, and is worth
repeating rather than inferring whenever an SKU question comes up.

Two consequences, both now settled by that probe:

- **Cost.** Retail pricing in `eastus2`, read from the Azure retail prices API on
  2026-11-11: `Standard_B1ms` **$0.0170/hr** (~$12/mo) against `Standard_D2ds_v5`
  **$0.1780/hr** (~$130/mo) — a **10.5x** increase, roughly **+$118/mo per server**.
  There is no cheaper way to buy 2 GeneralPurpose vCores: every current series
  (`Ddsv5`, `Dadsv5`, `Dsv6`, `Ddsv4`) prices at $0.0890/vCore, and the older `Dsv3` at
  $0.0855 saves under 4%. Accepted deliberately.
- **The dev environment.** Now answered, and unfavourably: Burstable is restricted
  **tier-wide**, not per-server — `Standard_B2s` fails exactly as `Standard_B1ms` does.
  So a rebuilt dev environment with its own server needs GeneralPurpose too, taking the
  pair to **~$260/mo** for one environment that carries no production traffic. This
  makes the open question in [decision 7](#decisions) sharper rather than softer: decide
  at step 21 whether dev needs its own server at all, or can share the production server
  with separate databases.

One upside: the 50-connection ceiling on `Standard_B1ms` that the current replica limits
were sized around disappears — a 2-vCore GeneralPurpose server allows far more. The
`MinReplicas` / `MaxReplicas` values in `AppHost.cs` were constrained partly by that cap
and can be revisited once this lands.

**Docker pushes to the new ACR time out intermittently**
(`net/http: timeout awaiting response headers`), and it is now clear this is transient
rather than image-specific: the first deploy lost `frontend` and `dashboard`, the third
lost `encouragement-api` and `contacts-api` — the exact inverse — with the two API
failures both dying on the same shared .NET base layer. Re-running `aspire deploy`
resumes without repeating the pushes that already succeeded, so the fix is simply to
run it again until all four land.

**The dashboard's Easy Auth needed a vault role that could not exist yet.** The third
deploy failed `provision-dashboard-containerapp` with:

> `AuthConfigSecretRefNotFound: Secret with name 'aad-client-secret' is not found in
> configuration of container app 'dashboard'.`

The message is misleading — the secret *is* present on the app, as a Key Vault reference
to `kv-mynl` resolved through the app's system-assigned identity. What was missing is
that identity's permission: `kv-mynl` is RBAC-only and the principal had no role, and it
could not have been granted one earlier because the principal does not exist until the
Container App does. That grant is step 5 and is now applied. The container app itself is
running, so only its auth config is outstanding.

**Done in this phase, with no user impact:**

- The new subscription's `customDomainVerificationId`
  (`17CFD1AA78C587D0A8A7519A47FFE91C55404919C6A42985F803E9E0AAE8B00F`) is added as a
  **second** TXT value on `asuid.love`, `asuid.dash`, and `asuid.dev`, alongside the old
  one. Verified: two values live on each record, CNAMEs still resolving to the old
  environment. Domain-ownership validation is now off the cutover's critical path.
- Read it from the environment, which avoids a chicken-and-egg (no container app has to
  exist first):
  `az containerapp env show -n <cae> -g <rg> --query properties.customDomainConfiguration.customDomainVerificationId`

**Still to do in this phase:**

- ~~Implement the GeneralPurpose SKU override~~ **done** (`deb5ebf`)
- ~~Get a Postgres server provisioned~~ **done** — `postgres-jcykdmvrxadbu`,
  `Standard_D2ds_v5` / GeneralPurpose / zone 3, `Ready`, with the `encouragement` and
  `contacts` databases created
- ~~Grant the dashboard identity `Key Vault Secrets User` on `kv-mynl`~~ **done** —
  principal `1ce367a2-e784-4c33-a5fd-02b044932ba8`,
  `container_app_grants_pending = false`
- ~~Deploy all four container apps~~ **done** — a fourth `aspire deploy` pushed the two
  API images on the retry and all four apps report `Healthy`, with `frontend` on 2
  replicas and the rest on 1
- ~~Create the dashboard's Easy Auth config~~ **done** — the deploy after the vault
  grant created it: platform enabled, `RedirectToLoginPage`, client
  `774f2175…`, issuer `aac88807…`, token store enabled. The dashboard now 302s
  browsers to `login.microsoftonline.com` and 401s everything else
- ~~Verify the stack over the default `*.azurecontainerapps.io` hostnames~~ **done** on
  `proudcoast-d2445cec.eastus2.azurecontainerapps.io` — frontend 200; both APIs
  connected to Postgres by managed identity and applied their `InitialCreate`
  migrations; `/encouragements` through the frontend proxy reaches
  `encouragement-api` (405 on `GET`, which is the route resolving, not failing)
- Optionally exercise dashboard sign-in before cutover — this needs a second redirect
  URI, so it is a deliberate opt-in rather than a free step. See
  [order of operations](#optional-validate-dashboard-sign-in-before-cutover)
- ~~Rehearsal `pg_dump` / `pg_restore`~~ **done**, via
  [`infra/pg-migrate.sh`](../../infra/pg-migrate.sh) (`prereqs`, `inspect`, `dump`,
  `restore`, `verify`, `cleanup`). It shook out exactly what a rehearsal is for:

  - Neither server had a human Entra admin, so **no user could connect at all** — see
    [authentication](#postgres-data-and-the-write-window). `prereqs` grants it.
  - Neither server's firewall carried the current address.
  - No local `pg_dump`/`psql`, so everything runs in a `postgres:16` container.
  - The old tenant's account is a **B2B guest**, whose Postgres role name is the
    mangled `..._gmail.com#EXT#@...onmicrosoft.com` form. The script reads the role
    name back from the server rather than guessing it.
  - A data-only restore collides on `__EFMigrationsHistory` and nothing else — benign,
    and now excluded via a filtered TOC. See step 14.
  - A data-only restore is also not repeatable without clearing the target first, so
    `restore` now truncates before reloading.

  **Verified end to end**: `Encouragements` 659 and `Contacts` 371 rows on both
  servers, identity sequences correct, and a repeat restore running clean under
  `--exit-on-error`. The sizes are small enough that the write freeze in Phase 5 will
  be brief.

  Note the new databases now hold a copy of production data from the rehearsal. That
  is harmless — nothing serves traffic from them, and the cutover's restore truncates
  first — but it is why `verify` matching is not by itself proof the *final* restore
  ran; re-run it after the real one.

  ~~**Still to do before the real run:** `cleanup`~~ **done** — both Entra admin grants
  and all rehearsal firewall rules revoked, verified on both servers. Production is
  back to its pre-rehearsal state: the old server holds only its three managed
  identities and its original three firewall rules, the new server only its two
  identities and `AllowAllAzureIps`. `prereqs` has to be run again for the real
  cutover.
- Optionally drop the CNAME TTLs from 300s to 60s to bound rollback time

### Phase 5 — Cutover

The only user-visible step, and the only one that is not freely reversible. See
[order of operations](#phase-5--cutover) for the sequence.

Two things make it awkward, and both are inherent rather than accidental:

- **A custom subdomain cannot be bound until its CNAME already resolves to the target
  environment.** So traffic has to move *before* the certificate can exist, which opens a
  TLS window for however long managed-certificate issuance takes. Accepted deliberately,
  since downtime during the migration is fine.
- **The dump and restore are not atomic with the DNS change.** Hence the write freeze:
  scaling both APIs to zero is honest downtime rather than silently losing a submission
  that lands in the gap.

The redeploy at the end also restores the replica counts, since `MinReplicas` /
`MaxReplicas` live in `AppHost.cs` — the freeze undoes itself, but it will not survive a
deploy either.

### Phase 6 — Decommission

Deliberately last, because **the old environments are the rollback target** right up
until they are deleted. Repointing the CNAMEs back is the entire recovery procedure, and
it only works while the old stack still exists and still holds valid certificates. See
[order of operations](#phase-6--decommission) for the sequence.

On removing the old platform resources: they were **orphaned from Terraform state** in
Phase 2, not left under management, so there is no workspace to destroy. Either
`az group delete` the old `rg-mynl-platform` directly, or restore
`tfstate/platform-legacy-oldsub.tfstate` and `terraform destroy` with the old variable
values. Deleting the old subscription outright makes both moot.

`WithAzdResourceNaming()` is also revisited here rather than earlier — see
[decision 5](#decisions).

## Findings worth keeping

Things learned the hard way during Phases 1-4, each of which cost time or misdirected
the investigation:

- **Aspire pins the Postgres availability zone to `'1'`.** Zone numbers are logical per
  subscription — zone 1 in one subscription is not the same physical zone as in another,
  and capacity differs — so a pinned zone does not survive a move between subscriptions.
  Worth overriding to `''` (let Azure choose) regardless of whether it is the current
  blocker. Done via `ConfigureInfrastructure` on the Postgres resource.
- **`aspire deploy` exited 0 while the Postgres deployment failed.** The exit code is not
  a reliable success signal. Verify with
  `az deployment group list -g <rg> --query "[].{n:name,s:properties.provisioningState}"`.
- **`SkuNotAvailable` does not mean the region lacks the SKU.** It is also returned for
  subscription-level restrictions and zone capacity, while the region's capability API
  cheerfully lists the SKU as available with `status: null`.
- **The only trustworthy SKU-availability test is to create a server and delete it.**
  Neither `az postgres flexible-server list-skus` nor the capability API distinguishes
  "offered in this region" from "provisionable by this subscription", and both reported
  the failing Burstable sizes as unrestricted. A throwaway `az postgres flexible-server
  create ... && delete` answers it definitively in a few minutes for cents, and
  `SkuNotAvailable` comes back in about two minutes — well before a successful create
  finishes. Probe several SKUs in parallel; the CLI cleans up the failures itself.
- **Prefer probing over inferring before committing a cost increase.** The GeneralPurpose
  move is a 10.5x jump on the project's main cost line, and the evidence for it
  originally rested on the same API that was wrong about Burstable.
- **`az keyvault check-name` is unreliable** — it reported a demonstrably-existing vault
  name as available. Use `dig +short <name>.vault.azure.net` instead.
- **Reading a vault while `az` points at the wrong tenant returns `AKV10032: Invalid
  issuer`**, listing the tenants it will accept — not a permissions error.
- **A custom subdomain cannot be bound until its CNAME already resolves to the target
  environment.** So a new environment must be deployed without its domains, and bound
  afterwards. This is what forces Phase 4 to precede Phase 5 rather than merge with it.
- **An "empty custom domain means skip binding" conditional driven from
  `builder.Configuration["Parameters:customDomain"]` does not work**, and the reason is
  now known: **`aspire deploy` caches every `Parameters:*` value in a per-environment
  deployment state file** at `~/.aspire/deployments/<hash>/<environment>.json`, and that
  cache takes precedence over `appsettings.<env>.json`. The conditional was reading a
  stale `love.maybeyourenotlost.com` out of the cache, not the `""` in appsettings —
  which is also why an unrelated *code* change in the same publish took effect
  immediately: code is not cached, parameters are. A compile-time `const bool` works
  because it sidesteps configuration entirely.
- **That cache is a hazard in its own right during a migration.** It held the old
  subscription's `kv-mynl-platform` Key Vault URIs and placeholder client/tenant GUIDs,
  so a deploy that trusted it would have pointed the dashboard at a vault its managed
  identity cannot read — the exact constraint this migration is ordered around. Inspect
  it before any cross-subscription deploy, and `aspire deploy --clear-cache` to discard
  it so the values come from `appsettings` again. Note `--clear-cache` also discards the
  cached `Azure:SubscriptionId` / `Azure:ResourceGroup`, so that run prompts for the
  target interactively; the run after it re-caches the corrected values.
- **The dashboard's vault grant cannot precede its first deploy.** `kv-mynl` is
  RBAC-only and the app's system-assigned principal does not exist until the Container
  App does, so the `Key Vault Secrets User` role has to be granted between two deploys.
  Skipping it fails the second one with `AuthConfigSecretRefNotFound: Secret with name
  'aad-client-secret' is not found in configuration of container app 'dashboard'`, which
  names the secret and not the permission — and the secret is genuinely present on the
  app, so the message sends you to the wrong place.
- **ACR push timeouts here are transient, not image-specific.** Two deploys each lost a
  different pair of images to `net/http: timeout awaiting response headers` — the first
  `frontend`/`dashboard`, the second `encouragement-api`/`contacts-api`. Re-running
  `aspire deploy` resumes from where it stopped; the pushes that already succeeded are
  not repeated.

## Uncommitted state

Two files still differ from `HEAD`, and **everything remaining in both is temporary and
discardable.** The Postgres work that used to be tangled in here is committed
(`09c5e8e` availability zone, `deb5ebf` GeneralPurpose SKU), so the earlier requirement
to stage selectively — and the risk that a careless `git checkout` destroyed the only
copy of the override — no longer applies.

### `apphost/appsettings.production.json` — discard entirely

`customDomain`, `certificateName`, `dashboardCustomDomain` and `dashboardCertificateName`
emptied, and both Key Vault URIs pointed at `kv-mynl`. CI still deploys to the **old**
subscription on push to `main`, so committing this would strip the custom domains off the
live production apps and point them at a vault their managed identity cannot read.

`git checkout -- apphost/appsettings.production.json` restores it; `HEAD` holds the
correct live values.

### `apphost/AppHost.cs` — discard entirely

All that remains is the Phase 4 scaffolding:

- `const bool bindFrontendDomain = false;` / `bindDashboardDomain = false`
- The two `if (...)` blocks wrapping `app.ConfigureCustomDomain(...)`

`HEAD` now contains the full Postgres configuration *and* two plain, unconditional
`ConfigureCustomDomain` calls — so at step 14 `git checkout -- apphost/AppHost.cs` is the
whole restoration, and it is safe. There is no committed conditional form to return to:
the config-driven conditional never worked (see
[findings](#findings-worth-keeping)) and was never committed. Do **not** simply flip the
constants to `true` — that leaves conditional scaffolding behind for a condition that
never varies.

## Decisions

1. ~~Who hosts DNS?~~ **AWS Route 53**, zone `Z008615911AMS7RX4EF3I`. The AWS CLI is
   installed and authenticated, and records are at 300s TTL, so no lead time is
   required.
2. ~~Zero-downtime or a brief TLS window?~~ **Accept the window, use managed
   certificates.** Downtime during the migration is acceptable.
3. ~~Write-freeze strategy?~~ **Freeze**: scale both APIs to zero for the dump/restore.
4. ~~Migrate the dev environment or rebuild it empty?~~ **Rebuild empty.** No dev data
   is worth carrying, and it roughly halves the cutover work — no second Postgres
   dump/restore, and `dev.` can be repointed whenever rather than on the critical path.
5. ~~`WithAzdResourceNaming()`~~ **Keep it for now**, deprecate later. It is a single
   global setting on `AppHost.cs:9` affecting both environments, and changing it while
   the old subscription still serves traffic would try to rename live resources. Revisit
   once the old subscription is gone.
6. ~~Resource group naming~~ **Corrected to `rg-prod` / `rg-dev` during the migration** —
   see [resource group naming](#resource-group-naming).
7. ~~Postgres SKU, after Burstable proved unavailable in the target subscription~~
   **GeneralPurpose `Standard_D2ds_v5`**, implemented in `deb5ebf` and confirmed by
   probe: both `Standard_B1ms` and `Standard_B2s` fail with `SkuNotAvailable` while
   `Standard_D2ds_v5` reaches `Ready`. Burstable is therefore restricted **tier-wide**
   in this subscription. ~~The dev environment's SKU~~ follows from that — it cannot be
   Burstable either — which leaves the real sub-question as **whether dev needs its own
   server at all** at ~$130/mo, or should share production's with separate databases.
   The revisited replica limits remain open. See
   [Phase 4](#phase-4--deploy-the-application-stack-without-custom-domains).

## Rollback

Phases 1–4 roll back by deleting what was created in the target subscription; nothing
user-visible has changed. Phase 5 is different:

- **Before the DNS flip**: abandon freely.
- **After the DNS flip**: roll back by repointing the CNAMEs at the old environments,
  which still exist and still hold valid certificates. This is why the old subscription
  is not deleted until Phase 6 — it is the rollback target, and the CNAME TTL is what
  bounds how long the reversal takes to take effect.
- **Writes that landed on the new stack** after cutover will not exist on the old
  server. A rollback after real traffic means reconciling those by hand, so the decision
  point is short: verify quickly, then commit.
