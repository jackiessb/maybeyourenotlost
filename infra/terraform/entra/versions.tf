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

# Points at wherever the Key Vault lives. Since the subscription migration completed
# that is the M365 tenant's subscription, so these now match var.entra_tenant_id.
#
# The migration needed a second `azurerm.target` alias here: the primary had to stay
# pinned to whichever tenant still held the secret, because Terraform must refresh the
# existing resource there, and repointing the primary would fail on a cross-tenant
# token before it could even plan. With both vault and app registration in aac88807
# that no longer applies, so the alias is gone.
provider "azurerm" {
  features {}

  tenant_id       = var.key_vault_tenant_id
  subscription_id = var.key_vault_subscription_id
}

# Only used when var.manage_github_actions is true. Authenticates with the
# GITHUB_TOKEN environment variable (needs the `repo` scope).
provider "github" {
  owner = var.github_owner
}
