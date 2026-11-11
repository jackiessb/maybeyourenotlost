# Plan: Migrating to the Microsoft 365 Tenant's Subscription

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

> **Do not simply repoint the existing tfvars and apply.** The `platform` state tracks
> `kv-mynl-platform` and the token store *in the old subscription*, and the live
> dashboard reads its secrets from that vault. Changing `subscription_id` in place makes
> Terraform either plan to destroy those resources — breaking sign-in — or silently keep
> managing the old ones and never create the new. The two deployments must have
> **separate state**.

Use a Terraform workspace so both coexist until Phase 6:

```sh
cd infra/terraform/platform
git mv terraform.tfvars old.tfvars        # stop auto-loading; always be explicit
terraform workspace new target
terraform apply -var-file=target.tfvars   # new tenant + subscription
```

`target.tfvars` carries `tenant_id = aac88807…` and
`subscription_id = 20aad6af…`, and omits `secret_writer_principal_ids` — that grant
exists only because Entra and the infrastructure were in different tenants. Once both
are in `aac88807…` one identity covers everything, and the MFA and guest-object friction
from the first apply disappears. `EXTRA_STATE_PRINCIPALS` likewise becomes unnecessary.

Renaming `terraform.tfvars` matters: it is auto-loaded in *every* workspace, so leaving
it in place would silently merge old-subscription values into the target apply. With it
renamed, forgetting `-var-file` is an immediate error about missing required variables
rather than a wrong-target apply. Both files are gitignored by the existing `*.tfvars`
rule.

The `default` workspace keeps managing the old deployment, which stays the rollback
target and is torn down with `terraform destroy` in Phase 6.

### Phase 3 — Write the client secret into the new vault

**The app registration itself does not change** — no new client ID, no re-assignment of
users, the redirect URI is unchanged. Only the secret's destination moves.

> **The same destroy trap applies here.** `key_vault_id` is ForceNew on
> `azurerm_key_vault_secret`, so editing it in place plans to *delete* the client secret
> from the old vault and recreate it in the new one. The live dashboard is still reading
> the old vault at that point, so that deletion breaks sign-in.

The secret has to exist in **both** vaults across the cutover. The smallest change that
achieves it: add a second, count-gated resource for the target vault rather than editing
the existing one.

```hcl
variable "target_key_vault_id" {
  description = "Second vault to receive the client secret during the migration. Empty disables."
  type        = string
  default     = ""
}

resource "azurerm_key_vault_secret" "client_secret_target" {
  count = var.target_key_vault_id == "" ? 0 : 1

  name            = var.client_secret_name
  value           = azuread_application_password.dashboard.value
  key_vault_id    = var.target_key_vault_id
  content_type    = "entra-client-secret"
  expiration_date = azuread_application_password.dashboard.end_date
}
```

A second `azurerm` provider alias is needed for the target subscription, since the
existing one is pinned to the old vault's. At Phase 6, delete the original resource and
variable and promote the target to be the only one — a `terraform state mv` keeps that
from being a destroy-and-recreate.

Deliberately *not* done with `for_each` over a map of vaults: that is tidier, but
converting the existing single resource into a keyed one requires `terraform state mv`
on a live secret, which is more risk than the duplication saves.

### Resource group naming

The current names are inverted — `rg-dev` holds production, `rg-dev-b` holds dev. The
migration corrects this to **`rg-prod` for production and `rg-dev` for dev**.

This is nearly free *because* of the migration. Azure cannot rename a resource group in
place; the alternative is creating new ones and moving resources, which not every
resource type supports. Creating them fresh in the new subscription sidesteps that
entirely.

**Do not change `AZURE_RESOURCE_GROUP` before Phase 4.** The workflows read the resource
group from that environment secret, and azd creates what it does not find — so pointing
the old subscription at `rg-prod` would not fail, it would quietly provision a second
copy of production alongside the real one. The secret changes only when the deploy target
changes.

Note this also *swaps* what `rg-dev` means: today it holds production, afterwards it
holds dev. Any saved query, bookmark, or alert scoped to `rg-dev` wants re-checking.

The Aspire environment name `dev-b` is left alone — correcting it means renaming
`appsettings.dev-b.json` and the dev workflow's `ASPIRE_ENVIRONMENT`, which is a separate
change from the resource groups.

### Phase 4 — Deploy the application stack, without custom domains

`aspire deploy` into the new subscription with the custom domain and certificate
parameters **left empty**. (Main already carried `dashboardCertificateName: ""`, so the
empty shape is known to work; verify `ConfigureCustomDomain` tolerates it, and skip the
call outright if it does not.)

This provisions the managed environment, both APIs, frontend, dashboard, Postgres, and
the auth config. Verify the whole stack over the default
`*.azurecontainerapps.io` hostnames.

Then bind a **temporary hostname** — say `new.maybeyourenotlost.com` — get a managed
certificate for it, and exercise everything end-to-end including dashboard sign-in. This
is the step that de-risks the migration: it proves the new stack works before any
user-visible change, leaving only the DNS flip itself untested.

Also in this phase, with no user impact:

- Add the new subscription's `customDomainVerificationId` as an **additional** TXT value
  on `asuid.love`, `asuid.dash`, and `asuid.dev`
- Optionally drop the CNAME TTLs from 300s to 60s, to bound rollback time
- Do a rehearsal `pg_dump`/`pg_restore` to size the real one and shake out auth and
  firewall problems while nothing is frozen
- Authenticate the AWS CLI (`aws login`) so the cutover is not waiting on it

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
