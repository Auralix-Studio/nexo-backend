#!/usr/bin/env bash
# Deploys the Nexo backend to Azure Container Apps, in the resource group "Nexo".
#
#   deploy/azure/deploy.sh          build the image in Azure (no local Docker) and deploy it
#   deploy/azure/deploy.sh domain   bind api.nexo.aurx.pro with a free managed certificate
#   deploy/azure/deploy.sh status   show the app's address, revision and outbound IPs
#
# Settings come from deploy/azure/.env.production (see env.production.example).
# Every step is idempotent: running it again updates what already exists.
set -euo pipefail

cd "$(dirname "$0")/../.."

RG="${RG:-Nexo}"
LOCATION="${LOCATION:-chilecentral}"
# ACR Tasks (az acr build) is not offered in chilecentral, and the student
# subscription only allows a few regions: the registry lives in canadacentral.
ACR_LOCATION="${ACR_LOCATION:-canadacentral}"
ENV_NAME="${ENV_NAME:-nexo-env}"
APP="${APP:-nexo-api}"
DOMAIN="${DOMAIN:-api.nexo.aurx.pro}"
IMAGE="nexo-backend"
ENV_FILE="${ENV_FILE:-deploy/azure/.env.production}"
MIN_REPLICAS="${MIN_REPLICAS:-0}"
MAX_REPLICAS="${MAX_REPLICAS:-2}"
# The Container Apps ingress reaches the app from private address ranges.
TRUSTED_PROXIES="${TRUSTED_PROXIES:-10.0.0.0/8,100.64.0.0/10,172.16.0.0/12,192.168.0.0/16}"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || fail "Azure CLI (az) is not installed."
az account show -o none 2>/dev/null || fail "Not signed in. Run: az login"
az extension add --name containerapp --upgrade -y -o none 2>/dev/null || true

# A globally unique registry name derived from the subscription.
ACR="${ACR:-nexo$(az account show --query id -o tsv | tr -d '-' | cut -c1-10)ca}"
REGISTRY="$ACR.azurecr.io"

app_exists() { az containerapp show -g "$RG" -n "$APP" -o none 2>/dev/null; }

# Reads KEY=VALUE lines without executing the file: values such as a MongoDB
# URI contain characters ("&", "?") a shell would interpret.
load_env_file() {
  [[ -f "$ENV_FILE" ]] || fail "Missing $ENV_FILE. Copy deploy/azure/env.production.example and fill it in."
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || fail "Invalid line in $ENV_FILE: $key"
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done <"$ENV_FILE"

  for required in MONGODB_URI SECRET_KEY_BASE ADMIN_API_KEY; do
    [[ -n "${!required:-}" ]] || fail "$required is empty in $ENV_FILE"
  done
  [[ ${#SECRET_KEY_BASE} -ge 64 ]] || fail "SECRET_KEY_BASE must have at least 64 characters (mix phx.gen.secret)."
  [[ ${#ADMIN_API_KEY} -ge 32 ]] || fail "ADMIN_API_KEY must have at least 32 characters."
}

deploy() {
  load_env_file

  say "Resource providers"
  for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.OperationalInsights; do
    az provider register -n "$ns" --wait -o none
  done
  az group create -n "$RG" -l "$LOCATION" --tags project=nexo -o none

  say "Container registry $ACR"
  az acr show -n "$ACR" -o none 2>/dev/null ||
    az acr create -g "$RG" -n "$ACR" -l "$ACR_LOCATION" --sku Basic --admin-enabled false -o none

  local tag
  tag="$(git rev-parse --short HEAD)"
  git diff --quiet HEAD -- || tag="$tag-dirty-$(date +%Y%m%d%H%M%S)"

  say "Building $REGISTRY/$IMAGE:$tag in Azure"
  az acr build -r "$ACR" -t "$IMAGE:$tag" -t "$IMAGE:latest" .

  say "Container Apps environment $ENV_NAME"
  az containerapp env show -g "$RG" -n "$ENV_NAME" -o none 2>/dev/null ||
    az containerapp env create -g "$RG" -n "$ENV_NAME" -l "$LOCATION" -o none

  local secrets=(
    "mongodb-uri=$MONGODB_URI"
    "secret-key-base=$SECRET_KEY_BASE"
    "admin-api-key=$ADMIN_API_KEY"
  )
  local env_vars=(
    "PHX_SERVER=true"
    "PORT=4000"
    "PHX_HOST=$DOMAIN"
    "TRUSTED_PROXIES=$TRUSTED_PROXIES"
    "APP_CHECK_MODE=${APP_CHECK_MODE:-enforce}"
    "SIGMA_BASE_URL=${SIGMA_BASE_URL:-https://sigma.upla.edu.pe/api}"
    "MONGODB_URI=secretref:mongodb-uri"
    "SECRET_KEY_BASE=secretref:secret-key-base"
    "ADMIN_API_KEY=secretref:admin-api-key"
  )
  [[ -n "${FIREBASE_PROJECT_NUMBER:-}" ]] && env_vars+=("FIREBASE_PROJECT_NUMBER=$FIREBASE_PROJECT_NUMBER")
  [[ -n "${FIREBASE_APP_IDS:-}" ]] && env_vars+=("FIREBASE_APP_IDS=$FIREBASE_APP_IDS")
  if [[ -n "${AUTHORIZED_TEACHERS:-}" ]]; then
    secrets+=("authorized-teachers=$AUTHORIZED_TEACHERS")
    env_vars+=("AUTHORIZED_TEACHERS=secretref:authorized-teachers")
  fi
  if [[ -n "${SYSTEM_ADMINS:-}" ]]; then
    secrets+=("system-admins=$SYSTEM_ADMINS")
    env_vars+=("SYSTEM_ADMINS=secretref:system-admins")
  fi

  if app_exists; then
    say "Updating $APP"
    az containerapp secret set -g "$RG" -n "$APP" --secrets "${secrets[@]}" -o none
    az containerapp update -g "$RG" -n "$APP" \
      --image "$REGISTRY/$IMAGE:$tag" \
      --set-env-vars "${env_vars[@]}" \
      --min-replicas "$MIN_REPLICAS" --max-replicas "$MAX_REPLICAS" -o none
  else
    say "Creating $APP"
    az containerapp create -g "$RG" -n "$APP" \
      --environment "$ENV_NAME" \
      --image "$REGISTRY/$IMAGE:$tag" \
      --registry-server "$REGISTRY" --registry-identity system \
      --ingress external --target-port 4000 --transport auto \
      --cpu 0.5 --memory 1.0Gi \
      --min-replicas "$MIN_REPLICAS" --max-replicas "$MAX_REPLICAS" \
      --secrets "${secrets[@]}" \
      --env-vars "${env_vars[@]}" -o none
  fi

  status
  cat <<EOF

Next:
  1. MongoDB Atlas > Network Access: allow the outbound IPs listed above.
  2. Check https://<fqdn>/health answers {"status":"ok","db":"ok"}.
  3. Run: deploy/azure/deploy.sh domain
EOF
}

bind_domain() {
  app_exists || fail "Deploy first: deploy/azure/deploy.sh"

  local fqdn verification
  fqdn="$(az containerapp show -g "$RG" -n "$APP" --query properties.configuration.ingress.fqdn -o tsv)"
  verification="$(az containerapp show -g "$RG" -n "$APP" --query properties.customDomainVerificationId -o tsv)"
  local name="${DOMAIN%.aurx.pro}"

  cat <<EOF

Create these records in Hostinger (DNS zone aurx.pro):

  Type   Name            Value
  CNAME  $name        $fqdn
  TXT    asuid.$name  $verification

EOF
  read -rp "Press Enter once both records resolve (nslookup $DOMAIN)... "

  say "Binding $DOMAIN with a managed certificate"
  az containerapp hostname add -g "$RG" -n "$APP" --hostname "$DOMAIN" -o none 2>/dev/null || true
  az containerapp hostname bind -g "$RG" -n "$APP" --environment "$ENV_NAME" \
    --hostname "$DOMAIN" --validation-method CNAME -o none

  say "Answering only $DOMAIN from now on"
  az containerapp update -g "$RG" -n "$APP" --set-env-vars "ALLOWED_HOSTS=$DOMAIN" -o none
  echo "Done: https://$DOMAIN/status"
}

status() {
  app_exists || fail "$APP does not exist in $RG yet."
  say "$APP"
  az containerapp show -g "$RG" -n "$APP" --query "{
    fqdn: properties.configuration.ingress.fqdn,
    revision: properties.latestReadyRevisionName,
    state: properties.runningStatus,
    image: properties.template.containers[0].image,
    minReplicas: properties.template.scale.minReplicas
  }" -o yaml
  echo "outbound IPs:"
  az containerapp show -g "$RG" -n "$APP" --query "properties.outboundIpAddresses" -o tsv
}

case "${1:-deploy}" in
  deploy) deploy ;;
  domain) bind_domain ;;
  status) status ;;
  *) fail "Unknown command: $1 (use: deploy | domain | status)" ;;
esac
