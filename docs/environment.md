# Environment

## Organization

MYNL operates on two levels of environment: _dev_ and _production_.

The Azure resource group names and the Aspire environment names diverged from when each
was created, and the resource group half is being corrected during the subscription
migration (see [`plans/subscription-migration.md`](plans/subscription-migration.md)).
Azure cannot rename a resource group in place, so the correction happens for free in the
new subscription, where everything is created fresh.

| Environment | Aspire env | Azure RG (current) | Azure RG (after migration) | Hostname |
| --- | --- | --- | --- | --- |
| dev | `dev-b` | `rg-dev-b` | **`rg-dev`** | `dev.maybeyourenotlost.com` |
| production | `production` | `rg-dev` | **`rg-prod`** | `love.` / `dash.` |

Until the migration lands, the inversion is live: **the `rg-dev` resource group holds
production.** Do not reason from the name.

The Aspire environment name `dev-b` stays as it is for now — renaming it means renaming
`appsettings.dev-b.json` and the `ASPIRE_ENVIRONMENT` value in the dev workflow, which is
a separate change from the resource groups.

## Workflows

Each environment has its own GitHub workflow. Each workflow runs `aspire deploy`, targeting the desired environment relative to the workflow.

## Environment Variables

Enviroment variables for each environment are stored in `appsettings.dev-b.json` and `appsettings.production.json`.

## Connecting to a Databse Server

1. Find the desired Postgres Flexible Server resource in Azure.
2. Navigate to the Connect tab. Record the parameters given to you.
3. Navigate to the Networking tab. If you are an admin, record your IP in the allowlist.

### DataGrip

1. Ensure that the server has admin mode enabled. You can turn this on in the Authentication tab.
2. Enter and save the username and password.
