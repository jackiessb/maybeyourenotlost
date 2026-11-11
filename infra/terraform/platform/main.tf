data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "platform" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Key Vault -- the handoff point between the two Terraform layers and Aspire.
# The entra module writes the client secret here; this module writes the token
# store SAS here; the Container App's managed identity reads both back.
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "platform" {
  name                = var.key_vault_name
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  tenant_id           = var.tenant_id
  sku_name            = "standard"
  tags                = var.tags

  # RBAC rather than access policies: the Container App's managed identity is
  # granted via a role assignment, which is what Key Vault references expect.
  rbac_authorization_enabled = true

  # Recovery for an accidental `terraform destroy`. Note that soft delete means
  # the vault name stays reserved for the retention period -- a destroyed vault
  # cannot immediately be recreated under the same name.
  soft_delete_retention_days = 90
  purge_protection_enabled   = false
}

# Lets whoever runs Terraform write secrets. Without this, an RBAC vault rejects
# the entra module's secret write even for a subscription Owner.
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.platform.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Granted after the first `aspire deploy`, once the Container App's identity
# exists. See var.container_app_principal_ids.
resource "azurerm_role_assignment" "container_app_secrets_user" {
  for_each = toset(var.container_app_principal_ids)

  scope                = azurerm_key_vault.platform.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

# ---------------------------------------------------------------------------
# Easy Auth token store.
#
# Enabling the token store is not optional: with a client secret present but
# tokenStore.enabled unset, sign-in succeeds and /.auth/me still 404s. Container
# Apps rejects a filesystem-backed store ("only blob storage token store is
# supported") because replicas would not share it, so this storage account is a
# hard requirement of the working auth configuration.
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "token_store" {
  name                = var.token_store_account_name
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  tags                = var.tags

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  # The SAS below is the only intended access path.
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "token_store" {
  name                  = var.token_store_container_name
  storage_account_id    = azurerm_storage_account.token_store.id
  container_access_type = "private"
}

# Keeps the SAS stable between rotations -- deriving it from timestamp() instead
# would mint a new token on every apply and churn the Container App's secret.
resource "time_rotating" "token_store_sas" {
  rotation_days = var.token_store_sas_rotation_days
}

data "azurerm_storage_account_blob_container_sas" "token_store" {
  connection_string = azurerm_storage_account.token_store.primary_connection_string
  container_name    = azurerm_storage_container.token_store.name
  https_only        = true

  start  = formatdate("YYYY-MM-DD'T'hh:mm:ssZ", time_rotating.token_store_sas.id)
  expiry = formatdate("YYYY-MM-DD'T'hh:mm:ssZ", timeadd(time_rotating.token_store_sas.id, "${var.token_store_sas_rotation_days * 24}h"))

  permissions {
    read   = true
    add    = true
    create = true
    write  = true
    delete = true
    list   = true
  }
}

resource "azurerm_key_vault_secret" "token_store_sas" {
  name         = "dashboard-tokenstore-sas"
  key_vault_id = azurerm_key_vault.platform.id
  content_type = "easyauth-tokenstore-sas-url"

  # Easy Auth expects a full container URL with the SAS query string appended.
  value = "${azurerm_storage_account.token_store.primary_blob_endpoint}${azurerm_storage_container.token_store.name}${data.azurerm_storage_account_blob_container_sas.token_store.sas}"

  expiration_date = formatdate("YYYY-MM-DD'T'hh:mm:ssZ", timeadd(time_rotating.token_store_sas.id, "${var.token_store_sas_rotation_days * 24}h"))

  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

# ---------------------------------------------------------------------------
# CI/CD deploy permissions.
#
# Contributor alone is not enough: `aspire deploy` creates role assignments of
# its own (the APIs' managed identities onto Postgres), which requires
# User Access Administrator. Both are subscription-scoped because azd/Aspire
# creates and names its own resource groups.
# ---------------------------------------------------------------------------

locals {
  subscription_scope = "/subscriptions/${var.subscription_id}"

  cicd_roles = {
    for pair in setproduct(var.cicd_principal_ids, ["Contributor", "User Access Administrator"]) :
    "${pair[0]}|${pair[1]}" => { principal_id = pair[0], role = pair[1] }
  }
}

resource "azurerm_role_assignment" "cicd" {
  for_each = local.cicd_roles

  scope                = local.subscription_scope
  role_definition_name = each.value.role
  principal_id         = each.value.principal_id
}

resource "azurerm_role_assignment" "secret_writer_secrets_officer" {
  for_each = toset(var.secret_writer_principal_ids)

  scope                = azurerm_key_vault.platform.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "secret_writer_reader" {
  for_each = toset(var.secret_writer_principal_ids)

  scope                = azurerm_key_vault.platform.id
  role_definition_name = "Reader"
  principal_id         = each.value
}
