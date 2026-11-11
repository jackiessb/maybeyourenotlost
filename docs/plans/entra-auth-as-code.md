# Plan: Bringing Entra ID / Easy Auth Under Infrastructure as Code

## Why

Setting up sign-in for the MYNL Dashboard required a long sequence of manual, one-off
`az`/Graph calls against the Azure subscription and its Entra tenant: inviting guest
users, flipping app registration settings, generating a client secret, provisioning a
storage account for session persistence, wiring all of that into a Container App, and
turning on diagnostic logging. None of it is reproducible from source control. If this
subscription were lost, or if the same dashboard needed to exist in a second Azure
environment (a true second tenant, or a second subscription under the same tenant),
someone would have to re-derive all of this from memory or from this document.

This plan inventories exactly what was done by hand, what's already codified, what
isn't, and what it would take to close the gap.

> **Status (2026-11-11): done and verified in production.** The Entra layer and both
> secrets are provisioned by Terraform (`infra/terraform`), the dashboard's auth config
> comes from `AppHost.cs`, and sign-in works against the Microsoft 365 tenant. Live
> state confirmed: both Container App secrets are Key Vault references resolved by the
> app's system-assigned identity, the issuer is
> `https://login.microsoftonline.com/aac88807-.../v2.0`, `tokenStore.enabled` is true,
> and `/.auth/me` returns the signed-in user. What remains is the subscription
> migration — see [consolidation](#tenant-and-subscription-consolidation).

## The working configuration (confirmed end-to-end this session)

After a lot of trial and error, login to the dashboard now works. The final, verified
working shape is:

- App registration's redirect URI lives under the **`web`** platform (not `spa`):
  `https://dash.maybeyourenotlost.com/.auth/login/aad/callback`.
- `web.implicitGrantSettings.enableIdTokenIssuance = true`.
- A client secret exists on the app registration and is stored as a Container App
  secret (`aad-client-secret`), referenced by the auth config's
  `clientSecretSettingName`.
- A Storage Account (`stmynldashauth`, `rg-dev`) with a private blob container
  (`easyauth-tokens`) backs the Easy Auth **token store**. A long-lived SAS URL to
  that container is stored as a second Container App secret (`tokenstore-sas`) and
  referenced by `--sas-url-secret-name` / the token store config.
- Token store is enabled (`login.tokenStore.enabled = true`).

All four of these pieces are required together. Each one alone produces a different
failure mode — see [What broke along the way](#what-broke-along-the-way-and-why-each-piece-is-required) for the
full chain, since it explains *why* the IaC has to provision all four, not just the
parts that look obviously necessary.

## What's already in code today

`apphost/AppHost.cs` (Aspire AppHost, compiled to Bicep via `Azure.Provisioning` at
`aspire deploy` / `azd deploy` time) already provisions:

- The Container App itself, scaling rules, and custom domain binding
  (`app.ConfigureCustomDomain(dashboardCustomDomain, dashboardCertificateName)`).
- A `ContainerAppAuthConfig` resource wiring the Container App to Azure AD, driven by
  two **externally supplied** parameters: `dashboardEntraClientId` and
  `dashboardEntraTenantId`. These come from the azd environment (`.azure/<env>`,
  gitignored) — i.e. someone ran `azd env set` by hand after creating the app
  registration out of band.

The existing code's comment is now **stale and should be corrected**:

> No client secret is configured, so sign-in uses the ID token flow. Who may sign in
> is controlled by "Assignment required" on the app registration's Enterprise
> Application.

That was the original design intent, and it does not work: without a client secret,
Easy Auth can't populate its token store, `/.auth/me` 404s after every successful
login, and the dashboard's client-side auth check bounces the user back to the login
screen in a loop no matter how many times the sign-in itself succeeds. **The decision
is now made** — the working design uses a client secret, a `web`-platform redirect
URI, and a real (storage-backed) token store. `AppHost.cs`'s `ContainerAppAuthConfig`
block and its comment need to be updated to match once this is ported to IaC; see
[the gap layer-by-layer](#the-gap-layer-by-layer) below for what that means concretely.

## What broke along the way (and why each piece is required)

This is worth preserving because each failure looked like a complete fix at the time,
and each gap is independently necessary:

1. **No client secret, `enableIdTokenIssuance = false`** → `AADSTS700054` ("response_type
   'id_token' is not enabled"). Fixed by enabling `enableIdTokenIssuance`.
2. **No client secret, `enableIdTokenIssuance = true`** → login completes
   (`LoginComplete: Authenticated: true` in the logs) but `/.auth/me` 404s every time,
   because there's no client credential to let Easy Auth do a real token exchange or
   populate a token store. This is what actually caused the "click login, get bounced
   right back" symptom — the AAD handshake was succeeding the whole time.
3. **Client secret added, redirect URI still under `spa` platform** →
   `AADSTS9002325` ("Proof Key for Code Exchange is required for cross-origin
   authorization code redemption"). Adding a secret makes Easy Auth attempt a
   server-side (confidential-client) authorization code exchange, but Entra requires
   PKCE for any code redemption tied to a `spa`-platform redirect URI, and Easy Auth's
   server-side exchange doesn't supply one. Fixed by moving the redirect URI to the
   `web` platform.
4. **Client secret + `web`-platform redirect URI, but token store still disabled** →
   login now succeeds cleanly every time, but `/.auth/me` *still* 404s. The client
   secret only unblocks the code exchange; `tokenStore.enabled` is a wholly separate
   flag that was never set. Fixed by `az containerapp auth update --token-store true`.
5. **Enabling the token store requires a backing store** — the CLI refused a plain
   `--token-store true` with `only blob storage token store is supported`, because
   Container Apps can scale to multiple replicas and a filesystem-backed store
   wouldn't be shared between them. Required standing up a new Storage Account +
   blob container + SAS URL that didn't exist in the subscription at all.

## What's manual today (the full list)

Everything below was done directly against the subscription/tenant with no record in
source control:

1. **App registration existed before this session** (`MYNL Dashboard`,
   `f32123ed-18c2-4740-b4df-c1e78c80aad1`), including `signInAudience: AzureADMyOrg`.
   Who/what created it, and how, is undocumented.
2. **`enableIdTokenIssuance` flipped to `true`** on the app registration via a Graph
   PATCH, to unblock `AADSTS700054`.
3. **The redirect URI moved from the `spa` platform to the `web` platform** via a
   Graph PATCH, to unblock `AADSTS9002325` once a client secret was in play.
4. **A B2B guest invitation sent** via `POST /v1.0/invitations` for
   `jackson@maybeyourenotlost.com` into the Default Directory tenant
   (`e22c9007-0f6b-44b6-a403-af91c309278d`) — the tenant that owns the app
   registration, which is a *different* Entra tenant than the one backing the
   Microsoft 365 instance (`aac88807-ec5d-4c7a-8379-0f2baf8123e0`) where the actual
   mailboxes/users live. Every M365 user that needs dashboard access needs this same
   invitation, one at a time, by hand.

   **Superseded.** The app registration now moves to the M365 tenant, where those
   users are native members. Invitations stop existing as a concept — see
   [Tenant and subscription consolidation](#tenant-and-subscription-consolidation).
5. **A client secret generated** (`az ad app credential reset --append`, 2-year
   expiry) and stored as a Container App secret (`aad-client-secret`), then wired into
   the auth config via `az containerapp auth microsoft update --client-secret-name`.
   This secret isn't tracked anywhere — if it expires or is lost, nothing in source
   control says how it was produced or how to replace it.
6. **A Storage Account + blob container created from scratch** (`stmynldashauth`,
   container `easyauth-tokens`, `rg-dev`) — this subscription had *no* storage
   accounts at all beforehand. A 2-year container SAS was generated and stored as a
   second Container App secret (`tokenstore-sas`).
7. **Token store enabled** via `az containerapp auth update --token-store true
   --sas-url-secret-name tokenstore-sas`.
8. **`Microsoft.Insights` and `Microsoft.Storage` resource providers registered** on
   the subscription (one-time subscription-level prerequisites with no Bicep/Aspire
   equivalent in this repo — both had to be discovered by hitting
   `InvalidAuthenticationToken` / `SubscriptionNotFound` errors on otherwise-correct
   commands).
9. **Two diagnostic settings created by hand**, one per Container Apps managed
   environment (`cae-yudlalf6hmivo` → `law-yudlalf6hmivo` in `rg-dev`, and
   `cae-jgbowniw3fqck` → `law-jgbowniw3fqck` in `rg-dev-b`), each shipping
   `ContainerAppConsoleLogs`, `ContainerAppSystemLogs`, and `ContainerAppHTTPLogs` to
   that environment's existing Log Analytics workspace. Nothing in `AppHost.cs`
   creates these, despite `AddAzureContainerAppEnvironment` already creating the
   managed environment and (per `docs/environment.md`'s naming note) the Log Analytics
   workspace existing per-environment already.

## The gap, layer by layer

### 1. Entra ID / Microsoft Graph layer — not in IaC at all

This is the layer with the least existing coverage, and it's the one Bicep has
historically had the weakest story for, because ARM doesn't model Graph objects
(applications, service principals, invitations) as first-class resource types.
Two options were considered:

- **Terraform's `azuread` provider.** Already a recognized tool in this repo — the
  root `.gitignore` already has Terraform entries (`.terraform/`, `*.tfstate`,
  `*.tfvars`) even though no `.tf` files exist yet. Would model:
  - `azuread_application` (display name, `sign_in_audience`, **`web` platform**
    redirect URIs — not `spa`, per the confirmed-working config —
    `web.implicit_grant.id_token_issuance_enabled`)
  - `azuread_service_principal` (+ `app_role_assignment_required = true`, matching
    the "Assignment required" behavior the current code comment assumes)
  - `azuread_application_password` for the client secret (see
    [secrets](#2-secrets--the-client-secret-and-the-token-store-sas) below)
  - `azuread_app_role_assignment` per permitted user
- **Bicep's `Microsoft.Graph` extension** (currently preview). Lets Graph resources
  live alongside the ARM Bicep that Aspire already generates, avoiding a second
  toolchain. Less mature; worth a spike before committing to it given this repo's
  deploys are driven by `aspire deploy`, not a hand-written Bicep root.

**Resolved: Terraform, run as a separate prior step.** Aspire has no extension point
for Graph calls, and the alternative — shelling out to `az`/Graph REST from a C#
`IResourceWithPostInit`-style hook — fights the grain of the tool and gives up
idempotency and plan-diffing for nothing. The Bicep `Microsoft.Graph` extension stays
unattractive while it is preview and while this repo has no hand-written Bicep root.

Written: [`infra/terraform/entra/`](../../infra/terraform/entra). The module encodes
the non-obvious parts of the working configuration as comments next to the settings
that enforce them, including which AADSTS code each one prevents.

One consequence of the two-tenant split: `azuread` authenticates against the M365
tenant and `azurerm` against whichever subscription holds the infrastructure, so no
single `az login` covers a full run and both tenant IDs are explicit variables rather
than inherited from ambient CLI state. This matters more than it sounds — an `az ad`
command aimed at the wrong directory reports the app as not found, which reads like a
permissions problem.

### 2. Secrets — the client secret *and* the token store SAS

There are now two sensitive values that must never land in a `.tf` file, a `.bicep`
parameter file, or a GitHub Actions log: the AAD client secret and the blob storage
SAS URL. The realistic pattern for both:

1. Terraform creates the `azuread_application_password` (client secret) and the
   storage account's container SAS, writing each directly into Key Vault
   (`azurerm_key_vault_secret`) — never into a `.tfvars` file, a Bicep parameter
   file, or a CI log. Both values *do* land in Terraform state in cleartext, which
   is unavoidable and the reason both modules want the `azurerm` remote backend
   rather than local state on a laptop.
2. The Container App's `aad-client-secret` and `tokenstore-sas` settings become
   **Key Vault references** — the Container App's system-assigned managed identity
   gets a Key Vault `get` RBAC role, and both `ContainerAppAuthConfig`'s
   `clientSecretSettingName` and the token store's SAS setting point at secrets
   backed by `secretRef` → Key Vault, not raw values.
3. Secret rotation — **decided**: a 2-year expiry was used ad hoc for both values
   this session. Both are now driven by a `time_rotating` resource, so rotation
   happens on `apply` once the window rolls over: 365 days for the client secret,
   180 for the SAS. Each credential's expiry is set past its rotation cadence (30
   days of grace for the secret) so a missed apply degrades into a warning window
   instead of an outage, and each Key Vault secret carries a matching
   `expiration_date` so the vault can drive alerting.

   The SAS is the more dangerous of the two to let lapse, because its failure mode
   (token store unreachable, `/.auth/me` 404ing) is indistinguishable from the
   original bug this whole investigation was chasing — an expiry would present as a
   regression in the auth config. Hence the shorter window.

### 3. Dashboard access control

Moving the app registration into the M365 tenant deletes the guest-invitation
problem outright: the users who need the dashboard are native members of that
directory, so there is no `POST /v1.0/invitations`, no guest object, and no
per-person Graph call. What replaces it is a list of UPNs in
`entra/terraform.tfvars`, fed into a `for_each` over `azuread_app_role_assignment`.

**This makes "Assignment required" load-bearing rather than belt-and-suspenders, and
that is the single most important consequence of the move.** Under the old
arrangement the de facto gate was "has someone invited you into the Default Directory
tenant" — a manual step that happened to be restrictive. In the M365 tenant, *every
member can authenticate against the app by default*. The only remaining gate is
`app_role_assignment_required = true` plus the explicit assignment list.

`AppHost.cs`'s comment already claimed this was the access control mechanism, but
nothing in this session's work ever verified it was enforced. It must be confirmed
set **before** the client ID and tenant ID are repointed, not after — otherwise the
window between the two is an admin dashboard open to the whole organization.

Being a member of the tenant and being assigned to the app remain two different
gates. The difference is that only the second one is still ours to control.

On automation: adding a user stays a reviewed `terraform plan` diff rather than
something triggered by M365 user creation. This is access to an admin dashboard —
automate the *mechanism*, not the *decision*.

### 4. Azure resource layer — mostly covered, three gaps

- Container App + custom domain + auth config: **already in `AppHost.cs`**, but the
  `ContainerAppAuthConfig` block needs updating to add `clientSecretSettingName`
  (Key Vault-backed, see above) and the token store configuration — today it only
  sets up `identityProviders.azureActiveDirectory` with no secret and no `login`
  block at all.
- **Storage Account + blob container for the token store** — didn't exist anywhere
  in the subscription before this session. An earlier draft of this plan proposed
  modeling it in `AppHost.cs` via `Azure.Provisioning.Storage` (already a transitive
  dependency of the AppHost project). **That is superseded**: it now lives in
  [`infra/terraform/platform/`](../../infra/terraform/platform) alongside the Key
  Vault, for two reasons. The SAS has to exist in the vault *before* the auth config
  can reference it, which puts it earlier in the ordering than `aspire deploy`; and a
  SAS on a deliberate 180-day rotation should not be regenerated by every deploy.
  Keeping both secrets out of the Aspire/Bicep path entirely is the simpler
  invariant.
- Diagnostic settings (`ContainerAppConsoleLogs`/`SystemLogs`/`HTTPLogs` → Log
  Analytics): **not in `AppHost.cs`**, despite the environment and workspace already
  existing through `AddAzureContainerAppEnvironment`. `Azure.Provisioning.Insights`
  (or a raw construct emitting `Microsoft.Insights/diagnosticSettings`) can attach
  this directly to the `cae` resource, right next to where `ContainerAppAuthConfig`
  is added today. This should apply to *every* environment, not just the one hosting
  the dashboard, so it belongs near `AddAzureContainerAppEnvironment("cae")` itself
  rather than inside the dashboard-specific `if (includeDashboard)` block.

### 5. Subscription-level prerequisites

`Microsoft.Insights` and `Microsoft.Storage` provider registrations are one-time,
subscription-wide operations that don't belong in a per-deploy pipeline
(re-registering an already-registered provider is a harmless no-op, but it's still
not a "resource" Aspire provisions, and registration takes a minute or two to
propagate — both were discovered reactively, by hitting opaque errors
`InvalidAuthenticationToken` / `SubscriptionNotFound` on otherwise-correct commands).
Written as [`infra/bootstrap-subscription.sh`](../../infra/bootstrap-subscription.sh),
run once per *new subscription*. It registers the eight providers this stack actually
needs (not just the two discovered reactively), waits for propagation, and provisions
the Terraform state storage account with versioning enabled. Idempotent, so re-running
it is harmless.

Registering proactively matters more on a new subscription than it did here: a fresh
subscription has almost nothing registered, and any module touching diagnostic
settings, storage, Key Vault, or Postgres hits the same wall.

## Tenant and subscription consolidation

The goal is for everything — Entra configuration and Azure infrastructure — to live
under the tenant that owns the Microsoft 365 instance
(`aac88807-ec5d-4c7a-8379-0f2baf8123e0`), billed to the organization email, so the
personal-account subscription in the Default Directory tenant
(`e22c9007-0f6b-44b6-a403-af91c309278d`) can be abandoned.

### The target already exists

A tenant is an Entra directory; subscriptions hang off a tenant, and Microsoft 365
licensing bills separately from Azure — so an M365 tenant having no Azure subscription
is the common case. That is not the case here. Confirmed in the tenant directly:

| | |
| --- | --- |
| Subscription | `Subscription 1` — `20aad6af-afbd-4c72-a48d-59ae01ca2cb2` |
| State | Enabled, Pay-As-You-Go, spending limit off |
| Billing account | `Maybe You're Not Lost` (Microsoft Customer Agreement) |
| Resource groups | **none — the subscription is empty** |
| This account's RBAC | **Owner** at subscription scope |
| This account's directory role | **Global Administrator** in `aac88807…` |

So there is nothing to create and no one to ask. An empty subscription under the right
tenant, already owned, is the ideal migration target — a fresh `aspire deploy` lands in
clean space with no name collisions against the old environment.

One thing still worth eyeballing in the portal: the billing account is
MCA-*Individual*, i.e. a self-serve signup rather than an enterprise agreement. Its
display name is the organization, but confirm the payment method on file is the
business card rather than a personal one — directory association and billing ownership
are separate properties, which is the same distinction that rules out a directory
transfer below.

### Why a new subscription, not a directory transfer

Changing an existing subscription's directory is a supported operation and looks
attractive: resource IDs survive, data survives, no DNS cutover, no migration. Two
things rule it out here.

**It would not achieve the actual goal.** Billing ownership and directory association
are separate properties of a subscription. Transferring the directory moves which
tenant authenticates against the subscription; it leaves the payment instrument and
billing account on the personal Microsoft account. Abandoning the personal account
requires a subscription whose billing belongs to the organization, which means a new
subscription (or a separate billing-ownership transfer) regardless.

**Its blast radius is the worst case for this repo.** A directory transfer deletes
every identity-bound thing in the subscription:

- All RBAC role assignments, without exception — they reference principals that no
  longer exist in the new directory
- System-assigned managed identities get new principal IDs, and must be disabled and
  re-enabled with every downstream grant redone
- User-assigned managed identities must be recreated outright
- Key Vault needs its `tenantId` property rewritten and all policies/RBAC rebuilt
- Postgres Flexible Server's Entra admin points at an old-tenant principal and breaks

`docs/architecture.md` describes the entire data-access story as managed-identity
based, wired by the `WithReference(encouragementDb)` / `WithReference(contactsDb)`
calls in `AppHost.cs`. A directory transfer breaks precisely that. Worse,
`WithAzdResourceNaming()` on `AppHost.cs:9` pins resource names to what azd already
provisioned, so a subsequent `aspire deploy` would try to reconcile resources that
look provisioned but are no longer functional, rather than rebuild them cleanly.

### What the move actually requires

The infrastructure is already nearly reproducible — that is the premise of this whole
document. Everything in `AppHost.cs` regenerates from a fresh `aspire deploy` into a
new subscription: Container Apps environment, both APIs, frontend, dashboard, Postgres
server and both databases, scaling rules, custom domain bindings, auth config. The
migration is therefore mostly a matter of what *doesn't* regenerate:

1. **Postgres data.** The `encouragement` and `contacts` databases, via
   `pg_dump`/`pg_restore`. The only genuinely stateful thing that matters — the token
   store's blob contents are disposable by nature.
2. **DNS and managed certificates — the fiddliest part.** Three hostnames
   (`love.`, `dev.`, `dash.`). Container Apps managed certificates have a
   chicken-and-egg: the certificate can only be issued once the CNAME points at the
   new environment, but repointing the CNAME *is* the cutover. Either accept a brief
   certificate-error window or stage through a temporary hostname first.
3. **The hardcoded certificate names.** `apphost/appsettings.production.json` pins
   `mc-cae-yudlalf6hm-love-maybeyouren-7639` and
   `mc-cae-yudlalf6hm-dash-maybeyouren-6840`. Both encode the current environment
   (`cae-yudlalf6hm…`) and are guaranteed edits.
4. **The `WithAzdResourceNaming()` decision.** Keep it and carry meaningless generated
   names like `cae-yudlalf6hmivo` into the new tenant, or drop it for clean naming.
   Dropping it is cleaner but renames every resource, which cascades straight back
   into item 3.
5. **Subscription bootstrap.** `infra/bootstrap-subscription.sh`, before anything else.
6. **GitHub OIDC.** `deploy-prod.yml:71-76` and its dev counterpart authenticate with
   `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID`, plus
   `AZURE_RESOURCE_GROUP`. All change. Needs a new federated-credential app
   registration in the M365 tenant and updated secrets in both GitHub environments.
7. **Dev is disposable.** Two environments exist (`cae-yudlalf6hmivo`/`rg-dev` and
   `cae-jgbowniw3fqck`/`rg-dev-b`). Rebuild dev empty rather than migrating it.

Expect a short window paying for both subscriptions in parallel — mostly the Postgres
B1ms instances.

### Sequencing

The app registration moves first, on its own:

- It is the only piece that moves with **zero code changes** — `AppHost.cs` consumes
  `dashboardEntraClientId` and `dashboardEntraTenantId` as plain parameters, and
  `dashboardEntraTenantId` is used only to interpolate the OIDC issuer URL. Nothing
  in `ContainerAppAuthConfig` is an ARM cross-tenant reference.
- Rollback is editing two values in `appsettings.production.json`.
- It proves M365-tenant identities work for dashboard sign-in before a subscription
  migration is staked on that assumption.
- It means the eventual subscription move does not *also* have to repoint auth.

Note that an app registration cannot be transferred between tenants. This is
create-new-in-M365, repoint, delete-old — so a new client ID and a new client secret,
with the redirect URI string unchanged. Keep the old registration alive until the new
one is verified.

Both prerequisites for the subscription half are already satisfied — Global
Administrator in the tenant and Owner on an empty subscription under it — so the
sequencing is a choice about risk appetite, not a dependency chain. Moving the app
registration first is still worth it for the cheap rollback and the early signal.

## Open decisions before writing any code

1. ~~Keep the client secret + token store, or go back to the ID-token-only design?~~
   **Resolved**: client secret + `web`-platform redirect URI + storage-backed token
   store is the confirmed-working design. `AppHost.cs` and its comment should be
   updated to match.
2. ~~Is "another Azure instance" a new subscription in the same Entra tenant, or a
   genuinely separate tenant?~~ **Resolved, as neither.** The target is a new
   subscription under the M365 tenant, so the Entra layer and the Azure layer
   converge there. The two-tenant split is a transition state, not an architecture;
   see [consolidation](#tenant-and-subscription-consolidation).
3. ~~Automated or human-gated guest invitations?~~ **Resolved, and the question
   dissolves.** Guest invitations disappear once the app registration lives in the
   M365 tenant. What remains is a reviewed list of app role assignments, applied by
   `terraform plan`/`apply` with a human reading the diff.
4. ~~Does the M365 tenant permit app registration and subscription creation, with
   this account holding the necessary roles?~~ **Resolved: yes, all of it.** Global
   Administrator in `aac88807…`, and Owner on an existing empty pay-as-you-go
   subscription (`20aad6af-afbd-4c72-a48d-59ae01ca2cb2`) already under that tenant.
   No escalation, no subscription creation, no billing transfer required.

## Runbook for standing this up in a new Azure instance

The first run is four phases, because the Container App's managed identity cannot be
granted vault access before the Container App exists, and the auth config cannot
resolve secrets before the vault holds them. Only phases 1 and 3 recur.
`infra/terraform/README.md` carries the commands.

0. **Subscription bootstrap**: `./infra/bootstrap-subscription.sh <subscription-id>
   [tenant-id]`. Resource providers and Terraform state storage. Once per
   subscription, before anything else — registrations take a couple of minutes to
   propagate and otherwise fail a deploy partway through with a confusing error.
1. **`terraform apply` the platform module**: Key Vault, token store storage account,
   blob container, SAS written straight to the vault.
2. **`terraform apply` the entra module** against the M365 tenant: app registration
   with its redirect URI under the `web` platform, service principal with
   `app_role_assignment_required`, client secret written straight to the vault, app
   role assignments for the permitted users.
3. **Write the entra outputs** (`dashboardEntraClientId`, `dashboardEntraTenantId`)
   into `apphost/appsettings.<env>.json`, then **`aspire deploy`** — now also
   provisioning the diagnostic settings and the token-store-enabled auth config once
   those gaps are closed in `AppHost.cs`.
4. **Grant the Container App's managed identity** read access to the vault:
   `az containerapp show -n dashboard -g <azd-rg> --query identity.principalId -o tsv`
   into `platform/terraform.tfvars` as `container_app_principal_ids`, re-apply, and
   restart the dashboard revision to pick up the secrets.
5. **Smoke test**, mirroring what this session had to do manually: attempt login,
   confirm `/.auth/login/aad/callback` completes with no `AADSTS9002325`/`700054`,
   confirm `/.auth/me` returns the user instead of 404ing, query
   `ContainerAppHTTPLogs`/`SystemLogs` in the new workspace if anything looks wrong.

## Summary of concrete next steps

- [x] Decide the client-secret-vs-ID-token-flow question — client secret + token
      store is the answer
- [x] Decide same-tenant vs. new-tenant scope — new subscription under the M365
      tenant, app registration first
- [x] Decide whether guest invitation is automated or human-gated — invitations are
      gone; app role assignments are human-gated via `terraform plan`
- [x] Spike Terraform `azuread` provider for the app registration — written as
      `infra/terraform/entra/`, `terraform validate` clean
- [x] Move the client secret *and* the token store SAS into Key Vault — written as
      `infra/terraform/platform/`
- [x] Add the token store's Storage Account + blob container to IaC — in the platform
      module rather than `AppHost.cs`, see [layer 4](#4-azure-resource-layer--mostly-covered-three-gaps)
- [x] Write the subscription-bootstrap checklist as a script —
      `infra/bootstrap-subscription.sh`
- [x] Verify `app_role_assignment_required` is enforced — confirmed `true` on the
      service principal, with one explicit assignment; the access gate described in
      [layer 3](#3-dashboard-access-control) is real for the first time
- [x] Confirm the M365 tenant permits app registration + subscription creation with
      adequate roles — Global Admin + Owner on an empty PAYG subscription already
      under the tenant
- [x] Update `AppHost.cs`'s `ContainerAppAuthConfig` comment and config to match the
      working design — `clientSecretSettingName`, `login.tokenStore` enabled with the
      SAS secret, both as Key Vault references resolved by a system-assigned identity;
      verified against the generated Bicep
- [x] Codify the GitHub Actions OIDC identity and environment secrets —
      `infra/terraform/entra/cicd.tf`
- [ ] Add diagnostic settings to `AppHost.cs` next to
      `AddAzureContainerAppEnvironment("cae")`
- [x] Enable the `azurerm` remote state backend for both Terraform modules —
      `rg-mynl-tfstate/stmynltfstate`, versioning on
- [ ] Plan the Postgres data migration and the DNS/certificate cutover for the
      subscription move
- [ ] Delete the dead repository-level `AZURE_*` variables left by
      `azd pipeline config` (the live values are environment secrets; see
      `infra/terraform/README.md`)
- [x] ~~Do not deploy production until Terraform has run~~ — both modules applied,
      parameters populated, deployed and verified in production
- [ ] Decommission the hand-made `stmynldashauth` storage account in `rg-dev`, now
      superseded by the Terraform-owned `stmynltokenstore`
- [ ] Delete the old app registration `f32123ed` in the Default Directory tenant —
      **keep it until confidence in the new one has settled**, since it is the
      rollback path
