# Deployment plan: `dev` environment + PR-driven CI/CD

Status: **proposed, not implemented.** No code has been written for this yet.

## Goal

1. Stand up a deployed `dev` environment that mirrors the existing production deployment.
2. On pull requests, a GitHub Action deploys the branch to `dev`.
3. After merge, a production deploy is staged and waits for manual approval before applying.

---

## 1. Where we are today

| Aspect | Current state |
| --- | --- |
| Tooling | `azd` only. `azure.yaml` declares one service `app` → `./apphost/AppHost.csproj`, `host: containerapp`. |
| Trigger | Manual `azd up` from a workstation. There is no `.github/` directory at all. |
| Environments | One. `.azure/` is gitignored, so the only azd environment exists on one machine. |
| Compute environment | Not modelled. `AppHost.cs` contains no `AddAzureContainerAppEnvironment`, so the ACA environment is implicit in azd's default Aspire handling. |
| Aspire | 13.4.6 across the AppHost SDK and all package references. `net10.0`. |
| Projects | `apphost`, `shared/ServiceDefaults`, `backend/contacts-api`, `backend/encouragement-api`, `frontend` (Vite/React). No solution file, no test projects. |
| Post-deploy fixups | `scripts/bind-custom-domain.sh` and `scripts/apply-scale.sh`, wired as azd `postprovision` + `postdeploy` hooks. |

Deployed topology: an ACA environment with three container apps (`frontend`, `contacts-api`,
`encouragement-api`) and a B1ms Postgres Flexible Server. The `frontend` app serves the built
SPA and reverse-proxies `/contacts` and `/encouragements` to the APIs via YARP.
Public entry point is `https://love.maybeyourenotlost.com`.

## 2. Blockers

These must be resolved before a second environment is possible at all.

1. **Hardcoded production hostname.** `apphost/AppHost.cs:28` —
   `const string frontendOrigin = "https://love.maybeyourenotlost.com"`, inside the
   `IsPublishMode` branch. There is no way to deploy a second environment without editing
   source. Must become an `AddParameter`.

2. **`scripts/bind-custom-domain.sh:9` hardcodes the same hostname.** Needs to read it from
   the environment.

3. **Postgres is Entra ID-only.** `backend/*/Program.cs:30-34` documents that password auth is
   disabled and the APIs authenticate with a managed identity whose Postgres role name comes
   from the token's `xms_mirid` claim. A fresh dev server needs its own Entra administrator
   wired to the dev managed identity. The CI service principal needs Graph directory-read
   permission to create that assignment. This is the most likely thing to break in automation.

4. **`azd` hooks are `shell: sh` + bash scripts.** Fine on `ubuntu-latest`, already broken on a
   Windows dev box without git-bash.

5. **No `global.json`.** CI will silently use whatever .NET 10 SDK the runner ships. No
   `Directory.Packages.props` either — `13.4.6` is repeated in four `.csproj` files.

6. **A fresh-environment deploy has never been tested.** The premise that "dev mirrors prod"
   assumes prod is reproducible from source. The stale managed identity name in the
   `Program.cs` comments (`mi-yudlalf6hmivo`) hints that some wiring happened out of band.

## 3. Decisions

| Decision | Choice |
| --- | --- |
| Dev isolation | Fully separate resource group. Own ACA env, ACR, Log Analytics, Postgres. |
| Prod promotion | On merge to `main`, gated by a GitHub Environment required-reviewer rule. |
| Dev hostname | `dev.maybeyourenotlost.com`. |
| Tooling | Migrate from `azd` to `aspire deploy`. |

### Why migrate off `azd`

The Aspire docs state plainly that `azd` "is no longer the recommended default deployment path",
that it consumes a **deprecated** manifest format, and that new Azure deployment features land
only in the `aspire deploy` path. Since the AppHost has to change anyway — parameters and a
compute environment resource — doing both at once is less total work than parameterizing azd's
`.env` plumbing and then migrating later.

### Why promote from `main` rather than the PR branch

The literal request was "on PRs, deploy to dev, then stage for production". Promoting from a PR
branch would ship code that was never merged and lets production drift ahead of `main`.
Triggering the gated production job on `push: main` gives the same approval button without that
hazard.

## 4. Target architecture

| | dev | production |
| --- | --- | --- |
| Resource group | `rg-maybeyourenotlost-dev` (new) | existing, azd-created |
| ACA env / ACR / Log Analytics / Postgres | all new, dedicated | existing, adopted in place |
| Hostname | `dev.maybeyourenotlost.com` | `love.maybeyourenotlost.com` |
| Aspire environment | `--environment dev` | `--environment production` |
| Trigger | `pull_request`, automatic | `push: main` + required reviewer |
| Azure identity | app registration, federated on `pull_request` | app registration, federated on `environment:production` |
| Frontend scale | 0 / 2 | 2 / 10 |
| API scale | 0 / 1 | 1 / 3 |

---

## Phase 0 — reproducibility gate

**Nothing else is safe until this passes.**

The risk: `aspire deploy` and `azd` use different Azure resource naming schemes.
`WithAzdResourceNaming()` exists to reproduce azd's scheme so an existing deployment is adopted
rather than duplicated. But azd derives names from `AZURE_ENV_NAME`, which has no equivalent
under `aspire deploy`. If the names don't line up, Aspire will provision a **parallel set of
production resources** instead of updating the existing ones.

Container app names (`frontend`, `contacts-api`, `encouragement-api`) come from the AppHost
resource names and should match either way. The ACA environment, ACR, and Log Analytics
workspace are the ones at risk.

Steps:

1. Add `global.json` pinning the .NET 10 SDK. Add `Directory.Packages.props` for central
   package management.
2. In `AppHost.cs`, add `builder.AddAzureContainerAppEnvironment("cae").WithAzdResourceNaming()`.
3. Replace the hardcoded `frontendOrigin` const with `builder.AddParameter("frontendOrigin")`.
   Add `apphost/appsettings.production.json` with
   `{ "Parameters": { "frontendOrigin": "https://love.maybeyourenotlost.com" } }`.
4. **Dry run:** `aspire publish --environment production --output-path ./out`. This emits Bicep
   without applying anything. Diff the generated resource names against what is actually in the
   production resource group.
5. Only if step 4 matches: `aspire deploy --environment production`, with the portal open.
   Confirm no duplicate ACA environment, ACR, Log Analytics workspace, or Postgres server
   appears.

**Fallback:** if naming cannot be reconciled, stay on `azd` and use `azd env` for the two
environments. The CI structure in Phase 4 is unchanged; only the command differs. Note that
under azd the Aspire environment name must be set explicitly per azd environment via
`azd env set DOTNET_ENVIRONMENT dev` — selecting an azd environment does **not** set it.

## Phase 1 — AppHost parameterization

- Add `apphost/appsettings.dev.json` with `Parameters:frontendOrigin` =
  `https://dev.maybeyourenotlost.com`.
- Move the scale rules out of `scripts/apply-scale.sh` into `PublishAsAzureContainerApp`
  callbacks, varying by `builder.Environment`. This is the fix the script's own header comment
  asks for: it exists only because the generated template resets scale on every provision, so
  expressing the values in the AppHost ends the reset-then-reapply cycle rather than racing it.
  Preserve the documented rationale in the migrated code — the API cap of 3 replicas is what
  bounds the pair to 30 Postgres connections against a B1ms `max_connections=50`, and it is
  referenced from `backend/*/Program.cs:17`.
- Parameterize the hostname in `scripts/bind-custom-domain.sh` via an environment variable.
- **Do not propagate the Aspire environment name to `ASPNETCORE_ENVIRONMENT`.** Aspire does not
  do this automatically, and here that default is load-bearing:
  `backend/*/Program.cs:25` appends `;Ssl Mode=Require` only when the environment is *not*
  `Development`, because disabling GSS makes Npgsql skip SSL negotiation while Azure Postgres
  runs `require_secure_transport=on`. Setting the dev containers to `Development` would break
  their database connections and additionally expose `MapOpenApi()`. Set
  `ASPNETCORE_ENVIRONMENT=Production` explicitly in both cloud environments so this is
  deliberate rather than accidental.
- Update the stale managed identity name in the `Program.cs` comments, which will no longer be
  accurate once a second environment exists with its own identity.

## Phase 2 — dev infrastructure, first run by hand

- Create `rg-maybeyourenotlost-dev`.
- Add DNS for `dev.maybeyourenotlost.com`: a CNAME to the container app, plus the `asuid.dev`
  TXT record that ACA hostname validation requires.
- Run `aspire deploy --environment dev` interactively, locally, once. Expect friction on the
  Postgres Entra administrator (blocker 3). Prove this works by hand before automating it.
- Confirm EF migrations apply cleanly against a fresh database — both APIs call
  `db.Database.Migrate()` at startup.

## Phase 3 — Azure identities for CI

Two app registrations with federated credentials, no client secrets:

| App registration | Federated subject | Scope |
| --- | --- | --- |
| `gh-mynl-dev` | `repo:jackiessb/maybeyourenotlost:pull_request` | dev resource group |
| `gh-mynl-prod` | `repo:jackiessb/maybeyourenotlost:environment:production` | prod resource group |

Each needs **Contributor + User Access Administrator** on its resource group. Contributor alone
is insufficient — Aspire emits role assignments (`AcrPull` for image pull, plus Postgres roles),
and creating role assignments requires User Access Administrator. Both also need the Graph
permission for the Postgres Entra admin assignment.

GitHub Environments `dev` and `production` hold `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`, and `AZURE_RESOURCE_GROUP` as environment-scoped values.
The `production` environment gets a **required reviewer** — this is the approval gate.

## Phase 4 — workflows

### `.github/workflows/deploy-dev.yml`

- `on: pull_request`
- `environment: dev`
- `concurrency: { group: deploy-dev, cancel-in-progress: false }` — a single shared dev
  environment means concurrent PRs overwrite each other, so serialize them. Do **not** cancel in
  progress; interrupting a deploy mid-flight can leave ACA in an inconsistent state.
- Skip when `github.event.pull_request.head.repo.fork` is true. Fork PRs cannot obtain OIDC
  tokens and the job would fail confusingly.
- Steps: `actions/checkout` → `azure/login@v2` (OIDC) → `actions/setup-dotnet` →
  `actions/setup-node` → install Aspire CLI → build/lint gates → `aspire deploy --environment dev`
- Comment the dev URL on the PR.

Because there are no test projects, the pre-deploy gates are `dotnet build`, `npm run lint`
(oxlint), and `tsc -b` from the frontend build. Adding tests is out of scope here but would
naturally slot in at this point.

### `.github/workflows/deploy-prod.yml`

- `on: push: { branches: [main] }`, plus `workflow_dispatch`
- `environment: production` — the job enters a *Waiting* state and does nothing until approved
  in the Actions UI. This is the "go ahead".
- `concurrency: { group: deploy-prod, cancel-in-progress: false }`
- Same steps, `--environment production`.

### Configuration passed to both

Supplied as environment variables on the deploy step:

```
Azure__SubscriptionId
Azure__ResourceGroup
Azure__Location
Parameters__frontendOrigin
```

**Do not cache `~/.aspire/deployments` in CI.** The docs suggest `actions/cache` for this, but
that state file can contain secrets, and GitHub makes caches created on the default branch
readable from every PR branch — which would expose production deployment state to any PR. The
cache exists only to avoid interactive prompting for subscription / resource group / location /
parameters. Supplying all of those explicitly as environment variables removes the need to
prompt, so the cache is unnecessary. Revisit only if a prompt turns out to be unavoidable, and
if so, scope the production cache key to `refs/heads/main`.

## Phase 5 — cleanup

- Delete `azure.yaml`.
- Retire `scripts/apply-scale.sh` once the scale rules live in the AppHost.
- Keep `scripts/bind-custom-domain.sh` as a post-deploy step until custom domain binding can be
  expressed in the AppHost.

Do this only after two consecutive clean production deploys through the new path.

---

## Costs and risks

- **~$30–50/month** for the dev resource group, dominated by the B1ms Postgres server; ACR and
  Log Analytics make up the rest. Scaling dev container apps to zero minimum replicas keeps the
  compute portion near zero when idle.
- **Phase 0 is the real risk.** If `WithAzdResourceNaming()` does not reproduce the existing
  names, `aspire deploy` will duplicate production infrastructure. The `aspire publish` dry run
  in Phase 0 step 4 is what makes this safe to attempt.
- **Shared dev environment.** Concurrent PRs overwrite each other's deployment; the last push
  wins. Acceptable for a single-maintainer project, but it is not per-PR preview environments.
- **Postgres Entra admin automation** (blocker 3) is the second-most-likely failure and is
  independent of the tooling decision — worth validating early.

## References

- [How Aspire deployment works](https://aspire.dev/deployment/deploy-with-aspire/)
- [CI/CD overview](https://aspire.dev/deployment/ci-cd/)
- [Environments](https://aspire.dev/deployment/environments/)
- [Deploy to Azure](https://aspire.dev/deployment/azure/)
- [Configure Azure Container Apps environments](https://aspire.dev/integrations/cloud/azure/configure-container-apps/)
- [Use existing azd workflows](https://aspire.dev/deployment/azure/azure-developer-cli/)
- [Deployment state caching](https://aspire.dev/deployment/deployment-state-caching/)
