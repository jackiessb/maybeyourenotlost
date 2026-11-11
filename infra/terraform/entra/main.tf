data "azuread_client_config" "current" {}

locals {
  redirect_uri = "https://${var.dashboard_hostname}/.auth/login/aad/callback"

  # Entra's built-in "default access" app role. Assigning it grants sign-in
  # rights without defining an app-specific role. If the dashboard ever needs
  # real roles (viewer/admin), declare them with an `app_role` block on the
  # application and assign those IDs here instead.
  default_access_role_id = "00000000-0000-0000-0000-000000000000"
}

resource "azuread_application" "dashboard" {
  display_name = var.application_display_name
  owners       = [data.azuread_client_config.current.object_id]

  # Single-tenant. Meaningful now that the registration lives in the tenant
  # whose members actually sign in -- previously this said "my org" while the
  # real user population lived in a different directory and reached it as
  # invited guests.
  sign_in_audience = "AzureADMyOrg"

  # The redirect URI MUST be on the `web` platform, not `spa`. Container Apps
  # Easy Auth performs a confidential-client authorization code exchange once a
  # client secret exists, and Entra requires PKCE for any code redemption tied
  # to an spa-platform redirect URI -- which Easy Auth's server-side exchange
  # does not supply. An spa redirect URI here fails with AADSTS9002325.
  web {
    redirect_uris = [local.redirect_uri]

    implicit_grant {
      # Without this, sign-in fails with AADSTS700054
      # ("response_type 'id_token' is not enabled").
      id_token_issuance_enabled = true
    }
  }
}

resource "azuread_service_principal" "dashboard" {
  client_id = azuread_application.dashboard.client_id
  owners    = [data.azuread_client_config.current.object_id]

  # Load-bearing. Every member of the M365 tenant can authenticate against this
  # app by default; this flag is what reduces access to the explicitly assigned
  # users in var.dashboard_user_upns.
  app_role_assignment_required = true
}

# Drives secret rotation on a fixed cadence. Terraform replaces the credential
# only when this resource's timestamp rolls over, so routine applies are no-ops.
resource "time_rotating" "client_secret" {
  rotation_days = var.client_secret_rotation_days
}

resource "azuread_application_password" "dashboard" {
  application_id = azuread_application.dashboard.id
  display_name   = "easy-auth-token-exchange"

  # Expire 30 days after the next scheduled rotation, so the two never coincide
  # exactly and a missed apply degrades into a warning window, not an outage.
  end_date = timeadd(time_rotating.client_secret.rotation_rfc3339, "720h")

  rotate_when_changed = {
    rotation = time_rotating.client_secret.id
  }
}

data "azuread_user" "dashboard_users" {
  for_each = toset(var.dashboard_user_upns)

  user_principal_name = each.value
}

resource "azuread_app_role_assignment" "dashboard_users" {
  for_each = data.azuread_user.dashboard_users

  app_role_id         = local.default_access_role_id
  principal_object_id = each.value.object_id
  resource_object_id  = azuread_service_principal.dashboard.object_id
}

# The secret goes straight from provider to Key Vault. It is never written to a
# .tfvars file, a Bicep parameter file, or a CI log -- the Container App reads it
# back through a Key Vault reference resolved by its managed identity.
resource "azurerm_key_vault_secret" "client_secret" {
  name         = var.client_secret_name
  value        = azuread_application_password.dashboard.value
  key_vault_id = var.key_vault_id
  content_type = "entra-client-secret"

  # Mirrors the credential's own expiry, so the vault itself can be the source
  # of truth for expiry alerting rather than a calendar reminder.
  expiration_date = azuread_application_password.dashboard.end_date
}

# Same secret, written into the migration target's vault. Removed in Phase 6 once the
# old subscription is gone and the target becomes the only vault.
resource "azurerm_key_vault_secret" "client_secret_target" {
  count = var.target_key_vault_id == "" ? 0 : 1

  provider = azurerm.target

  name            = var.client_secret_name
  value           = azuread_application_password.dashboard.value
  key_vault_id    = var.target_key_vault_id
  content_type    = "entra-client-secret"
  expiration_date = azuread_application_password.dashboard.end_date
}
