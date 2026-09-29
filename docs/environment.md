# Environment

## Organization

MYNL operates on two levels of environment: *dev* and *production*. 

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