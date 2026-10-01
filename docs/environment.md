# Environment

## Organization

MYNL operates on two levels of environment: _dev_ and _production_.

These environments have diverging names in the actual code due to when they were created:

- dev
  - In Azure: dev-b
  - In Aspire: dev-b
- production
  - In Azure: dev
  - In Aspire: production

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
