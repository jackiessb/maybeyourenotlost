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
    storage_account_name = "stmynlstate"
    container_name       = "tfstate"
    key                  = "platform.tfstate"
    use_azuread_auth     = true
    tenant_id            = "aac88807-ec5d-4c7a-8379-0f2baf8123e0"
    subscription_id      = "20aad6af-afbd-4c72-a48d-59ae01ca2cb2"
  }
}

provider "azurerm" {
  features {}

  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id
}
