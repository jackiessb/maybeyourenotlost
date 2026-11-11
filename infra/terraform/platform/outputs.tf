output "key_vault_id" {
  description = "Feeds the entra module's key_vault_id variable."
  value       = azurerm_key_vault.platform.id
}

output "key_vault_name" {
  value = azurerm_key_vault.platform.name
}

output "resource_group_name" {
  value = azurerm_resource_group.platform.name
}

output "token_store_account_name" {
  value = azurerm_storage_account.token_store.name
}

output "token_store_sas_secret_uri" {
  description = "Versionless Key Vault URI of the token store SAS URL, for the Container App's secret reference."
  value       = azurerm_key_vault_secret.token_store_sas.versionless_id
}

output "token_store_sas_expiry" {
  description = "When the token store SAS expires. Past this, /.auth/me starts 404ing again."
  value       = azurerm_key_vault_secret.token_store_sas.expiration_date
}

output "container_app_grants_pending" {
  description = "True until container_app_principal_ids is populated after the first aspire deploy."
  value       = length(var.container_app_principal_ids) == 0
}
