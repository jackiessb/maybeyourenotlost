output "function_app_name" {
  value = azurerm_linux_function_app.event_handler.name
}

output "function_app_default_hostname" {
  value = azurerm_linux_function_app.event_handler.default_hostname
}

output "eventgrid_topic_name" {
  value = azurerm_eventgrid_topic.main.name
}

output "eventgrid_topic_endpoint" {
  value = azurerm_eventgrid_topic.main.endpoint
}
