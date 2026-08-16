resource "azurerm_service_plan" "main" {
  name                = "asp-${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

# Bundled build output from `npm run build` in ../functions/event-handler.
# Deps are bundled by esbuild, so only dist/host.json/package.json are needed.
data "archive_file" "event_handler" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/event-handler"
  output_path = "${path.module}/.build/event-handler.zip"

  excludes = [
    "node_modules",
    "src",
    "build.mjs",
    "tsconfig.json",
    "dist/index.js.map",
  ]
}

resource "azurerm_linux_function_app" "event_handler" {
  name                       = "func-${var.project_name}-${var.environment}-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key

  zip_deploy_file = data.archive_file.event_handler.output_path

  site_config {
    application_stack {
      node_version = "20"
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME = "node"
  }
}
