#!/usr/bin/env bash
set -euo pipefail

# Aspire/azd regenerate the frontend Container App's ingress config from
# AppHost.cs on every provision, which has no notion of the custom domain
# binding added out-of-band. That silently drops the binding (and cert) on
# each redeploy, so re-bind it here as a postprovision/postdeploy hook.

HOSTNAME="love.maybeyourenotlost.com"
CONTAINER_APP="frontend"

RESOURCE_GROUP=$(echo "$AZURE_CONTAINER_APPS_ENVIRONMENT_ID" | sed -n 's#.*/resourceGroups/\([^/]*\)/.*#\1#p')
ENVIRONMENT_NAME="$AZURE_CONTAINER_APPS_ENVIRONMENT_NAME"

if [ -z "$RESOURCE_GROUP" ] || [ -z "$ENVIRONMENT_NAME" ]; then
  echo "bind-custom-domain: AZURE_CONTAINER_APPS_ENVIRONMENT_ID/_NAME not set, skipping" >&2
  exit 0
fi

BOUND=$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP" \
  --query "properties.configuration.ingress.customDomains[?name=='$HOSTNAME'].name" -o tsv 2>/dev/null || true)

if [ "$BOUND" = "$HOSTNAME" ]; then
  echo "bind-custom-domain: $HOSTNAME already bound to $CONTAINER_APP"
  exit 0
fi

echo "bind-custom-domain: binding $HOSTNAME to $CONTAINER_APP"
az containerapp hostname bind \
  -g "$RESOURCE_GROUP" \
  -n "$CONTAINER_APP" \
  --hostname "$HOSTNAME" \
  --environment "$ENVIRONMENT_NAME" \
  --validation-method CNAME
