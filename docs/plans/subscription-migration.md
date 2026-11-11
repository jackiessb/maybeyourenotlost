# Plan: Migrating to the Microsoft 365 Tenant's Subscription

> **Status (2026-11-11).** Phases 1-3 complete. Phase 4 is partially up and resuming:
> the Postgres SKU blocker is **decided — move to GeneralPurpose** — and the change is
> not yet implemented. See
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

- v16 → v16, so `pg_dump`/`pg_restore` per database with no version concerns. The SKU
  does change — `Standard_B1ms`/Burstable to `Standard_D2ds_v5`/GeneralPurpose — but that
  is irrelevant to a logical dump and restore.
- **Authentication**: the servers use Entra auth and the APIs connect by managed
  identity, so there is no stored password to reuse. Either enable password
  authentication temporarily (per [`environment.md`](../environment.md)) or authenticate
  `pg_dump` with an Entra access token as the password.
- **Firewall**: the running machine's IP must be in the server's allowlist, on both
  source and target.
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
target changes (step 15).

Note this also *swaps* what `rg-dev` means: today it holds production, afterwards it
holds dev. Any saved query, bookmark, or alert scoped to `rg-dev` wants re-checking.

The Aspire environment name `dev-b` is left alone — correcting it means renaming
`appsettings.dev-b.json` and the dev workflow's `ASPIRE_ENVIRONMENT`, which is a separate
change from the resource groups.

## Order of operations

The authoritative sequence from the current state to a decommissioned old subscription.
Phases 1-3 are done. Steps marked **⚠** must not be reordered — the note says what breaks.

### Resume Phase 4

1. Add the GeneralPurpose `Sku` override to the Postgres `ConfigureInfrastructure`
   callback in `AppHost.cs`, next to the existing `AvailabilityZone` override.
2. **⚠ Commit the Postgres changes on their own, before discarding anything else in
   `AppHost.cs`.** Stage selectively — that file also carries the temporary
   `const bool bind*Domain = false` flags, which must not ship. The Postgres override
   exists *only* in the working tree, so a careless `git checkout` on this file destroys
   it. See [Uncommitted state](#uncommitted-state).
3. Leave the temporary flags and the emptied `appsettings.production.json` in place —
   both are still needed for the next step.
4. `aspire deploy` into `Subscription 1` / `rg-prod`. Expect Postgres and the four
   container apps to be created. **⚠ Verify in Azure, not by exit code** — `aspire
   deploy` has already exited 0 with a failed Postgres deployment.
5. Verify the stack over the default `*.azurecontainerapps.io` hostnames.
6. Rehearse `pg_dump` / `pg_restore` while nothing is frozen, to size the real run and
   shake out authentication and firewall problems.

### Optional: validate dashboard sign-in before cutover

7. Sign-in cannot be exercised on the new environment's default hostname as-is: the only
   registered redirect URI is `https://dash.maybeyourenotlost.com/.auth/login/aad/callback`,
   so any other hostname fails with a redirect-URI mismatch. To test it early, add the
   new hostname as a second redirect URI in `infra/terraform/entra` and remove it in
   Phase 6.
8. Given that downtime is acceptable and rollback is a DNS flip, skipping this and
   testing after cutover is a reasonable trade. Decide deliberately rather than by
   default.

### Phase 5 — cutover

9. Freeze writes: scale `encouragement-api` and `contacts-api` to zero replicas **in the
   old subscription**.
10. Final `pg_dump` of `encouragement` and `contacts`; restore into the new server.
11. **⚠ Repoint the `love.` and `dash.` CNAMEs at the new environment's default domain,
    and only then bind the domains.** A custom subdomain cannot be bound until its CNAME
    already resolves to the target environment. Traffic moves here and the TLS window
    opens. Wait with `aws route53 wait resource-record-sets-changed --id <change-id>`.

    **Leave `dev.` alone.** The dev environment is not rebuilt until step 19, so
    repointing `dev.` now would aim it at an environment that does not exist. It moves
    with the rebuild, off the critical path — which is the whole point of
    [decision 4](#decisions).
12. Restore the two `ConfigureCustomDomain` call sites to their unconditional form,
    discard the temporary flags, and set the real values in
    `appsettings.production.json`: the live hostnames, the **deterministic** certificate
    names (`love-cert`, `dash-cert`, `dev-cert` — not the old
    `mc-cae-yudlalf6hm-*` strings), and the `kv-mynl` Key Vault URIs.
13. `aspire deploy` again. This binds the custom domains and issues the managed
    certificates, closing the TLS window.
14. Smoke test: public site loads; dashboard sign-in completes with no `AADSTS` error and
    `/.auth/me` returns the user rather than 404ing; both APIs read and write.

### Phase 6 — decommission

15. **⚠ Repoint CI before merging the cutover commit.** Set
    `manage_github_actions = true` with `github_environments` mapping `production` to
    `rg-prod` and `dev` to `rg-dev`, and `cicd_subscription_id` to the new subscription.
    Merging the cutover commit while CI still targets the old subscription would deploy
    the new configuration there.
16. Merge to `main` so source control matches reality, and confirm a CI run lands in the
    new subscription.
17. Promote the client secret: drop `azurerm_key_vault_secret.client_secret` from the
    `entra` module and make `client_secret_target` the only one, via `terraform state mv`
    rather than destroy-and-recreate. Remove the `azurerm.target` alias and the
    `target_key_vault_*` variables.
18. Drop `secret_writer_principal_ids` and `EXTRA_STATE_PRINCIPALS` — both existed only
    while Entra and the infrastructure were in different tenants.
19. Rebuild the dev environment in the new subscription (empty, no data migration), then
    repoint the `dev.` CNAME and set its hostname and certificate name in
    `appsettings.dev-b.json`. Decide its Postgres SKU here — see
    [decision 7](#decisions).
20. **⚠ Only now delete the old subscription's resources**, and only after the new stack
    has been verified under real use. Until this step the old environments are the
    rollback target: repointing the CNAMEs back is the entire recovery procedure.
21. Remove the stale verification ID from the `asuid.*` TXT records, and raise the CNAME
    TTLs back to 300s if they were lowered.
22. Delete the old app registration `f32123ed`, the legacy
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

**In progress.** `aspire deploy` has been run twice against `Subscription 1` /
`rg-prod`. Infrastructure partially exists; no application is running yet. The blocker
that stopped both runs is now **decided but not implemented** — see
[the SKU decision](#phase-4--deploy-the-application-stack-without-custom-domains)
below.

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

**Resolved: move to GeneralPurpose.** `Standard_D2ds_v5` / `GeneralPurpose` — the
smallest current-generation GeneralPurpose SKU, listed as available in `eastus2` for this
subscription. Chosen over the alternatives (a different region, which would move the
whole stack for a cheaper SKU; or requesting Burstable quota through support and
waiting).

Not yet implemented. The change goes alongside the availability-zone override already in
`AppHost.cs`, on the same `ConfigureInfrastructure` callback:

```csharp
server.Sku = new PostgreSqlFlexibleServerSku
{
    Name = "Standard_D2ds_v5",
    Tier = PostgreSqlFlexibleServerSkuTier.GeneralPurpose,
};
```

Two consequences worth deciding on separately:

- **Cost.** GeneralPurpose is substantially more expensive than `Standard_B1ms` —
  materially so at this project's scale. Check current pricing before committing; do not
  rely on a figure quoted here.
- **The dev environment.** If Burstable is unavailable subscription-wide rather than just
  for this server, the rebuilt dev environment needs GeneralPurpose too, doubling that
  cost for an environment with no production traffic. Worth testing Burstable in dev
  explicitly, and considering whether dev needs its own server at all.

One upside: the 50-connection ceiling on `Standard_B1ms` that the current replica limits
were sized around disappears — a 2-vCore GeneralPurpose server allows far more. The
`MinReplicas` / `MaxReplicas` values in `AppHost.cs` were constrained partly by that cap
and can be revisited once this lands.

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

- Implement the GeneralPurpose SKU override and get a server provisioned
- Get the container apps deployed (retry the ACR pushes)
- Verify the stack over the default `*.azurecontainerapps.io` hostnames
- Optionally exercise dashboard sign-in before cutover — this needs a second redirect
  URI, so it is a deliberate opt-in rather than a free step. See
  [order of operations](#optional-validate-dashboard-sign-in-before-cutover)
- Rehearsal `pg_dump` / `pg_restore` to size the real one and shake out auth and
  firewall problems while nothing is frozen
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

Two files differ from `HEAD`. Parts of those diffs are deliberate temporary edits that
**must not be committed**; other parts are genuine improvements that **should** be. They
are tangled in the same files, so separate them deliberately rather than staging whole
files.

### `apphost/appsettings.production.json` — discard entirely

`customDomain`, `certificateName`, `dashboardCustomDomain` and `dashboardCertificateName`
emptied, and both Key Vault URIs pointed at `kv-mynl`. CI still deploys to the **old**
subscription on push to `main`, so committing this would strip the custom domains off the
live production apps and point them at a vault their managed identity cannot read.

`git checkout -- apphost/appsettings.production.json` restores it; `HEAD` holds the
correct live values.

### `apphost/AppHost.cs` — mixed; keep some, discard some

**Keep** (not yet committed, and worth committing):

- `using Azure.Provisioning.PostgreSql;`
- The `ConfigureInfrastructure` callback on the Postgres resource setting
  `server.AvailabilityZone = ""`
- The GeneralPurpose `Sku` override, once added

**Discard**:

- `const bool bindFrontendDomain = false;` / `bindDashboardDomain = false` and the two
  `if (...)` blocks wrapping `app.ConfigureCustomDomain(...)`

Note what `HEAD` actually contains: two plain, unconditional `ConfigureCustomDomain`
calls and **no Postgres configuration at all**. There is no committed conditional form to
restore to — the config-driven conditional never worked (see
[findings](#findings-worth-keeping)) and was never committed. Restoring means returning
those two call sites to their unconditional form, not reinstating a conditional.

A scratchpad copy of both files exists but is session-local and will not survive. `HEAD`
is the real recovery path for `appsettings.production.json`; the Postgres override in
`AppHost.cs` exists **only in the working tree**, so commit it before discarding
anything in that file.

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
   **GeneralPurpose `Standard_D2ds_v5`.** See
   [Phase 4](#phase-4--deploy-the-application-stack-without-custom-domains); the dev
   environment's SKU and the revisited replica limits remain open sub-questions.

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
