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
Two realistic options:

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
  - `azuread_invitation` for each guest user
- **Bicep's `Microsoft.Graph` extension** (currently preview). Lets Graph resources
  live alongside the ARM Bicep that Aspire already generates, avoiding a second
  toolchain. Less mature; worth a spike before committing to it given this repo's
  deploys are driven by `aspire deploy`, not a hand-written Bicep root.

Given Aspire/`Azure.Provisioning` only emits ARM/Bicep (not Graph), **Terraform run as
a separate, prior step is the more realistic near-term choice** — Aspire has no
extension point for Graph calls today. The alternative — shelling out to `az`/Graph
REST from a C# `IResourceWithPostInit`-style hook — is possible but fights the
grain of the tool and loses idempotency/plan-diffing for free.

### 2. Secrets — the client secret *and* the token store SAS

There are now two sensitive values that must never land in a `.tf` file, a `.bicep`
parameter file, or a GitHub Actions log: the AAD client secret and the blob storage
SAS URL. The realistic pattern for both:

1. Terraform creates the `azuread_application_password` (client secret) and the
   storage account's SAS/connection details, writing each directly into Key Vault
   (`azurerm_key_vault_secret`), never into Terraform state in a way that gets
   printed, and never into a parameters file.
2. The Container App's `aad-client-secret` and `tokenstore-sas` settings become
   **Key Vault references** — the Container App's system-assigned managed identity
   gets a Key Vault `get` RBAC role, and both `ContainerAppAuthConfig`'s
   `clientSecretSettingName` and the token store's SAS setting point at secrets
   backed by `secretRef` → Key Vault, not raw values.
3. Secret rotation: a 2-year expiry was used ad hoc for both the client secret and
   the SAS token this session. IaC should pick a deliberate rotation window for each
   and either automate rotation (Key Vault + Event Grid + a rotation function) or, at
   minimum, put an expiry-date output so it's not a silent future outage. The SAS
   token is arguably the more dangerous of the two to let lapse silently, since its
   failure mode (token store unreachable) looks identical to the original bug this
   whole investigation was chasing.

### 3. Guest user provisioning

Right now this is "run a Graph POST by hand per person." In IaC, this becomes a
list — e.g. a `guest_users.tfvars` (or a JSON/YAML file under `infra/`) enumerating
emails per environment, fed into a `for_each` over `azuread_invitation`. Two things
worth deciding up front:

- Does every new M365 user automatically need an invitation (fully automated,
  triggered by M365 user creation), or is this still a deliberate, reviewed step
  per person (Terraform plan/apply with a human looking at the diff)? Given this is
  about who can access an admin dashboard, the latter is almost certainly right —
  automate the invitation *mechanism*, not the *decision*.
- The "Assignment required" setting referenced in `AppHost.cs`'s comment needs to
  actually be verified/set (`app_role_assignment_required` in Terraform, or
  "User assignment required" on the Enterprise Application in the portal) — right
  now guests get invited into the tenant but nothing in this session's work actually
  checked whether assignment is enforced. Being invited into the tenant and being
  assigned to the app are two different gates; both should be intentional.

### 4. Azure resource layer — mostly covered, three gaps

- Container App + custom domain + auth config: **already in `AppHost.cs`**, but the
  `ContainerAppAuthConfig` block needs updating to add `clientSecretSettingName`
  (Key Vault-backed, see above) and the token store configuration — today it only
  sets up `identityProviders.azureActiveDirectory` with no secret and no `login`
  block at all.
- **Storage Account + blob container for the token store: not in `AppHost.cs` at
  all**, and didn't exist anywhere in the subscription before this session.
  `Azure.Provisioning.Storage` is already a transitive dependency of the AppHost
  project (seen in `apphost/bin/.../Azure.Provisioning.Storage.dll`), so modeling
  this in C# alongside the existing resources is straightforward — it just hasn't
  been done.
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
This belongs in a short subscription-bootstrap script/checklist, run once per *new
subscription* — see the runbook below. Worth registering proactively rather than
reactively: any Terraform/Bicep module that touches diagnostic settings or storage
will hit the same wall on a brand-new subscription.

## Open decisions before writing any code

1. ~~Keep the client secret + token store, or go back to the ID-token-only design?~~
   **Resolved**: client secret + `web`-platform redirect URI + storage-backed token
   store is the confirmed-working design. `AppHost.cs` and its comment should be
   updated to match.
2. **Is "another Azure instance" a new subscription in the same Entra tenant, or a
   genuinely separate tenant (as with the M365 tenant discovered this session)?**
   This changes the runbook significantly: same-tenant duplication skips app
   registration/guest-invitation work entirely and only needs the Azure resource
   layer; a new tenant needs everything in this document.
3. **Automated or human-gated guest invitations?** (see above) — affects whether
   Terraform applies are safe to run unattended.

## Runbook for standing this up in a new Azure instance (once the above is codified)

Assuming a genuinely new Entra tenant + subscription:

1. **Subscription bootstrap** (one-time, manual or a tiny script):
   `az provider register --namespace Microsoft.Insights` and
   `az provider register --namespace Microsoft.Storage` (and any other providers the
   existing Postgres/Container Apps/Key Vault resources need that happen to already
   be registered in the current subscription from prior use). Run this *before*
   anything else — both registrations take a couple of minutes to propagate and will
   otherwise fail the deploy partway through with a confusing error.
2. **`terraform apply` against the Entra layer**: app registration with its redirect
   URI under the `web` platform, service principal with `app_role_assignment_required`,
   client secret written straight to Key Vault, guest invitations for the known
   initial user list.
3. **`terraform apply` (or a Bicep module) for the token store's Storage Account** +
   blob container + SAS, also written straight to Key Vault.
4. **`azd env set`** (or equivalent) the new app's client ID/tenant ID into the
   target environment, matching the existing `dashboardEntraClientId` /
   `dashboardEntraTenantId` parameters `AppHost.cs` already expects.
5. **`aspire deploy` / `azd deploy`** as today — now also provisioning the
   diagnostic settings and the token-store-enabled auth config once those gaps are
   closed in `AppHost.cs`.
6. **Smoke test**, mirroring what this session had to do manually: attempt login,
   confirm `/.auth/login/aad/callback` completes with no `AADSTS9002325`/`700054`,
   confirm `/.auth/me` returns the user instead of 404ing, query
   `ContainerAppHTTPLogs`/`SystemLogs` in the new workspace if anything looks wrong.

## Summary of concrete next steps

- [x] Decide the client-secret-vs-ID-token-flow question — client secret + token
      store is the answer
- [ ] Update `AppHost.cs`'s `ContainerAppAuthConfig` comment and config to match the
      working design (client secret, token store, no more "no secret" claim)
- [ ] Decide same-tenant vs. new-tenant scope for "another Azure instance"
- [ ] Spike Terraform `azuread` provider for the app registration (redirect URI under
      `web`, not `spa`) + invitations
- [ ] Move the client secret *and* the token store SAS into Key Vault + Container App
      managed identity references
- [ ] Add the token store's Storage Account + blob container to `AppHost.cs` via
      `Azure.Provisioning.Storage`
- [ ] Add diagnostic settings to `AppHost.cs` next to
      `AddAzureContainerAppEnvironment("cae")`
- [ ] Write the subscription-bootstrap checklist (`Microsoft.Insights` +
      `Microsoft.Storage` provider registrations) as a short script or doc, separate
      from per-deploy IaC
- [ ] Decide whether guest invitation is automated-on-apply or human-gated
