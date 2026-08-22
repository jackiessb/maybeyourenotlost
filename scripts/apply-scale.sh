#!/usr/bin/env bash
set -euo pipefail

# Aspire/azd regenerate each Container App's template from AppHost.cs on every
# provision, which resets scale to the default min 1 / max 10 with no explicit
# rule. Same problem as the custom domain binding, same fix: re-apply here as a
# postprovision/postdeploy hook.
#
# frontend  min 2: the site is ~2.3MB on a cold Safari load (bundle + poster +
#           the mp4 background loop). Scaling out from a single replica takes
#           30-60s, so a burst of arrivals would all land on one 0.5-vCPU
#           replica. A warm second replica absorbs the first cohort.
# *-api     max 3: guards Postgres, not CPU. The B1ms server allows 50
#           connections total; 2 APIs x 3 replicas x the pool size of 5 set in
#           their Program.cs bounds the pair at 30, leaving headroom for
#           migrations at startup and Azure's own monitoring sessions.

FRONTEND_MIN_REPLICAS=2
FRONTEND_MAX_REPLICAS=10
API_MIN_REPLICAS=1
API_MAX_REPLICAS=3

RESOURCE_GROUP=$(echo "${AZURE_CONTAINER_APPS_ENVIRONMENT_ID:-}" | sed -n 's#.*/resourceGroups/\([^/]*\)/.*#\1#p')

if [ -z "$RESOURCE_GROUP" ]; then
  echo "apply-scale: AZURE_CONTAINER_APPS_ENVIRONMENT_ID not set, skipping" >&2
  exit 0
fi

apply() {
  local app="$1" min="$2" max="$3"

  local current
  current=$(az containerapp show -g "$RESOURCE_GROUP" -n "$app" \
    --query "join('/', [to_string(properties.template.scale.minReplicas), to_string(properties.template.scale.maxReplicas)])" \
    -o tsv 2>/dev/null || true)

  if [ "$current" = "$min/$max" ]; then
    echo "apply-scale: $app already at min=$min max=$max"
    return 0
  fi

  echo "apply-scale: setting $app to min=$min max=$max (was ${current:-unknown})"
  az containerapp update -g "$RESOURCE_GROUP" -n "$app" \
    --min-replicas "$min" --max-replicas "$max" \
    --output none
}

apply frontend "$FRONTEND_MIN_REPLICAS" "$FRONTEND_MAX_REPLICAS"
apply contacts-api "$API_MIN_REPLICAS" "$API_MAX_REPLICAS"
apply encouragement-api "$API_MIN_REPLICAS" "$API_MAX_REPLICAS"
