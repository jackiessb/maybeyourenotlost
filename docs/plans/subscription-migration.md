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
| DNS | **External** — no Azure DNS zone exists; all records are managed at the registrar/provider |
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

## Hard problem 1: the DNS and certificate chicken-and-egg

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

Two options, and this is a decision to make before executing:

- **Accept a brief TLS window.** Lower the CNAME TTLs to 60s *at least one old-TTL
  period in advance* (the TTL reduction itself propagates at the old TTL), then flip and
  immediately request the managed certificates. The window is however long issuance
  takes — usually a few minutes, occasionally longer. Acceptable for `dash.`
  (admin-only, one user) and `dev.`; the judgement call is `love.`, the public site.
- **Bring your own certificate for zero downtime.** Obtain a certificate for the
  hostnames out-of-band — Let's Encrypt with DNS-01 validation works and does *not*
  require the CNAME to point anywhere — upload it to the new environment, and bind the
  custom domains **before** the DNS flip. The flip is then instantaneous and clean. You
  can swap to managed certificates afterwards at leisure. Cost is handling one
  certificate manually.

Azure's managed certificates cannot be exported, so there is no option to carry the
existing ones across.

## Hard problem 2: Postgres data and the write window

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

Options for the write window:

- **Accept it.** Do the cutover during a quiet hour and accept that a submission in the
  gap is lost. Simplest, and probably proportionate.
- **Freeze writes.** Scale the APIs to zero replicas, or return maintenance responses,
  for the duration of the final dump. Honest downtime instead of silent loss.
- **Dump twice.** A full dump beforehand to size and rehearse the restore, then a second
  short dump of only what changed at cutover. Reduces the window, adds complexity.

## Phases

Phases 1–4 are fully reversible and invisible to users: they build the new stack
alongside the old one and change nothing about what serves traffic. Phase 5 is the
cutover.

### Phase 1 — Bootstrap the target subscription

```sh
./infra/bootstrap-subscription.sh 20aad6af-afbd-4c72-a48d-59ae01ca2cb2 \
  aac88807-ec5d-4c7a-8379-0f2baf8123e0
```

Registers the eight providers (`Subscription 1` is empty, so expect most to be
unregistered — `Microsoft.KeyVault` was missing even on the *used* subscription) and
provisions Terraform state storage in the target. State currently lives in the old
subscription and must move with everything else; `terraform init -migrate-state` moves
it once the new container exists.

### Phase 2 — Platform layer in the target

Repoint `infra/terraform/platform/terraform.tfvars` at the new tenant and subscription,
then apply. Creates a second Key Vault and token store. The existing ones keep serving
production until cutover.

Drop `secret_writer_principal_ids` and `EXTRA_STATE_PRINCIPALS` at this point — both
exist only because Entra and the infrastructure were in different tenants. Once both are
in `aac88807…`, one identity covers everything, and the MFA/guest friction from the
first apply disappears.

### Phase 3 — Re-point the Entra layer at the new vault

Update `key_vault_id`, `key_vault_tenant_id`, and `key_vault_subscription_id` in
`infra/terraform/entra/terraform.tfvars` and apply. Writes the existing client secret
into the new vault. **The app registration itself does not change** — no new client ID,
no re-assignment of users, and the redirect URI is unchanged.

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
- Lower the CNAME TTLs to 60s, at least one old-TTL period before cutover
- Do a rehearsal `pg_dump`/`pg_restore` to size the real one

### Phase 5 — Cutover

1. Begin the write freeze, if that option was chosen
2. Final `pg_dump` of `encouragement` and `contacts`; restore into the new server
3. If using BYOC: bind the real hostnames with the uploaded certificate **now**, before DNS
4. Repoint the `love.`, `dash.`, and `dev.` CNAMEs at the new environments' default domains
5. If using managed certificates: request them now; this is the TLS window
6. Set the real domain and deterministic certificate names in
   `appsettings.production.json` / `appsettings.dev-b.json` and redeploy, so source
   control matches reality
7. Smoke test: public site loads; dashboard sign-in completes with no `AADSTS` error and
   `/.auth/me` returns the user; both APIs read and write

### Phase 6 — Decommission

- Repoint CI: `manage_github_actions = true` in the entra module, which rewrites the
  `AZURE_*` environment secrets and creates the federated credentials. The old
  `azd pipeline config` identity in `e22c9007…` can then go.
- Delete the old app registration `f32123ed`, if still present.
- Remove the stale TXT values from `asuid.*`.
- Raise the CNAME TTLs back.
- Delete the old resource groups, then the old subscription.
- Reconsider `WithAzdResourceNaming()` — see below.

## Decisions needed before executing

1. **Who hosts DNS?** Not Azure. This determines whether record changes can be scripted
   or must be clicked, and how much lead time the TTL reduction needs.
2. **Zero-downtime (BYOC) or a brief TLS window?** Possibly different answers for
   `love.` than for `dash.`/`dev.`
3. **Write-freeze strategy** for the Postgres cutover: accept loss, freeze, or dump twice.
4. **Migrate the dev environment or rebuild it empty?** Rebuilding is recommended —
   there is no dev data worth carrying, and it halves the cutover work.
5. **`WithAzdResourceNaming()`** on `AppHost.cs:9`. Tempting to drop for clean naming in
   a fresh subscription, but it is a single global setting affecting *both* environments,
   and changing it while the old subscription still serves traffic would try to rename
   live resources. **Leave it alone until the old subscription is decommissioned**, then
   decide.

## Rollback

Phases 1–4 roll back by deleting what was created in the target subscription; nothing
user-visible has changed. Phase 5 is different:

- **Before the DNS flip**: abandon freely.
- **After the DNS flip**: roll back by repointing the CNAMEs at the old environments,
  which still exist and still hold valid certificates. This is why the old subscription
  is not deleted until Phase 6 — it is the rollback target, and the 60s TTL set in
  Phase 4 is what makes the reversal quick.
- **Writes that landed on the new stack** after cutover will not exist on the old
  server. A rollback after real traffic means reconciling those by hand, so the decision
  point is short: verify quickly, then commit.
