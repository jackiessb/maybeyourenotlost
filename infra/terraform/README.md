# Terraform: Entra + platform layers

Covers what `aspire deploy` cannot. Aspire compiles `apphost/AppHost.cs` to ARM via
`Azure.Provisioning`, and ARM does not model Microsoft Graph objects (applications,
service principals, role assignments) as resources. Those live here, along with the
two secrets that must never pass through a parameter file or a CI log.

See `docs/plans/entra-auth-as-code.md` for why each setting is the way it is.

## Layout

| Module | Runs against | Owns |
| --- | --- | --- |
| `entra/` | The Microsoft 365 tenant | App registration, service principal, client secret, per-user app role assignments, CI/CD federated identity + GitHub Actions secrets |
| `platform/` | The target Azure subscription | Key Vault, Easy Auth token store (storage account + container + SAS), CI/CD subscription role assignments |

Two root modules, not one, for two reasons. During the migration they authenticate
against **different tenants** — `azuread` against the M365 tenant, `azurerm` against
whichever subscription currently holds the infrastructure — and no single login covers
both. And each state file holds a secret, so keeping them separate limits what a single
compromised state exposes. Key Vault is the handoff point between them.

`aspire deploy` remains the owner of everything else: Container Apps environment,
the apps themselves, Postgres, scaling, custom domains, and the auth config that
*references* these secrets.

## Ordering

The dashboard Container App's managed identity cannot be granted vault access before
the Container App exists, and the Container App's auth config cannot resolve secrets
before the vault holds them. That circularity makes the first run four phases. Only
phase 1 and 3 recur.

```
0. ./infra/bootstrap-subscription.sh <subscription-id> [tenant-id]
     Resource providers + Terraform state storage. Once per subscription.

1. terraform -chdir=infra/terraform/platform apply
     Key Vault, token store, SAS. Note the key_vault_id output.

2. terraform -chdir=infra/terraform/entra apply
     App registration in the M365 tenant, client secret written to the vault.
     With manage_github_actions = true, also the CI identity and GitHub secrets.
     Note the client_id, tenant_id, and *_key_vault_uri outputs.

3. Write the entra + platform outputs into apphost/appsettings.<env>.json:
     dashboardEntraClientId              <- entra  client_id
     dashboardEntraTenantId              <- entra  tenant_id
     dashboardClientSecretKeyVaultUri    <- entra  client_secret_key_vault_uri
     dashboardTokenStoreSasKeyVaultUri   <- platform token_store_sas_secret_uri
   Then: aspire deploy

4. Grant the now-existing Container App identity read access to the vault:
     az containerapp show -n dashboard -g <azd-rg> --query identity.principalId -o tsv
   Put it in platform/terraform.tfvars as container_app_principal_ids (and
   cicd_principal_ids from the entra module), then re-apply platform. Restart the
   dashboard revision to pick up the secrets.
```

The four Key Vault URIs and IDs in step 3 are identifiers, not secrets — the
values stay in the vault and are resolved at runtime by the Container App's
system-assigned identity, so they are safe in a committed appsettings file.

`platform`'s `container_app_grants_pending` output is `true` until phase 4 is done.

## Credentials

Set the tenant explicitly. `az`'s selected tenant is not a safe default here: an
`az ad` command run against the wrong directory reports the app as not found, which
reads like a permissions problem and sends you looking in the wrong place.

```sh
az login --tenant <m365-tenant-id>     # for entra/
az login --tenant <infra-tenant-id>    # for platform/
```

Running `entra/` needs, in the M365 tenant:

- **Application Administrator** (or Cloud Application Administrator) — create the app
  registration, set `app_role_assignment_required`, assign users
- **Key Vault Secrets Officer** on the vault — granted by `platform/`, but only to the
  principal that ran `platform/`. A different principal running `entra/` needs it too.

Both are satisfied today: this account holds **Global Administrator** in `aac88807…`
and **Owner** on the empty pay-as-you-go subscription already provisioned under that
tenant (`20aad6af-afbd-4c72-a48d-59ae01ca2cb2`), so nothing here needs escalating.

## Who can sign in

`dashboard_user_upns` in `entra/terraform.tfvars` is the access gate, and it is the
whole gate. The service principal sets `app_role_assignment_required = true`, but
every member of the M365 tenant can otherwise authenticate against the app — unlike
the previous arrangement, where access was incidentally limited to whoever had been
invited into the Default Directory tenant as a guest.

Adding a user is a reviewed `terraform plan` diff, deliberately. The mechanism is
automated; the decision is not.

## Secret rotation

| Secret | Cadence | Failure mode when it lapses |
| --- | --- | --- |
| Entra client secret | `client_secret_rotation_days`, default 365 | Sign-in fails at the token exchange |
| Token store SAS | `token_store_sas_rotation_days`, default 180 | `/.auth/me` 404s; sign-in appears to loop |

Rotation happens on `apply` once the `time_rotating` resource rolls over — nothing
rotates on its own. Both Key Vault secrets carry an `expiration_date` mirroring the
underlying credential, so the vault can drive expiry alerting.

The SAS is the more dangerous of the two. Its failure mode is identical to the
original bug chased in `docs/plans/entra-auth-as-code.md`, so an expiry looks like a
regression in the auth config rather than a lapsed credential.

## State contains secrets

Both state files hold a credential in cleartext — `azuread_application_password.value`
and the SAS token. Use the `azurerm` backend (commented out in each `versions.tf`;
`bootstrap-subscription.sh` prints the exact block and provisions the container with
versioning enabled). `*.tfstate` is gitignored, but local state on a laptop is not an
acceptable resting place for these.

## CI/CD identity

`entra/cicd.tf` replaces what `azd pipeline config` wired up by hand. It creates a
dedicated app registration, a federated credential per deploying GitHub environment,
and the four `AZURE_*` environment secrets both workflows read. No client secret:
GitHub mints an OIDC token and Entra exchanges it, so the values written to GitHub
are identifiers rather than credentials.

Set `manage_github_actions = true` and export a `GITHUB_TOKEN` with the `repo` scope.
Left `false` by default so the module runs without one.

**The repo currently holds two divergent copies of these identifiers, and only one is
live.** The workflows read `secrets.AZURE_*`, which resolve to **environment** secrets
on `production` and `dev`. Repository-level *variables* of the same names also exist as
leftovers from `azd pipeline config` and are read by nothing. Updating those during a
migration looks like it worked and changes nothing. Delete them:

```sh
for v in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_ENV_NAME; do
  gh variable delete "$v"
done
```

Leave the `AZURE_LOCATION` repository variable — the workflows do read that one, via
`vars.AZURE_LOCATION`.

`github_environments` has **no default on purpose.** It maps each GitHub environment to
the Azure resource group it deploys into, and those names change during the subscription
migration. A stale default would point a deploy at the wrong resource group, and since
azd creates what it does not find, that means a duplicate stack rather than a failure.
The variable's own description carries the before and after values.

Until the migration lands, the historical inversion in `docs/environment.md` is live:
**`rg-dev` holds production.** Afterwards it is `rg-prod` for production and `rg-dev`
for dev.
