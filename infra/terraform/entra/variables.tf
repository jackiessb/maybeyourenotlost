variable "entra_tenant_id" {
  description = <<-DESC
    Tenant that owns the Microsoft 365 instance and hosts the app registration.
    Dashboard users are native members here, so no B2B guest invitations are
    needed -- see docs/plans/entra-auth-as-code.md.
  DESC
  type        = string
}

variable "application_display_name" {
  description = "Display name of the app registration."
  type        = string
  default     = "MYNL Dashboard"
}

variable "dashboard_hostname" {
  description = "Public hostname of the dashboard Container App, without scheme."
  type        = string
  default     = "dash.maybeyourenotlost.com"
}

variable "dashboard_user_upns" {
  description = <<-DESC
    User principal names allowed to sign in to the dashboard. Each gets an
    explicit app role assignment. This list is the ONLY access gate: the service
    principal sets app_role_assignment_required, but every member of the M365
    tenant could otherwise authenticate. Changes here are deliberate and
    reviewed via `terraform plan`.
  DESC
  type        = list(string)
}

variable "client_secret_rotation_days" {
  description = <<-DESC
    How often Terraform rotates the Easy Auth client secret. The credential's
    own expiry is set 30 days beyond this, so a missed apply degrades into a
    warning window rather than an outage.
  DESC
  type        = number
  default     = 365
}

variable "key_vault_id" {
  description = "Resource ID of the Key Vault that receives the client secret. Output by the platform module."
  type        = string
}

variable "key_vault_tenant_id" {
  description = "Tenant of the subscription hosting the Key Vault."
  type        = string
}

variable "key_vault_subscription_id" {
  description = "Subscription hosting the Key Vault."
  type        = string
}

variable "client_secret_name" {
  description = "Key Vault secret name holding the Easy Auth client secret."
  type        = string
  default     = "dashboard-aad-client-secret"
}

# ---------------------------------------------------------------------------
# CI/CD identity (GitHub Actions OIDC)
# ---------------------------------------------------------------------------

variable "manage_github_actions" {
  description = <<-DESC
    Whether to create the CI app registration, its federated credentials, and the
    GitHub Actions environment secrets. Set false to run this module without a
    GitHub token.
  DESC
  type        = bool
  default     = false
}

variable "github_owner" {
  description = "GitHub account or organization owning the repository."
  type        = string
  default     = "jackiessb"
}

variable "github_repository" {
  description = "Repository name, without the owner."
  type        = string
  default     = "maybeyourenotlost"
}

variable "cicd_application_display_name" {
  description = "Display name of the CI/CD app registration."
  type        = string
  default     = "MYNL CI/CD"
}

variable "github_environments" {
  description = <<-DESC
    GitHub Actions environments that deploy, keyed by environment name, with the
    Azure resource group each one targets.

    Note the deliberate naming inversion documented in docs/environment.md: the
    GitHub `production` environment deploys to the Azure resource group named
    `rg-dev`, and the GitHub `dev` environment deploys to `rg-dev-b`. The names
    diverged from when each was created. Do not "fix" these by matching them up.
  DESC
  type = map(object({
    resource_group = string
  }))
  default = {
    production = { resource_group = "rg-dev" }
    dev        = { resource_group = "rg-dev-b" }
  }
}

variable "cicd_subscription_id" {
  description = <<-DESC
    Subscription the CI/CD identity deploys into -- written to each GitHub
    environment as AZURE_SUBSCRIPTION_ID. During the migration this is still the
    old subscription; afterwards it is the new one under the M365 tenant.
  DESC
  type        = string
  default     = ""
}
