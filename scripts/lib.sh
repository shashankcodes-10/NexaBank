#!/usr/bin/env bash
# Shared helpers for the scripts in this folder. Sourced, never run directly.

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# tfvar <name>: read a value from terraform/terraform.tfvars (falls back to $2)
tfvar() {
  local v
  v="$(grep -E "^$1[[:space:]]*=" "$ROOT/terraform/terraform.tfvars" 2>/dev/null \
        | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | tr -d ' ')"
  echo "${v:-${2:-}}"
}

# wait_for <namespace> <resource> [seconds]: wait until the object exists
wait_for() {
  local ns="$1" res="$2" limit="${3:-600}" waited=0
  until kubectl -n "$ns" get "$res" >/dev/null 2>&1; do
    [ "$waited" -ge "$limit" ] && return 1
    sleep 10; waited=$((waited + 10))
  done
}

# https://github.com/me/repo.git and git@github.com:me/repo.git -> github.com/me/repo
normalize_repo() {
  sed -E 's#^(https?://|git@)##; s#^github\.com:#github.com/#; s#\.git$##; s#/$##' <<<"$1"
}

# get_region: the region comes from Terraform settings only. No hidden default.
get_region() {
  local r="${REGION:-${TF_VAR_aws_region:-$(tfvar aws_region)}}"
  [ -n "$r" ] || die "no region: set aws_region in terraform/terraform.tfvars (or export TF_VAR_aws_region)"
  echo "$r"
}
