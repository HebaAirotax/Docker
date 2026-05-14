#!/usr/bin/env bash
# ==============================================================================
# regen-keys.sh — Rotate all service credentials in-place
#
# Rotates:
#   • MySQL root + user passwords (live ALTER USER inside running container)
#   • MongoDB root password       (live changeUserPassword inside running container)
#   • APP_KEY per Laravel service
#   • Shared JWT_SECRET
#   • SERVICE_TOKEN per service + full cross-service propagation
#
# DB passwords are changed LIVE inside the running containers first.
# .env files are only updated after the live changes succeed.
# If either DB step fails the script exits immediately — old credentials stay
# intact and all containers keep running.
#
# Usage:
#   ./regen-keys.sh
#   make regen-keys
#
# Run from:  Local Docker/
# ==============================================================================

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_ROOT="$(realpath "$SCRIPT_DIR/../laravel")"
DOCKER_ENV="$SCRIPT_DIR/.env"

# ── Disable services here (must stay in sync with install.sh) ────────────────
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

# ── Per-service DB type ───────────────────────────────────────────────────────
declare -A SVC_DB_TYPE
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

gen_app_key() {
  printf 'base64:%s' "$(openssl rand -base64 32)"
}

# Read a single value from an .env file  (read_env <file> <key>)
read_env() {
  grep "^${2}=" "$1" 2>/dev/null | cut -d= -f2-
}

# ── Sanity checks ─────────────────────────────────────────────────────────────
if [[ ! -f "$DOCKER_ENV" ]]; then
  err "Docker .env not found at $DOCKER_ENV — run install.sh first"
  exit 1
fi

printf "\033[1;36m  regen-keys — rotating all credentials\033[0m\n"
echo "  Services root : $SERVICES_ROOT"
sep

# ==============================================================================
# STEP 1 — Read OLD credentials from Docker .env
# ==============================================================================
info "Step 1/6  Reading current credentials from Docker .env"

OLD_MYSQL_ROOT_PASS="$(read_env "$DOCKER_ENV" "MYSQL_ROOT_PASSWORD")"
OLD_MYSQL_USER="$(read_env "$DOCKER_ENV" "MYSQL_USER")"
OLD_MYSQL_PASS="$(read_env "$DOCKER_ENV" "MYSQL_PASSWORD")"
OLD_MONGO_USER="$(read_env "$DOCKER_ENV" "MONGO_INITDB_ROOT_USERNAME")"
OLD_MONGO_PASS="$(read_env "$DOCKER_ENV" "MONGO_INITDB_ROOT_PASSWORD")"

if [[ -z "$OLD_MYSQL_ROOT_PASS" || -z "$OLD_MYSQL_USER" || -z "$OLD_MYSQL_PASS" ]]; then
  err "  MySQL credentials missing from .env (MYSQL_ROOT_PASSWORD / MYSQL_USER / MYSQL_PASSWORD)"
  exit 1
fi
if [[ -z "$OLD_MONGO_USER" || -z "$OLD_MONGO_PASS" ]]; then
  err "  MongoDB credentials missing from .env (MONGO_INITDB_ROOT_USERNAME / MONGO_INITDB_ROOT_PASSWORD)"
  exit 1
fi

ok "  Old credentials loaded"
sep

# ==============================================================================
# STEP 2 — Generate new credentials
# ==============================================================================
info "Step 2/6  Generating new DB credentials"

NEW_MYSQL_ROOT_PASS="$(openssl rand -hex 20)"
NEW_MYSQL_USER_PASS="$(openssl rand -hex 20)"
NEW_MONGO_ROOT_PASS="$(openssl rand -hex 20)"

ok "  New credentials generated (not yet written)"
sep

# ==============================================================================
# STEP 3 — Apply new passwords inside the running containers
# ==============================================================================
info "Step 3/6  Applying new passwords inside running containers"

# ── MySQL ──────────────────────────────────────────────────────────────────────
if ! docker inspect --format '{{.State.Running}}' mysql 2>/dev/null | grep -q "true"; then
  err "  mysql container is not running — start it with 'docker-compose up -d mysql' first"
  exit 1
fi

info "  MySQL → changing root and user passwords..."
if docker exec mysql mysql \
    -uroot \
    -p"${OLD_MYSQL_ROOT_PASS}" \
    -e "ALTER USER 'root'@'%' IDENTIFIED BY '${NEW_MYSQL_ROOT_PASS}';
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_MYSQL_ROOT_PASS}';
        ALTER USER '${OLD_MYSQL_USER}'@'%' IDENTIFIED BY '${NEW_MYSQL_USER_PASS}';
        FLUSH PRIVILEGES;" 2>&1; then
  ok "  MySQL passwords changed successfully"
else
  err "  MySQL ALTER USER failed — old credentials are still valid, .env was NOT modified"
  exit 1
fi

# ── MongoDB ───────────────────────────────────────────────────────────────────
if ! docker inspect --format '{{.State.Running}}' mongodb 2>/dev/null | grep -q "true"; then
  err "  mongodb container is not running — start it with 'docker-compose up -d mongodb' first"
  exit 1
fi

info "  MongoDB → changing root password..."
if docker exec mongodb mongosh \
    --quiet \
    -u "${OLD_MONGO_USER}" \
    -p "${OLD_MONGO_PASS}" \
    --authenticationDatabase admin \
    --eval "db.getSiblingDB('admin').changeUserPassword('${OLD_MONGO_USER}', '${NEW_MONGO_ROOT_PASS}')" 2>&1; then
  ok "  MongoDB password changed successfully"
else
  err "  MongoDB changeUserPassword failed — old credentials are still valid, .env was NOT modified"
  exit 1
fi

sep

# ==============================================================================
# STEP 4 — Write new DB credentials to .env files
# ==============================================================================
info "Step 4/6  Writing new credentials to .env files"

# Docker .env
set_env "$DOCKER_ENV" "MYSQL_ROOT_PASSWORD"          "$NEW_MYSQL_ROOT_PASS"
set_env "$DOCKER_ENV" "MYSQL_PASSWORD"               "$NEW_MYSQL_USER_PASS"
set_env "$DOCKER_ENV" "MONGO_INITDB_ROOT_PASSWORD"   "$NEW_MONGO_ROOT_PASS"
ok "  Docker .env updated"

# Per-service .env files
for svc in "${SERVICES[@]}"; do
  is_enabled "$svc" || continue
  [[ "$svc" == "FrontEnd" ]] && continue
  [[ ! -d "$SERVICES_ROOT/$svc" ]] && { warn "  $svc  →  directory not found, skipping"; continue; }
  env_file="$SERVICES_ROOT/$svc/.env"
  [[ ! -f "$env_file" ]] && { warn "  $svc  →  .env not found, skipping"; continue; }

  db_type="${SVC_DB_TYPE[$svc]:-mongo}"

  if [[ "$db_type" == "mongo" ]]; then
    set_env "$env_file" "DB_PASSWORD" "$NEW_MONGO_ROOT_PASS"
    # Also update secondary MySQL credentials if present in this service's .env
    if grep -q "^MYSQL_DB_PASSWORD=" "$env_file" 2>/dev/null; then
      set_env "$env_file" "MYSQL_DB_PASSWORD" "$NEW_MYSQL_USER_PASS"
    fi
  else
    # mysql primary (Integration-Service)
    set_env "$env_file" "DB_PASSWORD" "$NEW_MYSQL_USER_PASS"
  fi

  ok "  $svc  →  DB_PASSWORD updated"
done

sep

# ==============================================================================
# STEP 5 — Rotate app-level secrets
# ==============================================================================
info "Step 5/6  Rotating APP_KEY, JWT_SECRET, and SERVICE_TOKENs"

# ── APP_KEY ───────────────────────────────────────────────────────────────────
echo ""
info "  APP_KEY"
for svc in "${SERVICES[@]}"; do
  is_enabled "$svc" || continue
  [[ "$svc" == "FrontEnd" ]] && continue
  [[ ! -d "$SERVICES_ROOT/$svc" ]] && { warn "    $svc  →  directory not found, skipping"; continue; }
  env_file="$SERVICES_ROOT/$svc/.env"
  [[ ! -f "$env_file" ]] && { warn "    $svc  →  .env not found, skipping"; continue; }
  set_env "$env_file" "APP_KEY" "$(gen_app_key)"
  ok "    $svc  →  APP_KEY rotated"
done

# ── JWT_SECRET ────────────────────────────────────────────────────────────────
echo ""
info "  JWT_SECRET (shared across all services)"
JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 64)"
for svc in "${SERVICES[@]}"; do
  is_enabled "$svc" || continue
  [[ "$svc" == "FrontEnd" ]] && continue
  [[ ! -d "$SERVICES_ROOT/$svc" ]] && { warn "    $svc  →  directory not found, skipping"; continue; }
  env_file="$SERVICES_ROOT/$svc/.env"
  [[ ! -f "$env_file" ]] && { warn "    $svc  →  .env not found, skipping"; continue; }
  set_env "$env_file" "JWT_SECRET" "$JWT_SECRET"
done
ok "    JWT_SECRET written to all enabled backend services"

# ── SERVICE_TOKENs ────────────────────────────────────────────────────────────
echo ""
info "  SERVICE_TOKENs"
declare -A TOKENS
TOKENS["Core-Service"]="$(openssl rand -hex 32)"
TOKENS["Notifications-Service"]="$(openssl rand -hex 32)"
TOKENS["Billing-Service"]="$(openssl rand -hex 32)"
TOKENS["Inventory-Service"]="$(openssl rand -hex 32)"
TOKENS["Subscriptions-Service"]="$(openssl rand -hex 32)"
TOKENS["Task-Service"]="$(openssl rand -hex 32)"
TOKENS["Forms-Service"]="$(openssl rand -hex 32)"
TOKENS["File-Management-Service"]="$(openssl rand -hex 32)"
TOKENS["Integration-Service"]="$(openssl rand -hex 32)"
TOKENS["Airtable-Service"]="$(openssl rand -hex 32)"

# Write each service's own SERVICE_TOKEN
for svc in "${!TOKENS[@]}"; do
  is_enabled "$svc" || continue
  [[ ! -d "$SERVICES_ROOT/$svc" ]] && { warn "    $svc  →  directory not found, skipping"; continue; }
  env_file="$SERVICES_ROOT/$svc/.env"
  [[ ! -f "$env_file" ]] && { warn "    $svc  →  .env not found, skipping"; continue; }
  set_env "$env_file" "SERVICE_TOKEN" "${TOKENS[$svc]}"
  ok "    $svc  →  SERVICE_TOKEN rotated"
done

# ── Cross-service token propagation ───────────────────────────────────────────
echo ""
info "  Cross-service token propagation"

propagate() {
  local key="$1" value="$2"; shift 2
  for target in "$@"; do
    is_enabled "$target" || continue
    env_file="$SERVICES_ROOT/$target/.env"
    [[ ! -f "$env_file" ]] && continue
    set_env "$env_file" "$key" "$value"
  done
}

propagate "NOTIFICATION_SERVICE_TOKEN" "${TOKENS[Notifications-Service]}" \
  Core-Service Billing-Service Notifications-Service Inventory-Service \
  Subscriptions-Service Task-Service Forms-Service \
  File-Management-Service Integration-Service Airtable-Service
ok "    NOTIFICATION_SERVICE_TOKEN  →  all enabled backend services"

propagate "CORE_SERVICE_TOKEN" "${TOKENS[Core-Service]}" \
  Integration-Service Subscriptions-Service Task-Service Airtable-Service
ok "    CORE_SERVICE_TOKEN          →  Integration, Subscriptions, Task, Airtable"

propagate "BILLING_SERVICE_TOKEN" "${TOKENS[Billing-Service]}" \
  Integration-Service Task-Service
ok "    BILLING_SERVICE_TOKEN       →  Integration, Task"

propagate "INVENTORY_SERVICE_TOKEN" "${TOKENS[Inventory-Service]}" \
  Integration-Service Task-Service Airtable-Service
ok "    INVENTORY_SERVICE_TOKEN     →  Integration, Task, Airtable"

propagate "INTEGRATION_SERVICE_TOKEN" "${TOKENS[Integration-Service]}" \
  Task-Service
ok "    INTEGRATION_SERVICE_TOKEN   →  Task-Service"

propagate "TASK_SERVICE_TOKEN" "${TOKENS[Task-Service]}" \
  Airtable-Service
ok "    TASK_SERVICE_TOKEN          →  Airtable-Service"

propagate "AIRTABLE_SYNC_SERVICE_TOKEN" "${TOKENS[Airtable-Service]}" \
  Task-Service
ok "    AIRTABLE_SYNC_SERVICE_TOKEN →  Task-Service"

sep

# ==============================================================================
# STEP 6 — Restart Docker services
# ==============================================================================
info "Step 6/6  Restarting Docker services"
cd "$SCRIPT_DIR"
docker-compose down
docker-compose up -d
ok "  All services restarted"

sep
printf "\033[1;32m  Key rotation complete.\033[0m\n\n"
echo "  Review any service-specific secrets that are NOT managed by this script:"
echo "    MAIL_*, AWS_*, OPENAI_*, KAFKA_*, and REVERB_APP_SECRET"
echo ""
