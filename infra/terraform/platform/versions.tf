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

  # This module's state contains the token store SAS token. Use remote state.
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-mynl-tfstate"
  #   storage_account_name = "stmynltfstate"
  #   container_name       = "tfstate"
  #   key                  = "platform.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  features {}

  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id
}
