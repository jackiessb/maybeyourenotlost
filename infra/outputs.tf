output "encouragement_api_name" {
  value = azurerm_linux_web_app.encouragement_api.name
}

output "encouragement_api_default_hostname" {
  value = azurerm_linux_web_app.encouragement_api.default_hostname
}

output "contacts_api_name" {
  value = azurerm_linux_web_app.contacts_api.name
}

output "contacts_api_default_hostname" {
  value = azurerm_linux_web_app.contacts_api.default_hostname
}

output "postgres_server_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}
