variable "project_name" {
  description = "Short name used as a prefix for all resource names."
  type        = string
  default     = "maybeyourenotlost"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "dotnet_version" {
  description = "Runtime stack version for the Linux Web Apps (must match an Azure-supported .NET on Linux stack)."
  type        = string
  default     = "10.0"
}

variable "postgres_admin_username" {
  description = "Administrator login for the Postgres Flexible Server."
  type        = string
  default     = "psqladmin"
}

variable "postgres_admin_password" {
  description = "Administrator password for the Postgres Flexible Server. Supply via TF_VAR_postgres_admin_password or a .tfvars file that is not committed."
  type        = string
  sensitive   = true
}
