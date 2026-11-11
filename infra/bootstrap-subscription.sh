#!/usr/bin/env bash
#
# One-time bootstrap for a NEW Azure subscription, run before any Terraform or
# `aspire deploy`. Safe to re-run: every step is idempotent.
#
# A brand-new subscription has almost no resource providers registered, and
# registration takes a couple of minutes to propagate. Skipping this step does
# not fail fast -- it fails partway through a deploy with errors
# (InvalidAuthenticationToken, SubscriptionNotFound) that point nowhere near
# the actual cause.
#
# Usage:
#   ./bootstrap-subscription.sh <subscription-id> [tenant-id]

set -euo pipefail

SUBSCRIPTION_ID="${1:-}"
TENANT_ID="${2:-}"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo "usage: $0 <subscription-id> [tenant-id]" >&2
  exit 64
fi

# Terraform state storage. Holds the Entra client secret and the token store
# SAS, so it is versioned and private.
STATE_RG="${STATE_RG:-rg-mynl-tfstate}"
STATE_ACCOUNT="${STATE_ACCOUNT:-stmynltfstate}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
LOCATION="${LOCATION:-eastus2}"

PROVIDERS=(
  Microsoft.App                # Container Apps
  Microsoft.ContainerRegistry  # images pushed by aspire deploy
  Microsoft.DBforPostgreSQL    # Postgres Flexible Server
  Microsoft.Insights           # diagnostic settings
  Microsoft.KeyVault           # client secret + token store SAS
  Microsoft.ManagedIdentity    # API -> Postgres auth
  Microsoft.OperationalInsights # Log Analytics workspaces
  Microsoft.Storage            # Easy Auth token store + tf state
)

echo "==> Targeting subscription $SUBSCRIPTION_ID"
if [[ -n "$TENANT_ID" ]]; then
  echo "    (tenant $TENANT_ID)"
  az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
  actual_tenant="$(az account show --query tenantId -o tsv)"
  if [[ "$actual_tenant" != "$TENANT_ID" ]]; then
    echo "ERROR: subscription $SUBSCRIPTION_ID is in tenant $actual_tenant, not $TENANT_ID." >&2
    echo "       Run 'az login --tenant $TENANT_ID' and retry." >&2
    exit 1
  fi
else
  az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
fi

echo "==> Registering resource providers"
for provider in "${PROVIDERS[@]}"; do
  state="$(az provider show --namespace "$provider" --query registrationState -o tsv 2>/dev/null || echo NotFound)"
  if [[ "$state" == "Registered" ]]; then
    printf '    %-30s already registered\n' "$provider"
  else
    printf '    %-30s registering...\n' "$provider"
    az provider register --namespace "$provider" >/dev/null
  fi
done

echo "==> Waiting for registrations to propagate"
for provider in "${PROVIDERS[@]}"; do
  for _ in $(seq 1 60); do
    state="$(az provider show --namespace "$provider" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
    [[ "$state" == "Registered" ]] && break
    sleep 5
  done
  printf '    %-30s %s\n' "$provider" "$state"
done

echo "==> Ensuring Terraform state storage"
az group create --name "$STATE_RG" --location "$LOCATION" --only-show-errors >/dev/null

if ! az storage account show --name "$STATE_ACCOUNT" --resource-group "$STATE_RG" >/dev/null 2>&1; then
  az storage account create \
    --name "$STATE_ACCOUNT" \
    --resource-group "$STATE_RG" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --only-show-errors >/dev/null
  az storage account blob-service-properties update \
    --account-name "$STATE_ACCOUNT" \
    --resource-group "$STATE_RG" \
    --enable-versioning true \
    --only-show-errors >/dev/null
fi

# Grant data-plane access so the azurerm backend can use use_azuread_auth instead
# of a storage key. Covers the current user plus anything in EXTRA_STATE_PRINCIPALS
# (space-separated object IDs).
#
# EXTRA_STATE_PRINCIPALS exists because the entra module spans two tenants: it has
# to run as an M365-tenant identity, which in this tenant is a B2B guest with a
# different object ID and no access of its own. Once infrastructure and Entra live
# in the same tenant, one identity covers everything and this is unnecessary.
current_user="$(az ad signed-in-user show --query id -o tsv)"
account_id="$(az storage account show --name "$STATE_ACCOUNT" --resource-group "$STATE_RG" --query id -o tsv)"

for principal in $current_user ${EXTRA_STATE_PRINCIPALS:-}; do
  az role assignment create \
    --assignee-object-id "$principal" \
    --assignee-principal-type User \
    --role "Storage Blob Data Contributor" \
    --scope "$account_id" \
    --only-show-errors >/dev/null 2>&1 || true
done

az storage container create \
  --name "$STATE_CONTAINER" \
  --account-name "$STATE_ACCOUNT" \
  --auth-mode login \
  --only-show-errors >/dev/null

cat <<SUMMARY

==> Done. Backend configuration for infra/terraform/*/versions.tf:

  backend "azurerm" {
    resource_group_name  = "$STATE_RG"
    storage_account_name = "$STATE_ACCOUNT"
    container_name       = "$STATE_CONTAINER"
    key                  = "<entra|platform>.tfstate"
    use_azuread_auth     = true
  }

Next: infra/terraform/README.md
SUMMARY
