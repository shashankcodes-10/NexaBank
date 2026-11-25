#!/usr/bin/env bash
# Stores YOUR passwords in AWS Secrets Manager (the secret CONTAINERS were created by Terraform).
# External Secrets Operator then copies them into Kubernetes. Nothing goes into Git or Terraform state.
#
#   ./scripts/set-secrets.sh              # asks for each value (typing is hidden)
#   ./scripts/set-secrets.sh --generate   # random values instead of asking
#   ./scripts/set-secrets.sh --force      # overwrite secrets that already have a value
#
# Non-interactive: export MYSQL_ROOT_PASSWORD, MYSQL_APP_USER, MYSQL_APP_PASSWORD, GRAFANA_ADMIN_PASSWORD.
#
# WARNING: MySQL reads its password only when its data volume is first created. Changing the MySQL
# secret later does NOT change the password inside an existing database, and the app stops
# connecting. Choose once, before the first deploy (or delete the MySQL PVC if you must change it).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

FORCE=0 GENERATE=0
for a in "$@"; do
  case "$a" in
    --force)    FORCE=1 ;;
    --generate) GENERATE=1 ;;
    -h|--help)  sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done

REGION="$(get_region)"
MYSQL_SECRET="${MYSQL_SECRET:-nexabank/mysql}"
GRAFANA_SECRET="${GRAFANA_SECRET:-nexabank/grafana}"

for bin in aws jq; do command -v "$bin" >/dev/null || die "missing: $bin"; done
[ "$GENERATE" -eq 0 ] || command -v openssl >/dev/null || die "missing: openssl"

has_value() { aws secretsmanager get-secret-value --secret-id "$1" --region "$REGION" >/dev/null 2>&1; }
put()       { aws secretsmanager put-secret-value --secret-id "$1" --region "$REGION" --secret-string "$2" >/dev/null; }

# ask <VARNAME> <prompt>: use the env var if set, otherwise prompt twice (hidden) until both match
ask() {
  local var="$1" label="$2" a b
  if [ -n "${!var:-}" ]; then return 0; fi
  [ -t 0 ] || die "$var is not set and there is no terminal to ask on"
  while :; do
    read -r -s -p "  $label: " a; echo
    read -r -s -p "  $label (again): " b; echo
    [ -n "$a" ] || { warn "empty is not allowed"; continue; }
    [ "$a" = "$b" ] && break
    warn "the two entries differ, try again"
  done
  printf -v "$var" '%s' "$a"
}

say "MySQL credentials ($MYSQL_SECRET)"
if has_value "$MYSQL_SECRET" && [ "$FORCE" -eq 0 ]; then
  ok "already set, left alone (use --force to overwrite; read the warning at the top first)"
else
  if [ "$GENERATE" -eq 1 ]; then
    MYSQL_ROOT_PASSWORD="$(openssl rand -hex 24)"
    MYSQL_APP_PASSWORD="$(openssl rand -hex 24)"
    MYSQL_APP_USER="${MYSQL_APP_USER:-nexabank}"
  else
    if [ -z "${MYSQL_APP_USER:-}" ] && [ -t 0 ]; then
      read -r -p "  MySQL app username [nexabank]: " MYSQL_APP_USER
    fi
    MYSQL_APP_USER="${MYSQL_APP_USER:-nexabank}"
    ask MYSQL_ROOT_PASSWORD "MySQL root password"
    ask MYSQL_APP_PASSWORD  "MySQL password for '$MYSQL_APP_USER'"
  fi
  [ "$MYSQL_ROOT_PASSWORD" != "$MYSQL_APP_PASSWORD" ] || warn "root and app passwords are identical: use different ones"
  put "$MYSQL_SECRET" "$(jq -nc --arg r "$MYSQL_ROOT_PASSWORD" --arg u "$MYSQL_APP_USER" --arg p "$MYSQL_APP_PASSWORD" \
      '{root_password:$r, username:$u, password:$p}')"
  ok "stored"
fi

say "Grafana admin login ($GRAFANA_SECRET)"
if has_value "$GRAFANA_SECRET" && [ "$FORCE" -eq 0 ]; then
  ok "already set, left alone"
else
  if [ "$GENERATE" -eq 1 ]; then GRAFANA_ADMIN_PASSWORD="$(openssl rand -hex 16)"; else ask GRAFANA_ADMIN_PASSWORD "Grafana admin password"; fi
  put "$GRAFANA_SECRET" "$(jq -nc --arg p "$GRAFANA_ADMIN_PASSWORD" '{username:"admin", password:$p}')"
  ok "stored (login user: admin)"
fi

echo
echo "Check (prints key names only):"
echo "    aws secretsmanager get-secret-value --secret-id $MYSQL_SECRET --region $REGION --query SecretString --output text | jq 'keys'"
