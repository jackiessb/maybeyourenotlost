resource "azurerm_service_plan" "main" {
  name                = "asp-${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "encouragement_api" {
  name                = "app-${var.project_name}-encouragement-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id

  site_config {
    application_stack {
      dotnet_version = var.dotnet_version
    }
  }

  app_settings = {
    ASPNETCORE_ENVIRONMENT = "Production"
  }

  connection_string {
    name  = "Postgres"
    type  = "PostgreSQL"
    value = "Host=${azurerm_postgresql_flexible_server.main.fqdn};Database=${azurerm_postgresql_flexible_server_database.encouragement.name};Username=${var.postgres_admin_username};Password=${var.postgres_admin_password};Ssl Mode=Require"
  }
}

resource "azurerm_linux_web_app" "contacts_api" {
  name                = "app-${var.project_name}-contacts-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id

  site_config {
    application_stack {
      dotnet_version = var.dotnet_version
    }
  }

  app_settings = {
    ASPNETCORE_ENVIRONMENT = "Production"
  }

  connection_string {
    name  = "Postgres"
    type  = "PostgreSQL"
    value = "Host=${azurerm_postgresql_flexible_server.main.fqdn};Database=${azurerm_postgresql_flexible_server_database.contacts.name};Username=${var.postgres_admin_username};Password=${var.postgres_admin_password};Ssl Mode=Require"
  }
}
