#!/usr/bin/env bash
# ==============================================================================
# Portal Install Script
# Sets up .env files, generates JWT + service tokens, propagates cross-service
# secrets, and ensures supervisord / nginx conf files are in place.
#
# Usage:
#   ./install.sh            # Skip services whose .env already exists
#   ./install.sh --force    # Overwrite existing .env files
#
# Run from:  Local Docker/
# ==============================================================================

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_ROOT="$(realpath "$SCRIPT_DIR/../laravel")"
SUPERVISOR_CONF="$SCRIPT_DIR/php/supervisor.d/supervisord.conf"
NGINX_CONF_DIR="$SCRIPT_DIR/nginx/conf.d"

# ── Disable services here (leave array empty to enable all) ─────────────────
# Add exact service names from SERVICES below to skip them entirely.
# Example:  DISABLED_SERVICES=("Airtable-Service" "Integration-Service")
DISABLED_SERVICES=(
  # "Billing-Service"
  # "Subscriptions-Service"
  # "Task-Service"
  # "Forms-Service"
  # "File-Management-Service"
  # "Integration-Service"
  # "Airtable-Service"
)

# ── Portal services ───────────────────────────────────────────────────────────
SERVICES=(
  "Core-Service"
  "Notifications-Service"
  "Billing-Service"
  "Inventory-Service"
  "Subscriptions-Service"
  "Task-Service"
  "Forms-Service"
  "File-Management-Service"
  "Integration-Service"
  "Airtable-Service"
  "FrontEnd"
)

# ── Nginx template → service mapping ─────────────────────────────────────────
# Keys must match filenames under nginx/templates/ (without .conf)
# Values must match entries in SERVICES above
declare -A NGINX_TEMPLATE_MAP
NGINX_TEMPLATE_MAP["core"]="Core-Service"
NGINX_TEMPLATE_MAP["notifications"]="Notifications-Service"
NGINX_TEMPLATE_MAP["billing"]="Billing-Service"
NGINX_TEMPLATE_MAP["inventory"]="Inventory-Service"
NGINX_TEMPLATE_MAP["subscriptions"]="Subscriptions-Service"
NGINX_TEMPLATE_MAP["tasks"]="Task-Service"
NGINX_TEMPLATE_MAP["forms"]="Forms-Service"
NGINX_TEMPLATE_MAP["files"]="File-Management-Service"
NGINX_TEMPLATE_MAP["integration"]="Integration-Service"
NGINX_TEMPLATE_MAP["airtable"]="Airtable-Service"
NGINX_TEMPLATE_MAP["portal"]="FrontEnd"

# ── Git repository URLs ──────────────────────────────────────────────────────
declare -A SVC_REPO
SVC_REPO["Core-Service"]="git@github.com:AiroTax/Core-Service-Restructure.git"
SVC_REPO["Notifications-Service"]="git@github.com:AiroTax/NotificationAndLogs.git"
SVC_REPO["Billing-Service"]="git@github.com:AiroTax/Billing-Service.git"
SVC_REPO["Inventory-Service"]="git@github.com:AiroTax/Inventory-Service.git"
SVC_REPO["Subscriptions-Service"]="git@github.com:AiroTax/Subscriptions-Service.git"
SVC_REPO["Task-Service"]="git@github.com:AiroTax/Task-Service.git"
SVC_REPO["Forms-Service"]="git@github.com:AiroTax/Forms-Service.git"
SVC_REPO["File-Management-Service"]="git@github.com:AiroTax/File-Management-Service.git"
SVC_REPO["Integration-Service"]="git@github.com:AiroTax/Integration-Service.git"
SVC_REPO["Airtable-Service"]="git@github.com:AiroTax/Airtable-Sync.git"
SVC_REPO["FrontEnd"]="git@github.com:AiroTax/FrontEnd.git"

# ── Per-service identity, DB type, DB name, Redis DB index ───────────────────
# DB_TYPE: "mongo" = MongoDB primary  |  "mysql" = MySQL primary
declare -A SVC_APP_NAME SVC_SERVICE_NAME SVC_DB_TYPE SVC_DB_NAME SVC_REDIS_DB

SVC_APP_NAME["Core-Service"]="Core Service"
SVC_APP_NAME["Notifications-Service"]="Notification Service"
SVC_APP_NAME["Billing-Service"]="Billing Service"
SVC_APP_NAME["Inventory-Service"]="Inventory Service"
SVC_APP_NAME["Subscriptions-Service"]="Subscriptions Service"
SVC_APP_NAME["Task-Service"]="Task Service"
SVC_APP_NAME["Forms-Service"]="Forms Service"
SVC_APP_NAME["File-Management-Service"]="File Management Service"
SVC_APP_NAME["Integration-Service"]="Integration Service"
SVC_APP_NAME["Airtable-Service"]="Airtable Service"

SVC_SERVICE_NAME["Core-Service"]="core-service"
SVC_SERVICE_NAME["Notifications-Service"]="notifications-service"
SVC_SERVICE_NAME["Billing-Service"]="billing-service"
SVC_SERVICE_NAME["Inventory-Service"]="inventory-service"
SVC_SERVICE_NAME["Subscriptions-Service"]="subscriptions-service"
SVC_SERVICE_NAME["Task-Service"]="task-service"
SVC_SERVICE_NAME["Forms-Service"]="forms-service"
SVC_SERVICE_NAME["File-Management-Service"]="file-management-service"
SVC_SERVICE_NAME["Integration-Service"]="integration-service"
SVC_SERVICE_NAME["Airtable-Service"]="airtable-service"

SVC_DB_TYPE["Core-Service"]="mongo"
SVC_DB_TYPE["Notifications-Service"]="mongo"
SVC_DB_TYPE["Billing-Service"]="mongo"
SVC_DB_TYPE["Inventory-Service"]="mongo"
SVC_DB_TYPE["Subscriptions-Service"]="mongo"
SVC_DB_TYPE["Task-Service"]="mongo"
SVC_DB_TYPE["Forms-Service"]="mongo"
SVC_DB_TYPE["File-Management-Service"]="mongo"
SVC_DB_TYPE["Integration-Service"]="mysql"
SVC_DB_TYPE["Airtable-Service"]="mongo"

SVC_DB_NAME["Core-Service"]="core_service"
SVC_DB_NAME["Notifications-Service"]="notifications"
SVC_DB_NAME["Billing-Service"]="billing"
SVC_DB_NAME["Inventory-Service"]="inventory"
SVC_DB_NAME["Subscriptions-Service"]="subscriptions"
SVC_DB_NAME["Task-Service"]="tasks"
SVC_DB_NAME["Forms-Service"]="forms"
SVC_DB_NAME["File-Management-Service"]="file_management"
SVC_DB_NAME["Integration-Service"]="integration"
SVC_DB_NAME["Airtable-Service"]="airtable_sync"

# Subdomain prefix — used to construct APP_URL (https://<subdomain>.<domain>)
declare -A SVC_SUBDOMAIN
SVC_SUBDOMAIN["Core-Service"]="core"
SVC_SUBDOMAIN["Notifications-Service"]="notifications"
SVC_SUBDOMAIN["Billing-Service"]="billing"
SVC_SUBDOMAIN["Inventory-Service"]="inventory"
SVC_SUBDOMAIN["Subscriptions-Service"]="subscriptions"
SVC_SUBDOMAIN["Task-Service"]="tasks"
SVC_SUBDOMAIN["Forms-Service"]="forms"
SVC_SUBDOMAIN["File-Management-Service"]="files"
SVC_SUBDOMAIN["Integration-Service"]="integration"
SVC_SUBDOMAIN["Airtable-Service"]="airtable"

# Redis DB index: one unique integer per service (0-9)
SVC_REDIS_DB["Core-Service"]=0
SVC_REDIS_DB["Notifications-Service"]=1
SVC_REDIS_DB["Billing-Service"]=2
SVC_REDIS_DB["Inventory-Service"]=3
SVC_REDIS_DB["Subscriptions-Service"]=4
SVC_REDIS_DB["Task-Service"]=5
SVC_REDIS_DB["Forms-Service"]=6
SVC_REDIS_DB["File-Management-Service"]=7
SVC_REDIS_DB["Integration-Service"]=8
SVC_REDIS_DB["Airtable-Service"]=9

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf "\033[0;34m[INFO]\033[0m  %s\n" "$*"; }
ok()      { printf "\033[0;32m[ OK ]\033[0m  %s\n" "$*"; }
warn()    { printf "\033[0;33m[WARN]\033[0m  %s\n" "$*"; }
err()     { printf "\033[0;31m[ERR ]\033[0m  %s\n" "$*" >&2; }
sep()     { printf "\033[0;90m%s\033[0m\n" "──────────────────────────────────────────────────"; }

# Returns 0 (true) if service is NOT in DISABLED_SERVICES
is_enabled() {
  local svc="$1"
  [[ ${#DISABLED_SERVICES[@]} -eq 0 ]] && return 0
  for d in "${DISABLED_SERVICES[@]}"; do
    [[ "$d" == "$svc" ]] && return 1
  done
  return 0
}

# Set or add a KEY=VALUE in an .env file (in-place, safe for values with slashes)
set_env() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s' "$key" "$value" >> "$file"
  fi
}

# Generate a Laravel APP_KEY  (base64:<32 random bytes>)
gen_app_key() {
  printf 'base64:%s' "$(openssl rand -base64 32)"
}

# ── Parse args ────────────────────────────────────────────────────────────────
FORCE=false
DOMAIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)        FORCE=true ;;
    --domain)       DOMAIN="$2"; shift ;;
    --domain=*)     DOMAIN="${1#--domain=}" ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

# ── Sanity check ──────────────────────────────────────────────────────────────
mkdir -p "$SERVICES_ROOT"

if [[ -z "$DOMAIN" ]]; then
  printf "  Enter base domain (e.g. example.com): "
  read -r DOMAIN
fi

if [[ -z "$DOMAIN" ]]; then
  err "Domain is required. Pass --domain=example.com or enter it at the prompt."
  exit 1
fi

echo ""
printf "\033[1;36m  Portal Install Script\033[0m\n"
echo "  Services root    : $SERVICES_ROOT"
echo "  Domain           : $DOMAIN"
echo "  Force            : $FORCE"
if [[ ${#DISABLED_SERVICES[@]} -gt 0 ]]; then
  echo "  Disabled services: ${DISABLED_SERVICES[*]}"
else
  echo "  Disabled services: (none)"
fi
sep

# ==============================================================================
# STEP 0 — Clone / verify service repositories
# ==============================================================================
info "Step 0/8  Cloning service repositories"

for svc in "${SERVICES[@]}"; do
  is_enabled "$svc" || { warn "  $svc  →  disabled, skipping"; continue; }
  repo="${SVC_REPO[$svc]:-}"
  dir="$SERVICES_ROOT/$svc"

  if [[ -z "$repo" ]]; then
    warn "  $svc  →  no repo URL defined, skipping"
    continue
  fi

  if [[ -d "$dir/.git" ]]; then
    ok "  $svc  →  already cloned (skipping)"
  else
    info "  $svc  →  cloning from $repo"
    if git clone "$repo" "$dir"; then
      ok "  $svc  →  cloned successfully"
    else
      err "  $svc  →  git clone failed — check SSH keys and network access"
      exit 1
    fi
  fi
done

sep

# ==============================================================================
# STEP 1 — Create Docker .env from .env.example (with generated credentials)
# ==============================================================================
info "Step 1/8  Creating Docker .env"

DOCKER_ENV="$SCRIPT_DIR/.env"
DOCKER_ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

if [[ ! -f "$DOCKER_ENV_EXAMPLE" ]]; then
  err "  $DOCKER_ENV_EXAMPLE not found — cannot create Docker .env"
  exit 1
fi

if [[ -f "$DOCKER_ENV" ]] && [[ "$FORCE" == false ]]; then
  warn "  Docker .env already exists (use --force to overwrite)"
else
  cp "$DOCKER_ENV_EXAMPLE" "$DOCKER_ENV"

  # Generate strong random credentials
  MYSQL_ROOT_PASS="$(openssl rand -hex 20)"
  MYSQL_USER_PASS="$(openssl rand -hex 20)"
  MONGO_ROOT_PASS="$(openssl rand -hex 20)"

  set_env "$DOCKER_ENV" "MYSQL_ROOT_PASSWORD" "$MYSQL_ROOT_PASS"
  set_env "$DOCKER_ENV" "MYSQL_PASSWORD"      "$MYSQL_USER_PASS"
  set_env "$DOCKER_ENV" "MONGO_INITDB_ROOT_PASSWORD" "$MONGO_ROOT_PASS"

  ok "  Docker .env created with generated credentials"
  echo "       MYSQL_ROOT_PASSWORD = $MYSQL_ROOT_PASS"
  echo "       MYSQL_PASSWORD      = $MYSQL_USER_PASS"
  echo "       MONGO_ROOT_PASSWORD = $MONGO_ROOT_PASS"
fi

# Read DB credentials from Docker .env (for use in per-service configuration)
DOCKER_MYSQL_USER="$(grep '^MYSQL_USER=' "$DOCKER_ENV" | cut -d= -f2-)"
DOCKER_MYSQL_PASS="$(grep '^MYSQL_PASSWORD=' "$DOCKER_ENV" | cut -d= -f2-)"
DOCKER_MONGO_USER="$(grep '^MONGO_INITDB_ROOT_USERNAME=' "$DOCKER_ENV" | cut -d= -f2-)"
DOCKER_MONGO_PASS="$(grep '^MONGO_INITDB_ROOT_PASSWORD=' "$DOCKER_ENV" | cut -d= -f2-)"

sep

# ==============================================================================
# STEP 2 — Copy .env.example → .env
# ==============================================================================
info "Step 2/8  Creating .env files from .env.example"

for svc in "${SERVICES[@]}"; do
  is_enabled "$svc" || { warn "  $svc  →  disabled, skipping"; continue; }
  dir="$SERVICES_ROOT/$svc"

  if [[ ! -d "$dir" ]]; then
    warn "  $svc  →  directory not found, skipping"
    continue
  fi

  if [[ ! -f "$dir/.env.example" ]]; then
    warn "  $svc  →  no .env.example found, skipping"
    continue
  fi

  if [[ -f "$dir/.env" ]] && [[ "$FORCE" == false ]]; then
    warn "  $svc  →  .env already exists (use --force to overwrite)"
  else
    cp "$dir/.env.example" "$dir/.env"
    ok "  $svc  →  .env created"
  fi
done

sep

# ==============================================================================
# STEP 3 — Per-service identity, database, and Redis configuration
# ==============================================================================
info "Step 3/8  Configuring APP_NAME, DB, Redis per service"

for svc in "${SERVICES[@]}"; do
  is_enabled "$svc" || continue
  [[ "$svc" == "FrontEnd" ]] && continue  # Vue SPA — handled in separate block below
  env_file="$SERVICES_ROOT/$svc/.env"
  [[ ! -f "$env_file" ]] && continue

  app_name="${SVC_APP_NAME[$svc]:-$svc}"
  svc_name="${SVC_SERVICE_NAME[$svc]:-$svc}"
  db_name="${SVC_DB_NAME[$svc]:-}"
  redis_db="${SVC_REDIS_DB[$svc]:-0}"
  db_type="${SVC_DB_TYPE[$svc]:-mongo}"
  subdomain="${SVC_SUBDOMAIN[$svc]:-}"
  app_url="https://${subdomain}.${DOMAIN}"

  # ── Identity ────────────────────────────────────────────────────────────────
  set_env "$env_file" "APP_NAME"     "\"$app_name\""
  set_env "$env_file" "APP_ENV"      "production"
  set_env "$env_file" "APP_DEBUG"    "false"
  set_env "$env_file" "APP_URL"      "$app_url"
  set_env "$env_file" "LOG_LEVEL"    "error"
  set_env "$env_file" "SERVICE_NAME" "$svc_name"

  # ── Session ──────────────────────────────────────────────────────────────────
  set_env "$env_file" "SESSION_DRIVER"   "redis"
  set_env "$env_file" "SESSION_LIFETIME" "120"
  set_env "$env_file" "SESSION_ENCRYPT"  "false"
  set_env "$env_file" "SESSION_PATH"     "/"
  set_env "$env_file" "SESSION_DOMAIN"   "null"

  # ── Redis ───────────────────────────────────────────────────────────────────
  set_env "$env_file" "REDIS_CLIENT"      "phpredis"
  set_env "$env_file" "REDIS_HOST"        "redis"
  set_env "$env_file" "REDIS_PASSWORD"    ""
  set_env "$env_file" "REDIS_PORT"        "6379"
  set_env "$env_file" "REDIS_DB"          "$redis_db"

  # ── Queue & Cache ─────────────────────────────────────────────────────────
  set_env "$env_file" "QUEUE_CONNECTION"   "redis"
  set_env "$env_file" "CACHE_STORE"        "redis"
  set_env "$env_file" "BROADCAST_CONNECTION" "log"

  # ── Mail (log fallback — replace MAIL_* post-install for real delivery) ──────
  set_env "$env_file" "MAIL_MAILER"       "log"
  set_env "$env_file" "MAIL_HOST"         "localhost"
  set_env "$env_file" "MAIL_PORT"         "587"
  set_env "$env_file" "MAIL_USERNAME"     ""
  set_env "$env_file" "MAIL_PASSWORD"     ""
  set_env "$env_file" "MAIL_ENCRYPTION"   "tls"
  set_env "$env_file" "MAIL_FROM_ADDRESS" "noreply@${DOMAIN}"
  set_env "$env_file" "MAIL_FROM_NAME"    "\"$app_name\""

  # ── Database ────────────────────────────────────────────────────────────────
  if [[ "$db_type" == "mongo" ]]; then
    # Primary: MongoDB
    set_env "$env_file" "DB_CONNECTION" "mongodb"
    set_env "$env_file" "DB_HOST"       "mongodb"
    set_env "$env_file" "DB_PORT"       "27017"
    set_env "$env_file" "DB_DATABASE"   "$db_name"
    set_env "$env_file" "DB_USERNAME"   "$DOCKER_MONGO_USER"
    set_env "$env_file" "DB_PASSWORD"   "$DOCKER_MONGO_PASS"
    # Secondary: MySQL (for services that declare MYSQL_DB_* in their .env.example)
    if grep -q "^MYSQL_DB_HOST=" "$SERVICES_ROOT/$svc/.env.example" 2>/dev/null; then
      set_env "$env_file" "MYSQL_DB_HOST"     "mysql"
      set_env "$env_file" "MYSQL_DB_PORT"     "3306"
      set_env "$env_file" "MYSQL_DB_DATABASE" "$db_name"
      set_env "$env_file" "MYSQL_DB_USERNAME" "$DOCKER_MYSQL_USER"
      set_env "$env_file" "MYSQL_DB_PASSWORD" "$DOCKER_MYSQL_PASS"
    fi
  else
    # Integration-Service: primary is MySQL only
    set_env "$env_file" "DB_CONNECTION" "mysql"
    set_env "$env_file" "DB_HOST"       "mysql"
    set_env "$env_file" "DB_PORT"       "3306"
    set_env "$env_file" "DB_DATABASE"   "$db_name"
    set_env "$env_file" "DB_USERNAME"   "$DOCKER_MYSQL_USER"
    set_env "$env_file" "DB_PASSWORD"   "$DOCKER_MYSQL_PASS"
  fi

  ok "  $svc  →  APP_NAME / APP_URL / Redis / DB configured (url=${app_url}, db=${db_type}, redis=${redis_db})"
done

# ── Reverb / broadcast env for Notifications-Service ─────────────────────────
if is_enabled "Notifications-Service"; then
  notif_env="$SERVICES_ROOT/Notifications-Service/.env"
  if [[ -f "$notif_env" ]]; then
    set_env "$notif_env" "BROADCAST_DRIVER"   "reverb"
    set_env "$notif_env" "REVERB_APP_ID"      "reverb"
    set_env "$notif_env" "REVERB_APP_KEY"     "8h5nmwzamzubt6mon5fl"
    set_env "$notif_env" "REVERB_APP_SECRET"  "8h5nmwzamzubt6mon5fl"
    set_env "$notif_env" "REVERB_HOST"        "0.0.0.0"
    set_env "$notif_env" "REVERB_PORT"        "6001"
    set_env "$notif_env" "REVERB_SCHEME"      "http"
    set_env "$notif_env" "REVERB_PATH"        "/"
    set_env "$notif_env" "REVERB_APP_CLUSTER" "false"
    set_env "$notif_env" "SESSION_LIFETIME"   "120"
    set_env "$notif_env" "SESSION_ENCRYPT"    "false"
    set_env "$notif_env" "SESSION_PATH"       "/"
    set_env "$notif_env" "SESSION_DOMAIN"     "null"
    ok "  Notifications-Service  →  Reverb/broadcast env set"
  fi
fi

# ── FrontEnd (Vue SPA) — VITE_ API endpoints ─────────────────────────────────
if is_enabled "FrontEnd"; then
  fe_env="$SERVICES_ROOT/FrontEnd/.env"
  if [[ -f "$fe_env" ]]; then
    set_env "$fe_env" "VITE_ENVIRONMENT"          "production"
    set_env "$fe_env" "VITE_PORTAL_NAME"          "Portal"
    set_env "$fe_env" "VITE_API_BASE_URL"         "https://core.${DOMAIN}"
    set_env "$fe_env" "VITE_BASE_SERVER"          "https://core.${DOMAIN}"
    set_env "$fe_env" "VITE_NOTIFICATION_SERVER"  "https://notifications.${DOMAIN}"
    set_env "$fe_env" "VITE_AIRTABLE_SERVER"      "https://airtable.${DOMAIN}"
    set_env "$fe_env" "VITE_INVENTORY_SERVER"     "https://inventory.${DOMAIN}"
    set_env "$fe_env" "VITE_BILLING_SERVER"       "https://billing.${DOMAIN}"
    set_env "$fe_env" "VITE_INTEGRATION_SERVER"   "https://integration.${DOMAIN}"
    set_env "$fe_env" "VITE_SUBSCRIPTIONS_SERVER" "https://subscriptions.${DOMAIN}"
    set_env "$fe_env" "VITE_TASK_SERVER"          "https://tasks.${DOMAIN}"
    set_env "$fe_env" "VITE_FORMS_SERVER"         "https://forms.${DOMAIN}"
    set_env "$fe_env" "VITE_PUSHER_HOST"          "notifications.${DOMAIN}"
    set_env "$fe_env" "VITE_PUSHER_PORT"          "443"
    set_env "$fe_env" "VITE_PUSHER_APP_KEY"       "8h5nmwzamzubt6mon5fl"
    ok "  FrontEnd  →  VITE_ API endpoints configured"
  fi
fi

sep

# ==============================================================================
# STEP 4 — Generate APP_KEY for each service
# ==============================================================================
info "Step 4/8  Generating APP_KEY for each service"

for svc in "${SERVICES[@]}"; do
  is_enabled "$svc" || continue
  [[ "$svc" == "FrontEnd" ]] && continue  # Vue SPA — no APP_KEY needed
  env_file="$SERVICES_ROOT/$svc/.env"
  [[ ! -f "$env_file" ]] && continue
  set_env "$env_file" "APP_KEY" "$(gen_app_key)"
  ok "  $svc  →  APP_KEY set"
done

sep

# ==============================================================================
# STEP 5 — Generate shared JWT_SECRET
# ==============================================================================
info "Step 5/8  Generating shared JWT_SECRET"

JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 64)"
ok "  JWT_SECRET generated (64 chars)"

for svc in "${SERVICES[@]}"; do
  is_enabled "$svc" || continue
  [[ "$svc" == "FrontEnd" ]] && continue  # Vue SPA — no JWT_SECRET needed
  env_file="$SERVICES_ROOT/$svc/.env"
  [[ ! -f "$env_file" ]] && continue
  set_env "$env_file" "JWT_SECRET" "$JWT_SECRET"
done
ok "  JWT_SECRET written to all enabled service .env files"

sep

# ==============================================================================
# STEP 6 — Generate per-service SERVICE_TOKENs
# ==============================================================================
info "Step 6/8  Generating per-service SERVICE_TOKENs"

declare -A TOKENS
TOKENS[Core-Service]="$(openssl rand -hex 32)"
TOKENS[Notifications-Service]="$(openssl rand -hex 32)"
TOKENS[Billing-Service]="$(openssl rand -hex 32)"
TOKENS[Inventory-Service]="$(openssl rand -hex 32)"
TOKENS[Subscriptions-Service]="$(openssl rand -hex 32)"
TOKENS[Task-Service]="$(openssl rand -hex 32)"
TOKENS[Forms-Service]="$(openssl rand -hex 32)"
TOKENS[File-Management-Service]="$(openssl rand -hex 32)"
TOKENS[Integration-Service]="$(openssl rand -hex 32)"
TOKENS[Airtable-Service]="$(openssl rand -hex 32)"

# Write each service's own SERVICE_TOKEN into its .env
for svc in "${!TOKENS[@]}"; do
  is_enabled "$svc" || continue
  env_file="$SERVICES_ROOT/$svc/.env"
  [[ ! -f "$env_file" ]] && continue
  set_env "$env_file" "SERVICE_TOKEN" "${TOKENS[$svc]}"
  ok "  $svc  →  SERVICE_TOKEN set"
done

sep

# ==============================================================================
# STEP 7 — Propagate cross-service tokens
# ==============================================================================
info "Step 7/8  Propagating cross-service tokens"

# Helper: write a cross-service token into target services' .env files,
# but only if the target service is enabled.
propagate() {
  local key="$1" value="$2"; shift 2
  for target in "$@"; do
    is_enabled "$target" || continue
    env_file="$SERVICES_ROOT/$target/.env"
    [[ ! -f "$env_file" ]] && continue
    set_env "$env_file" "$key" "$value"
  done
}

NOTIF_TOKEN="${TOKENS[Notifications-Service]}"
CORE_TOKEN="${TOKENS[Core-Service]}"
BILLING_TOKEN="${TOKENS[Billing-Service]}"
INVENTORY_TOKEN="${TOKENS[Inventory-Service]}"
INTEGRATION_TOKEN="${TOKENS[Integration-Service]}"
TASK_TOKEN="${TOKENS[Task-Service]}"
AIRTABLE_TOKEN="${TOKENS[Airtable-Service]}"

propagate "NOTIFICATION_SERVICE_TOKEN" "$NOTIF_TOKEN" \
  Core-Service Billing-Service Notifications-Service Inventory-Service \
  Subscriptions-Service Task-Service Forms-Service \
  File-Management-Service Integration-Service Airtable-Service
ok "  NOTIFICATION_SERVICE_TOKEN  →  all enabled backend services"

propagate "CORE_SERVICE_TOKEN" "$CORE_TOKEN" \
  Integration-Service Subscriptions-Service Task-Service Airtable-Service
ok "  CORE_SERVICE_TOKEN          →  Integration, Subscriptions, Task, Airtable-Service"

propagate "CORE_SERVICE" "https://core.${DOMAIN}" \
  Integration-Service Subscriptions-Service Task-Service Airtable-Service
ok "  CORE_SERVICE URL            →  Integration, Subscriptions, Task, Airtable-Service"

propagate "BILLING_SERVICE_TOKEN" "$BILLING_TOKEN" \
  Integration-Service Task-Service
ok "  BILLING_SERVICE_TOKEN       →  Integration, Task"

propagate "INVENTORY_SERVICE_TOKEN" "$INVENTORY_TOKEN" \
  Integration-Service Task-Service Airtable-Service
ok "  INVENTORY_SERVICE_TOKEN     →  Integration, Task, Airtable-Service"

propagate "INTEGRATION_SERVICE_TOKEN" "$INTEGRATION_TOKEN" \
  Task-Service
ok "  INTEGRATION_SERVICE_TOKEN   →  Task-Service"

propagate "TASK_SERVICE_TOKEN" "$TASK_TOKEN" \
  Airtable-Service
ok "  TASK_SERVICE_TOKEN          →  Airtable-Service"

propagate "AIRTABLE_SYNC_SERVICE_TOKEN" "$AIRTABLE_TOKEN" \
  Task-Service
ok "  AIRTABLE_SYNC_SERVICE_TOKEN →  Task-Service"

# ── Service endpoint URLs ───────────────────────────────────────────────────
# All backend services need to know the notifications endpoint URL
propagate "NOTIFICATION_SERVICE" "https://notifications.${DOMAIN}" \
  Core-Service Billing-Service Inventory-Service Subscriptions-Service \
  Task-Service Forms-Service File-Management-Service Integration-Service Airtable-Service
ok "  NOTIFICATION_SERVICE URL     →  all enabled backend services"

# Notifications-Service needs frontend URL (for CORS / redirect) and the Core DB name
if is_enabled "Notifications-Service"; then
  notif_env="$SERVICES_ROOT/Notifications-Service/.env"
  if [[ -f "$notif_env" ]]; then
    set_env "$notif_env" "FRONTEND_URL"  "https://portal.${DOMAIN}"
    set_env "$notif_env" "CORE_DATABASE" "${SVC_DB_NAME[Core-Service]}"
    ok "  FRONTEND_URL / CORE_DATABASE   →  Notifications-Service"
  fi
fi

sep

# ==============================================================================
# STEP 8 — Supervisord & nginx conf files
# ==============================================================================
info "Step 8/8  Setting up supervisord and nginx configuration"

# ── Supervisord ───────────────────────────────────────────────────────────────
# Appends one [program:] block per service to the supervisord conf file.
write_supervisor_program() {
  local name="$1" svc_dir="$2" numprocs="${3:-2}" extra_queue="${4:-}"
  cat >> "$SUPERVISOR_CONF" <<EOF

[program:queue-${name}]
process_name=%(program_name)s_%(process_num)02d
command=php /var/www/html/${svc_dir}/artisan queue:work --sleep=3 --tries=3 --timeout=90
autostart=true
autorestart=true
user=root
numprocs=${numprocs}
redirect_stderr=true
stdout_logfile=/var/www/html/${svc_dir}/storage/logs/supervisor-queue.log
EOF
  if [[ -n "$extra_queue" ]]; then
    cat >> "$SUPERVISOR_CONF" <<EOF

[program:queue-${name}-${extra_queue}]
process_name=%(program_name)s_%(process_num)02d
command=php /var/www/html/${svc_dir}/artisan queue:work --queue=${extra_queue} --sleep=3 --tries=3 --timeout=90
autostart=true
autorestart=true
user=root
numprocs=2
redirect_stderr=true
stdout_logfile=/var/www/html/${svc_dir}/storage/logs/supervisor-queue.log
EOF
  fi
}

if [[ -f "$SUPERVISOR_CONF" ]] && [[ "$FORCE" == false ]]; then
  ok "  Supervisord conf exists (use --force to regenerate)"
else
  mkdir -p "$(dirname "$SUPERVISOR_CONF")"
  printf '; Portal services — supervisord program definitions (generated by install.sh)\n' > "$SUPERVISOR_CONF"

  is_enabled "Core-Service"            && write_supervisor_program "core-service"      "Core-Service"            2
  is_enabled "Notifications-Service"   && write_supervisor_program "notifications"     "Notifications-Service"   4
  is_enabled "Billing-Service"         && write_supervisor_program "billing"           "Billing-Service"         2
  is_enabled "Inventory-Service"       && write_supervisor_program "inventory"         "Inventory-Service"       2
  is_enabled "Subscriptions-Service"   && write_supervisor_program "subscriptions"     "Subscriptions-Service"   2
  is_enabled "Task-Service"            && write_supervisor_program "tasks"             "Task-Service"            2
  is_enabled "Forms-Service"           && write_supervisor_program "forms"             "Forms-Service"           2
  is_enabled "File-Management-Service" && write_supervisor_program "file-management"   "File-Management-Service" 2
  is_enabled "Integration-Service"     && write_supervisor_program "integration"       "Integration-Service"     10 "update-transaction-cache"
  is_enabled "Airtable-Service"        && write_supervisor_program "airtable-service"  "Airtable-Service"        2

  if is_enabled "FrontEnd"; then
    cat >> "$SUPERVISOR_CONF" <<'FRONTEND'

[program:frontend-dev-server]
command=npm run dev
directory=/var/www/html/FrontEnd
autostart=true
autorestart=true
user=root
redirect_stderr=true
stdout_logfile=/var/log/supervisor/frontend-dev.log
FRONTEND
  fi

  ok "  Supervisord conf written: $SUPERVISOR_CONF"
fi

# ── nginx conf files ──────────────────────────────────────────────────────────
NGINX_TEMPLATES_DIR="$SCRIPT_DIR/nginx/templates"
mkdir -p "$NGINX_CONF_DIR"
echo ""
info "  Nginx conf files:"
for template in "${!NGINX_TEMPLATE_MAP[@]}"; do
  svc="${NGINX_TEMPLATE_MAP[$template]}"
  if ! is_enabled "$svc"; then
    warn "    ${template}.conf  →  disabled (${svc})"
    continue
  fi
  src="$NGINX_TEMPLATES_DIR/${template}.conf"
  dst="$NGINX_CONF_DIR/${template}.conf"
  if [[ ! -f "$src" ]]; then
    warn "    ${template}.conf  →  template not found in nginx/templates/"
    continue
  fi
  if [[ -f "$dst" ]] && [[ "$FORCE" == false ]]; then
    ok "    ${template}.conf  →  already exists in conf.d/"
  else
    sed "s/__DOMAIN__/${DOMAIN}/g" "$src" > "$dst"
    ok "    ${template}.conf  →  copied to conf.d/ (domain: ${DOMAIN})"
  fi
done

sep

# ==============================================================================
# Done — summary
# ==============================================================================
printf "\033[1;32m  Installation complete.\033[0m\n\n"
echo "  Next steps:"
echo "    1. Review generated .env files — most values are pre-set, but check:"
echo "       MAIL_*, AWS_*, OPENAI_*, KAFKA_* and any service-specific keys"
echo "    2. Run:  docker compose up --build -d"
echo "    3. In each service container, run:"
echo "       php artisan migrate --force"
echo "       php artisan storage:link"
echo ""
echo "  Auto-configured per service: APP_KEY, APP_URL, APP_ENV, APP_DEBUG,"
echo "  JWT_SECRET, SERVICE_TOKEN, DB (Mongo/MySQL), Redis, Queue, Cache,"
echo "  Reverb (notifications), VITE_ endpoints (frontend)."
echo "  Cross-service tokens and service URLs are fully propagated."
echo ""
