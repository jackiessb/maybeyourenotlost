output "client_id" {
  description = "Application (client) ID -- feeds the dashboardEntraClientId parameter."
  value       = azuread_application.dashboard.client_id
}

output "tenant_id" {
  description = "Tenant ID -- feeds the dashboardEntraTenantId parameter."
  value       = var.entra_tenant_id
}

output "service_principal_object_id" {
  description = "Enterprise Application object ID, for assigning users outside Terraform if ever needed."
  value       = azuread_service_principal.dashboard.object_id
}

output "redirect_uri" {
  description = "Redirect URI registered on the web platform."
  value       = local.redirect_uri
}

output "client_secret_expiry" {
  description = "When the Easy Auth client secret expires. Past this, sign-in breaks."
  value       = azuread_application_password.dashboard.end_date
}

output "client_secret_key_vault_uri" {
  description = "Versionless Key Vault URI of the client secret, for the Container App's secret reference."
  value       = azurerm_key_vault_secret.client_secret.versionless_id
}

output "assigned_users" {
  description = "UPNs currently permitted to sign in to the dashboard."
  value       = sort(var.dashboard_user_upns)
}

output "apphost_parameters" {
  description = "Values to write into apphost/appsettings.<env>.json after an apply."
  value = {
    dashboardEntraClientId = azuread_application.dashboard.client_id
    dashboardEntraTenantId = var.entra_tenant_id
  }
}

output "cicd_client_id" {
  description = "CI/CD application (client) ID written to AZURE_CLIENT_ID."
  value       = var.manage_github_actions ? azuread_application.cicd[0].client_id : null
}

output "cicd_principal_id" {
  description = "CI/CD service principal object ID. Feeds the platform module's cicd_principal_ids variable."
  value       = var.manage_github_actions ? azuread_service_principal.cicd[0].object_id : null
}
