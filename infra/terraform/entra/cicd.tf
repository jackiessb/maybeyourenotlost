# ---------------------------------------------------------------------------
# GitHub Actions deploy identity.
#
# Workload identity federation, so CI holds no client secret: GitHub mints an
# OIDC token, Entra trades it for an Azure access token. The values written to
# GitHub are therefore identifiers, not credentials.
#
# Replaces what `azd pipeline config` set up by hand against the personal
# subscription. Gated on var.manage_github_actions so the rest of this module
# runs without a GitHub token.
# ---------------------------------------------------------------------------

locals {
  manage_cicd = var.manage_github_actions ? 1 : 0

  cicd_environments = var.manage_github_actions ? var.github_environments : {}
}

resource "azuread_application" "cicd" {
  count = local.manage_cicd

  display_name     = var.cicd_application_display_name
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "cicd" {
  count = local.manage_cicd

  client_id = azuread_application.cicd[0].client_id
  owners    = [data.azuread_client_config.current.object_id]

  # Not an app users sign in to -- nothing to assign.
  app_role_assignment_required = false
}

# One credential per deploying environment. The subject must match GitHub's
# token claim exactly; an `environment:` subject only matches a job that declares
# `environment: <name>`, which both workflows do.
resource "azuread_application_federated_identity_credential" "cicd" {
  for_each = local.cicd_environments

  application_id = azuread_application.cicd[0].id
  display_name   = "github-${var.github_repository}-${each.key}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_owner}/${var.github_repository}:environment:${each.key}"
}

# ---------------------------------------------------------------------------
# GitHub Actions environment secrets.
#
# Environment-scoped, not repository-scoped, because that is what the workflows
# read. Repository-level variables of the same names exist as dead leftovers from
# `azd pipeline config` and are NOT consulted by either workflow -- updating
# those instead would appear to work and change nothing. Delete them separately:
#   gh variable delete AZURE_CLIENT_ID
#   gh variable delete AZURE_TENANT_ID
#   gh variable delete AZURE_SUBSCRIPTION_ID
#   gh variable delete AZURE_ENV_NAME
# (AZURE_LOCATION is a repository variable that IS live -- leave it.)
# ---------------------------------------------------------------------------

resource "github_actions_environment_secret" "client_id" {
  for_each = local.cicd_environments

  repository      = var.github_repository
  environment     = each.key
  secret_name     = "AZURE_CLIENT_ID"
  plaintext_value = azuread_application.cicd[0].client_id
}

resource "github_actions_environment_secret" "tenant_id" {
  for_each = local.cicd_environments

  repository      = var.github_repository
  environment     = each.key
  secret_name     = "AZURE_TENANT_ID"
  plaintext_value = var.entra_tenant_id
}

resource "github_actions_environment_secret" "subscription_id" {
  for_each = local.cicd_environments

  repository      = var.github_repository
  environment     = each.key
  secret_name     = "AZURE_SUBSCRIPTION_ID"
  plaintext_value = var.cicd_subscription_id
}

resource "github_actions_environment_secret" "resource_group" {
  for_each = local.cicd_environments

  repository      = var.github_repository
  environment     = each.key
  secret_name     = "AZURE_RESOURCE_GROUP"
  plaintext_value = each.value.resource_group
}
