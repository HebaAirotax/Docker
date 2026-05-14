#!/usr/bin/env bash
# ==============================================================================
# change-domain.sh — Update all domain-based URLs and nginx configs
#
# Rewrites:
#   • nginx/conf.d/*.conf   — regenerated from templates/ with new domain/prefix
#   • Per-service .env      — APP_URL, MAIL_FROM_ADDRESS
#   • Cross-service .env    — NOTIFICATION_SERVICE, CORE_SERVICE, FRONTEND_URL
#   • FrontEnd .env         — all VITE_* endpoint URLs
#
# Usage:
#   ./change-domain.sh --domain=example.com
#   ./change-domain.sh --domain=example.com --prefix=v2
#   make change-domain DOMAIN=example.com
#   make change-domain DOMAIN=example.com PREFIX=v2
#
# With --prefix=v2 the URL pattern becomes:
#   https://v2-core.example.com   (instead of https://core.example.com)
#
# Run from:  Local Docker/
# ==============================================================================

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_ROOT="$(realpath "$SCRIPT_DIR/../laravel")"
NGINX_CONF_DIR="$SCRIPT_DIR/nginx/conf.d"
NGINX_TEMPLATES_DIR="$SCRIPT_DIR/nginx/templates"

# ── Disable services here (keep in sync with install.sh) ─────────────────────
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

# ── Per-service subdomain prefix ──────────────────────────────────────────────
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

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf "\033[0;34m[INFO]\033[0m  %s\n" "$*"; }
ok()      { printf "\033[0;32m[ OK ]\033[0m  %s\n" "$*"; }
warn()    { printf "\033[0;33m[WARN]\033[0m  %s\n" "$*"; }
err()     { printf "\033[0;31m[ERR ]\033[0m  %s\n" "$*" >&2; }
sep()     { printf "\033[0;90m%s\033[0m\n" "──────────────────────────────────────────────────"; }

is_enabled() {
  local svc="$1"
  [[ ${#DISABLED_SERVICES[@]} -eq 0 ]] && return 0
  for d in "${DISABLED_SERVICES[@]}"; do
    [[ "$d" == "$svc" ]] && return 1
  done
  return 0
}

set_env() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s' "$key" "$value" >> "$file"
  fi
}

# ── Parse args ────────────────────────────────────────────────────────────────
DOMAIN=""
PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)    DOMAIN="$2"; shift ;;
    --domain=*)  DOMAIN="${1#--domain=}" ;;
    --prefix)    PREFIX="$2"; shift ;;
    --prefix=*)  PREFIX="${1#--prefix=}" ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$DOMAIN" ]]; then
  printf "  Enter new domain (e.g. example.com): "
  read -r DOMAIN
fi

if [[ -z "$DOMAIN" ]]; then
  err "Domain is required. Pass --domain=example.com or enter it at the prompt."
  exit 1
fi

# PREFIX_STR is either empty or "prefix-"  (used to build URLs and nginx server_names)
PREFIX_STR=""
[[ -n "$PREFIX" ]] && PREFIX_STR="${PREFIX}-"

echo ""
printf "\033[1;36m  change-domain\033[0m\n"
echo "  Domain      : $DOMAIN"
echo "  Prefix      : ${PREFIX:-(none)}"
echo "  URL pattern : https://${PREFIX_STR}<subdomain>.${DOMAIN}"
sep

# ==============================================================================
# STEP 1 — Rebuild nginx/conf.d from templates
# ==============================================================================
info "Step 1/4  Rebuilding nginx/conf.d from templates"
mkdir -p "$NGINX_CONF_DIR"

for src in "$NGINX_TEMPLATES_DIR"/*.conf; do
  name="$(basename "$src")"
  dst="$NGINX_CONF_DIR/$name"

  if [[ -n "$PREFIX" ]]; then
    # Prefix each server_name subdomain, then resolve __DOMAIN__
    # e.g.  server_name core.__DOMAIN__  →  server_name v2-core.example.com
    sed "s/server_name \([a-z0-9-]*\)\.__DOMAIN__/server_name ${PREFIX_STR}\1.${DOMAIN}/g; \
         s/__DOMAIN__/${DOMAIN}/g" "$src" > "$dst"
  else
    sed "s/__DOMAIN__/${DOMAIN}/g" "$src" > "$dst"
  fi

  ok "  $name  →  conf.d/"
done

sep

# ==============================================================================
# STEP 2 — Per-service APP_URL and MAIL_FROM_ADDRESS
# ==============================================================================
info "Step 2/4  Updating APP_URL and MAIL_FROM_ADDRESS per service"

for svc in "${SERVICES[@]}"; do
  is_enabled "$svc" || continue
  [[ "$svc" == "FrontEnd" ]] && continue
  [[ ! -d "$SERVICES_ROOT/$svc" ]] && { warn "  $svc  →  directory not found, skipping"; continue; }
  env_file="$SERVICES_ROOT/$svc/.env"
  [[ ! -f "$env_file" ]] && { warn "  $svc  →  .env not found, skipping"; continue; }

  subdomain="${SVC_SUBDOMAIN[$svc]:-}"
  new_url="https://${PREFIX_STR}${subdomain}.${DOMAIN}"

  set_env "$env_file" "APP_URL"           "$new_url"
  set_env "$env_file" "MAIL_FROM_ADDRESS" "noreply@${DOMAIN}"
  ok "  $svc  →  APP_URL=$new_url"
done

sep

# ==============================================================================
# STEP 3 — Cross-service URL keys
# ==============================================================================
info "Step 3/4  Updating cross-service URL keys"

propagate_url() {
  local key="$1" value="$2"; shift 2
  for target in "$@"; do
    is_enabled "$target" || continue
    [[ ! -d "$SERVICES_ROOT/$target" ]] && continue
    local env_file="$SERVICES_ROOT/$target/.env"
    [[ ! -f "$env_file" ]] && continue
    set_env "$env_file" "$key" "$value"
  done
}

NOTIF_URL="https://${PREFIX_STR}notifications.${DOMAIN}"
CORE_URL="https://${PREFIX_STR}core.${DOMAIN}"
PORTAL_URL="https://${PREFIX_STR}portal.${DOMAIN}"

propagate_url "NOTIFICATION_SERVICE" "$NOTIF_URL" \
  Core-Service Billing-Service Inventory-Service Subscriptions-Service \
  Task-Service Forms-Service File-Management-Service Integration-Service Airtable-Service
ok "  NOTIFICATION_SERVICE  →  $NOTIF_URL"

propagate_url "CORE_SERVICE" "$CORE_URL" \
  Integration-Service Subscriptions-Service Task-Service Airtable-Service
ok "  CORE_SERVICE          →  $CORE_URL"

if is_enabled "Notifications-Service"; then
  notif_env="$SERVICES_ROOT/Notifications-Service/.env"
  if [[ -f "$notif_env" ]]; then
    set_env "$notif_env" "FRONTEND_URL" "$PORTAL_URL"
    ok "  FRONTEND_URL          →  $PORTAL_URL"
  fi
fi

sep

# ==============================================================================
# STEP 4 — FrontEnd VITE_ endpoint URLs
# ==============================================================================
info "Step 4/4  Updating FrontEnd VITE_ endpoints"

if is_enabled "FrontEnd"; then
  if [[ ! -d "$SERVICES_ROOT/FrontEnd" ]]; then
    warn "  FrontEnd  →  directory not found, skipping"
  else
    fe_env="$SERVICES_ROOT/FrontEnd/.env"
    if [[ ! -f "$fe_env" ]]; then
      warn "  FrontEnd  →  .env not found, skipping"
    else
      set_env "$fe_env" "VITE_API_BASE_URL"         "https://${PREFIX_STR}core.${DOMAIN}"
      set_env "$fe_env" "VITE_BASE_SERVER"          "https://${PREFIX_STR}core.${DOMAIN}"
      set_env "$fe_env" "VITE_NOTIFICATION_SERVER"  "https://${PREFIX_STR}notifications.${DOMAIN}"
      set_env "$fe_env" "VITE_AIRTABLE_SERVER"      "https://${PREFIX_STR}airtable.${DOMAIN}"
      set_env "$fe_env" "VITE_INVENTORY_SERVER"     "https://${PREFIX_STR}inventory.${DOMAIN}"
      set_env "$fe_env" "VITE_BILLING_SERVER"       "https://${PREFIX_STR}billing.${DOMAIN}"
      set_env "$fe_env" "VITE_INTEGRATION_SERVER"   "https://${PREFIX_STR}integration.${DOMAIN}"
      set_env "$fe_env" "VITE_SUBSCRIPTIONS_SERVER" "https://${PREFIX_STR}subscriptions.${DOMAIN}"
      set_env "$fe_env" "VITE_TASK_SERVER"          "https://${PREFIX_STR}tasks.${DOMAIN}"
      set_env "$fe_env" "VITE_FORMS_SERVER"         "https://${PREFIX_STR}forms.${DOMAIN}"
      set_env "$fe_env" "VITE_PUSHER_HOST"          "${PREFIX_STR}notifications.${DOMAIN}"
      ok "  FrontEnd  →  all VITE_ endpoints updated"
    fi
  fi
fi

sep
printf "\033[1;32m  Domain change complete.\033[0m\n\n"
echo "  To apply nginx changes without a full restart:"
echo "    docker-compose exec nginx nginx -s reload"
echo "  For a full restart:"
echo "    make restart"
echo ""
