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
