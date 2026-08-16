# Storage account names must be globally unique, lowercase alphanumeric, <=24 chars.
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "main" {
  name                     = "st${substr(replace(lower(var.project_name), "-", ""), 0, 8)}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
