# Plan: Migrating to the Microsoft 365 Tenant's Subscription

> **Status (2026-11-11).** Phases 1-3 complete. Phase 4 is **blocked on Postgres SKU
> availability** in the target subscription — see
> [Phase 4](#phase-4--deploy-the-application-stack-without-custom-domains). The live
> site and dashboard are unaffected and still served entirely from the old
> subscription.
>
> **Two uncommitted working-tree edits exist and must not be committed as-is** — see
> [Uncommitted state](#uncommitted-state).

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
| Target subscription | `Subscription 1` — `20aad6af-afbd-4c72-a48d-59ae01ca2cb2` (tenant `aac88807…`), **empty**, Owner held |
| Entra tenant (already moved) | `aac88807…`, app registration `774f2175…` |
| DNS | **AWS Route 53**, zone `Z008615911AMS7RX4EF3I` (`maybeyourenotlost.com`, 11 records) — no Azure DNS zone. All records at **300s TTL**, short enough that no pre-lowering is needed |
| `customDomainVerificationId` | `1174F191…7FD3` — **subscription-scoped**, identical for every app in both environments |

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
| Terraform state | `rg-mynl-tfstate/stmynltfstate` in the **old** subscription; needs moving too |

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

The cutover itself is an `UPSERT` of the three CNAMEs to the new environments' default
domains. Apply with:

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

- v16 → v16, same SKU, so `pg_dump`/`pg_restore` per database with no version concerns.
- **Authentication**: the servers use Entra auth and the APIs connect by managed
  identity, so there is no stored password to reuse. Either enable password
  authentication temporarily (per [`environment.md`](../environment.md)) or authenticate
  `pg_dump` with an Entra access token as the password.
- **Firewall**: the running machine's IP must be in the server's allowlist, on both
  source and target.
- **Connections**: Standard_B1ms caps at 50 connections. Keep `pg_restore -j` modest —
  single-digit parallelism is plenty for 32 GB of burstable storage.
- **Managed identity grants on the new server** are handled by `aspire deploy`, which
  emits the `*-roles-postgres` modules — no manual grant needed.

**Decided: freeze writes.** Since downtime is acceptable, scale `encouragement-api` and
`contacts-api` to zero replicas for the duration of the final dump and restore. This is
strictly better than doing the cutover quickly and hoping — honest downtime instead of
silently losing a submission that lands in the gap.

```sh
az containerapp update -n encouragement-api -g rg-dev --min-replicas 0 --max-replicas 0
az containerapp update -n contacts-api      -g rg-dev --min-replicas 0 --max-replicas 0
```

Note these replica counts are also set in `AppHost.cs` (`MinReplicas = 1`,
`MaxReplicas = 3`), so the next `aspire deploy` restores them — no need to undo the
freeze by hand, but also don't expect it to persist across a deploy.

Still worth doing a **rehearsal dump and restore** in Phase 4 while everything is still
live, to size the real one and shake out authentication and firewall problems before
anything is frozen.

## Phases

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
dig +short kv-mynl.vault.azure.net    # resolves => name taken
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

**In progress, blocked.** `aspire deploy` has been run twice against
`Subscription 1` / `rg-prod`. Infrastructure partially exists; no application is running.

Created and healthy (resource token `jcykdmvrxadbu`):

| Resource | |
| --- | --- |
| `cae-jcykdmvrxadbu` | Container Apps environment, `Succeeded` |
| Default domain | `proudcoast-d2445cec.eastus2.azurecontainerapps.io` |
| `acrjcykdmvrxadbu` | Container registry |
| `law-jcykdmvrxadbu` | Log Analytics workspace |
| `mi-`, `encouragement_api_identity-`, `contacts_api_identity-` | Managed identities |

**Blocker: Postgres `SkuNotAvailable`.** Both deploys failed provisioning
`Standard_B1ms` / `Burstable` in `eastus2`:

> Specified SKU is not supported in this region. Please choose a different SKU.

This is subscription-specific, not regional — the *old* subscription runs exactly that
SKU in exactly that region, and the region's capability API lists `Standard_B1ms` with
no restriction. A fresh Pay-As-You-Go subscription commonly cannot provision Burstable
until quota is granted.

A first hypothesis — that Aspire's pinned `availabilityZone: '1'` was at fault, since
zone numbers are logical per subscription and do not survive a move — was **wrong**. The
pin was removed and the error is unchanged. The fix is still worth keeping on its own
merits (see [findings](#findings-worth-keeping)), but it is not the cause.

**Decision needed before this can proceed:**

1. **Different tier.** `Standard_D2ds_v5` (GeneralPurpose) is the usual fallback and is
   listed as available. Materially more expensive than B1ms — roughly an order of
   magnitude — so this is a cost decision, not just a config change.
2. **Different region.** Keeps the cheap SKU but moves the whole stack, since everything
   else is in `eastus2`.
3. **Request Burstable quota** for the subscription through support, and wait.

Also unresolved: the first deploy's **Docker pushes to the new ACR timed out**
(`net/http: timeout awaiting response headers`) for both `frontend` and `dashboard`.
Untested since, because the second deploy never got past Postgres. May be transient.

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

- Resolve the Postgres SKU decision above and get a server provisioned
- Get the container apps deployed (retry the ACR pushes)
- Verify the stack over the default `*.azurecontainerapps.io` hostnames
- Bind a temporary hostname and exercise end-to-end, including dashboard sign-in
- Rehearsal `pg_dump` / `pg_restore` to size the real one and shake out auth and
  firewall problems while nothing is frozen
- Optionally drop the CNAME TTLs from 300s to 60s to bound rollback time

### Phase 5 — Cutover

1. Freeze writes — scale both APIs to zero replicas
2. Final `pg_dump` of `encouragement` and `contacts`; restore into the new server
3. Repoint the `love.`, `dash.`, and `dev.` CNAMEs at the new environments' default
   domains, then `aws route53 wait resource-record-sets-changed`
4. Add the custom domains to the new apps and request managed certificates. This is the
   TLS window: traffic has moved but no certificate exists for the hostname yet
5. Set the real domain and deterministic certificate names in
   `appsettings.production.json` / `appsettings.dev-b.json` and redeploy — this also
   restores the replica counts frozen in step 1
6. Smoke test: public site loads; dashboard sign-in completes with no `AADSTS` error and
   `/.auth/me` returns the user; both APIs read and write

### Phase 6 — Decommission

- Repoint CI: `manage_github_actions = true` in the entra module, which rewrites the
  `AZURE_*` environment secrets and creates the federated credentials. The old
  `azd pipeline config` identity in `e22c9007…` can then go.
- Delete the old app registration `f32123ed`, if still present.
- Remove the stale TXT values from `asuid.*`.
- Raise the CNAME TTLs back to 300s if they were lowered.
- `terraform destroy` the `default` workspace of `platform` to remove the old vault and
  token store, then promote `client_secret_target` to be the only secret resource in
  `entra` (via `terraform state mv`, not destroy-and-recreate).
- Delete the old `stmynltfstate` state account once its versioned backups are no longer
  wanted.
- Delete the old resource groups, then the old subscription.
- Reconsider `WithAzdResourceNaming()` — see below.

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
- **`az keyvault check-name` is unreliable** — it reported a demonstrably-existing vault
  name as available. Use `dig +short <name>.vault.azure.net` instead.
- **Reading a vault while `az` points at the wrong tenant returns `AKV10032: Invalid
  issuer`**, listing the tenants it will accept — not a permissions error.
- **A custom subdomain cannot be bound until its CNAME already resolves to the target
  environment.** So a new environment must be deployed without its domains, and bound
  afterwards. This is what forces Phase 4 to precede Phase 5 rather than merge with it.
- **An "empty custom domain means skip binding" conditional driven from
  `builder.Configuration["Parameters:customDomain"]` does not work.** It reads non-empty
  during `aspire publish` even with `appsettings.production.json` set to `""`, and it is
  neither user secrets nor a stale build — an unrelated code change in the same publish
  took effect immediately. A compile-time `const bool` does work. The mechanism behind
  Aspire's `Parameters:` resolution at publish time was not identified; this is an open
  question, not a solved one.

## Uncommitted state

Two working-tree edits are deliberate, local, and **must not be committed as they
stand**. Both are backed up in the session scratchpad.

| File | Local deviation | Why it must not ship |
| --- | --- | --- |
| `apphost/appsettings.production.json` | `customDomain`, `certificateName`, `dashboardCustomDomain`, `dashboardCertificateName` emptied; both Key Vault URIs point at `kv-mynl` | CI still deploys to the **old** subscription on push to `main`. Committing this would strip the custom domains off the live production apps. |
| `apphost/AppHost.cs` | `const bool bindFrontendDomain = false;` and `bindDashboardDomain = false` | Same reason — a deploy to the old subscription would unbind `love.` and `dash.` |

The Postgres availability-zone override in `AppHost.cs` is a genuine improvement and
should be committed, but it shares a file with those temporary constants, so the
constants have to be restored to their conditional form first.

## Decisions

1. ~~Who hosts DNS?~~ **AWS Route 53.** Records are scriptable via the AWS CLI (already
   installed, needs authenticating) and are at 300s TTL, so no lead time is required.
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
