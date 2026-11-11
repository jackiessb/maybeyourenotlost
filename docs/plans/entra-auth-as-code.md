# Plan: Bringing Entra ID / Easy Auth Under Infrastructure as Code

## Why

Setting up sign-in for the MYNL Dashboard required a long sequence of manual, one-off
`az`/Graph calls against the Azure subscription and its Entra tenant: inviting guest
users, flipping an app registration setting, generating a client secret, wiring that
secret into a Container App, and turning on diagnostic logging. None of it is
reproducible from source control. If this subscription were lost, or if the same
dashboard needed to exist in a second Azure environment (a true second tenant, or a
second subscription under the same tenant), someone would have to re-derive all of
this from memory or from this document.

This plan inventories exactly what was done by hand, what's already codified, what
isn't, and what it would take to close the gap.

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

Notably, the existing code's comment says:

> No client secret is configured, so sign-in uses the ID token flow. Who may sign in
> is controlled by "Assignment required" on the app registration's Enterprise
> Application.

That was the original design intent. **This session's debugging found that design
doesn't actually work**: without a client secret, Easy Auth v2 can't populate its
token store, `/.auth/me` 404s after every successful login, and the dashboard's
client-side auth check bounces the user back to the login screen in a loop. The fix
applied live (a generated client secret, stored as a Container App secret, wired via
`clientSecretSettingName`) now **contradicts what's in source control**. Before
writing IaC for this, that design decision needs to be made explicitly — see
[Open decisions](#open-decisions-before-writing-any-code) below.

## What's manual today (the full list)

Everything below was done directly against the subscription/tenant with no record in
source control:

1. **App registration existed before this session** (`MYNL Dashboard`,
   `f32123ed-18c2-4740-b4df-c1e78c80aad1`), including its SPA redirect URI
   (`https://dash.maybeyourenotlost.com/.auth/login/aad/callback`) and
   `signInAudience: AzureADMyOrg`. Who/what created it, and how, is undocumented.
2. **`enableIdTokenIssuance` flipped to `true`** on the app registration via a Graph
   PATCH, to unblock `AADSTS700054`.
3. **A B2B guest invitation sent** via `POST /v1.0/invitations` for
   `jackson@maybeyourenotlost.com` into the Default Directory tenant
   (`e22c9007-0f6b-44b6-a403-af91c309278d`) — the tenant that owns the app
   registration, which is a *different* Entra tenant than the one backing the
   Microsoft 365 instance (`aac88807-ec5d-4c7a-8379-0f2baf8123e0`) where the actual
   mailboxes/users live. Every M365 user that needs dashboard access needs this same
   invitation, one at a time, by hand.
4. **A client secret generated** (`az ad app credential reset --append`, 2-year
   expiry) and stored as a Container App secret (`aad-client-secret`), then wired into
   the auth config via `az containerapp auth microsoft update
   --client-secret-name`. This secret isn't tracked anywhere — if it expires or is
   lost, nothing in source control says how it was produced or how to replace it.
5. **`Microsoft.Insights` resource provider registered** on the subscription (a
   one-time subscription-level prerequisite with no Bicep/Aspire equivalent in this
   repo).
6. **Two diagnostic settings created by hand**, one per Container Apps managed
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
  - `azuread_application` (display name, `sign_in_audience`, SPA redirect URIs,
    `web.implicit_grant.id_token_issuance_enabled`)
  - `azuread_service_principal` (+ `app_role_assignment_required = true`, matching
    the "Assignment required" behavior the current code comment assumes)
  - `azuread_application_password` for the client secret (see
    [secrets](#2-secrets--the-client-secret-problem) below)
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

### 2. Secrets — the client secret problem

Whatever creates the client secret must not put it in a `.tf` file, a `.bicep`
parameter file, or a GitHub Actions log. The realistic pattern:

1. Terraform creates the `azuread_application_password` and writes the value directly
   into Key Vault (`azurerm_key_vault_secret`), never into Terraform state in a way
   that gets printed, and never into a parameters file.
2. The Container App's `aad-client-secret` setting becomes a **Key Vault
   reference** — the Container App's system-assigned managed identity gets a Key
   Vault `get` RBAC role, and `ContainerAppAuthConfig`'s
   `clientSecretSettingName` points at a secret backed by `secretRef` → Key Vault,
   not a raw value.
3. Secret rotation: a 2-year expiry was used ad hoc this session. IaC should pick a
   deliberate rotation window and either automate rotation (Key Vault + Event Grid +
   a rotation function) or, at minimum, put an expiry-date comment/output so it's not
   a silent future outage.

This also means re-opening the "no client secret" design decision from the top of
this document — if the team decides the ID-token-only flow should be fixed some other
way instead (e.g., disabling the token store requirement, or moving `/.auth/me`
calls out of the frontend's auth-check path), the secret infrastructure in this
section becomes unnecessary. Don't build it until that's settled.

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

### 4. Azure resource layer — mostly covered, two gaps

- Container App + custom domain + auth config: **already in `AppHost.cs`**. Only
  needs the client-secret/Key-Vault wiring from above if that design direction is
  kept.
- Diagnostic settings (`ContainerAppConsoleLogs`/`SystemLogs`/`HTTPLogs` → Log
  Analytics): **not in `AppHost.cs`**, despite the environment and workspace already
  existing through `AddAzureContainerAppEnvironment`. This is the easiest gap to
  close — `Azure.Provisioning.Insights` (or a raw `ProvisioningConstruct` emitting
  `Microsoft.Insights/diagnosticSettings`) can attach this directly to the
  `cae` resource inside `AppHost.cs`, right next to where `ContainerAppAuthConfig` is
  added today. This should apply to *every* environment, not just the one hosting
  the dashboard, so it belongs near `AddAzureContainerAppEnvironment("cae")` itself
  rather than inside the dashboard-specific `if (includeDashboard)` block.

### 5. Subscription-level prerequisites

`Microsoft.Insights` provider registration is a one-time, subscription-wide
operation that doesn't belong in a per-deploy pipeline (re-registering an already-
registered provider is a harmless no-op, but it's still not a "resource" Aspire
provisions). This belongs in a short subscription-bootstrap script/checklist, run
once per *new subscription* — see the runbook below.

## Open decisions before writing any code

1. **Keep the client secret + token store, or go back to the ID-token-only
   design and fix `/.auth/me` some other way?** The code today says one thing; the
   working fix says another. Pick one before investing in Key Vault wiring for a
   secret that might get removed again.
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
   `az provider register --namespace Microsoft.Insights` (and any other providers
   the existing Postgres/Container Apps/Key Vault resources need that happen to
   already be registered in the current subscription from prior use).
2. **`terraform apply` against the Entra layer**: app registration, service
   principal with `app_role_assignment_required`, client secret written straight to
   Key Vault, guest invitations for the known initial user list.
3. **`azd env set`** (or equivalent) the new app's client ID/tenant ID into the
   target environment, matching the existing `dashboardEntraClientId` /
   `dashboardEntraTenantId` parameters `AppHost.cs` already expects.
4. **`aspire deploy` / `azd deploy`** as today — now also provisioning the
   diagnostic settings once that gap is closed in `AppHost.cs`.
5. **Smoke test**, mirroring what this session had to do manually: attempt login,
   confirm `/.auth/login/aad/callback` completes, confirm `/.auth/me` returns the
   user instead of 404ing, query `ContainerAppHTTPLogs`/`SystemLogs` in the new
   workspace if anything looks wrong.

## Summary of concrete next steps

- [ ] Decide the client-secret-vs-ID-token-flow question
- [ ] Decide same-tenant vs. new-tenant scope for "another Azure instance"
- [ ] Spike Terraform `azuread` provider for the app registration + invitations
- [ ] Move the client secret into Key Vault + Container App managed identity
      reference, if the secret-based flow is kept
- [ ] Add diagnostic settings to `AppHost.cs` next to
      `AddAzureContainerAppEnvironment("cae")`
- [ ] Write the subscription-bootstrap checklist (provider registrations) as a short
      script or doc, separate from per-deploy IaC
- [ ] Decide whether guest invitation is automated-on-apply or human-gated
