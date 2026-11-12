variable "tenant_id" {
  description = "Tenant owning the target subscription."
  type        = string
}

variable "subscription_id" {
  description = "Subscription receiving the platform resources."
  type        = string
}

variable "location" {
  description = "Azure region. Should match the Container Apps environment's region."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = <<-DESC
    Dedicated resource group for the secret/token-store layer. Deliberately
    separate from the resource group azd/Aspire manages, so `aspire deploy`
    never reconciles resources Terraform owns. Cross-resource-group Key Vault
    references work fine.
  DESC
  type        = string
  default     = "rg-mynl-platform"
}

variable "key_vault_name" {
  description = "Key Vault name. Globally unique, 3-24 chars, alphanumerics and hyphens."
  type        = string
  default     = "kv-mynl"
}

variable "token_store_account_name" {
  description = "Storage account backing the Easy Auth token store. Globally unique, 3-24 lowercase alphanumerics."
  type        = string
  default     = "stmynltokens"
}

variable "token_store_container_name" {
  description = "Blob container holding Easy Auth's token store."
  type        = string
  default     = "easyauth-tokens"
}

variable "token_store_sas_rotation_days" {
  description = <<-DESC
    Rotation cadence for the token store SAS. Shorter than the client secret on
    purpose: an expired SAS makes the token store unreachable, whose failure mode
    (/.auth/me returning 404) is indistinguishable from the original bug this
    whole investigation chased.
  DESC
  type        = number
  default     = 180
}

variable "container_app_principal_ids" {
  description = <<-DESC
    Managed identity principal IDs granted read access to the vault's secrets.
    Empty on first apply: the dashboard Container App does not exist until
    `aspire deploy` has run. Populate after the first deploy with the dashboard
    app's system-assigned identity principal ID and re-apply. See ../README.md
    for the bootstrap ordering.
  DESC
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default = {
    project   = "maybeyourenotlost"
    managedBy = "terraform"
    layer     = "platform"
  }
}

variable "cicd_principal_ids" {
  description = <<-DESC
    CI/CD service principal object IDs, from the entra module's cicd_principal_id
    output. Granted the subscription-scoped roles `aspire deploy` needs. Empty
    until the entra module has been applied with manage_github_actions = true.
  DESC
  type        = list(string)
  default     = []
}

