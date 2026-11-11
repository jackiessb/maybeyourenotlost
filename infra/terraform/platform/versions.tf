terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # State contains the token store SAS in cleartext, hence remote state.
  backend "azurerm" {
    resource_group_name  = "rg-mynl-tfstate"
    storage_account_name = "stmynltfstate"
    container_name       = "tfstate"
    key                  = "platform.tfstate"
    use_azuread_auth     = true
    tenant_id            = "e22c9007-0f6b-44b6-a403-af91c309278d"
    subscription_id      = "c1a7d305-fc17-4bba-a6a9-bcb3cad99751"
  }
}

provider "azurerm" {
  features {}

  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id
}
