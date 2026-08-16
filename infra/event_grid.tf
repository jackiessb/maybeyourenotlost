resource "azurerm_eventgrid_topic" "main" {
  name                = "evgt-${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_eventgrid_event_subscription" "event_handler" {
  name  = "sub-event-handler"
  scope = azurerm_eventgrid_topic.main.id

  azure_function_endpoint {
    function_id = "${azurerm_linux_function_app.event_handler.id}/functions/eventHandler"
  }

  included_event_types = ["App.Sample.Event"]
}
