terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.1"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.6"
    }
  }

  # State contains the Entra client secret in cleartext, hence remote state in a
  # versioned, private container rather than on a laptop.
  backend "azurerm" {
    resource_group_name  = "rg-mynl-tfstate"
    storage_account_name = "stmynlstate"
    container_name       = "tfstate"
    key                  = "entra.tfstate"
    use_azuread_auth     = true
    tenant_id            = "aac88807-ec5d-4c7a-8379-0f2baf8123e0"
    subscription_id      = "20aad6af-afbd-4c72-a48d-59ae01ca2cb2"
  }
}

# The Entra layer is administered in the tenant that owns the Microsoft 365
# instance, which is NOT (during the migration) the tenant that owns the Azure
# subscription. Both tenant IDs are therefore explicit rather than inherited
# from whatever `az login` last selected -- getting this wrong produces
# "application not found" errors that read like permission failures.
provider "azuread" {
  tenant_id = var.entra_tenant_id
}

# Points at wherever the Key Vault lives. During the migration that is the old
# subscription in the Default Directory tenant; afterwards it is the M365
# tenant's subscription and these match var.entra_tenant_id.
provider "azurerm" {
  features {}

  tenant_id       = var.key_vault_tenant_id
  subscription_id = var.key_vault_subscription_id
}

# Second vault, during the subscription migration. The primary provider stays pinned to
# whichever tenant currently holds the secret, because Terraform has to refresh the
# existing resource there -- repointing the primary would fail on a cross-tenant token
# before it could even plan. Falls back to mirroring the primary when the migration
# variables are unset, so the alias is always validly configured even though nothing
# uses it.
provider "azurerm" {
  alias = "target"

  features {}

  tenant_id       = var.target_key_vault_tenant_id != "" ? var.target_key_vault_tenant_id : var.key_vault_tenant_id
  subscription_id = var.target_key_vault_subscription_id != "" ? var.target_key_vault_subscription_id : var.key_vault_subscription_id
}

# Only used when var.manage_github_actions is true. Authenticates with the
# GITHUB_TOKEN environment variable (needs the `repo` scope).
provider "github" {
  owner = var.github_owner
}
