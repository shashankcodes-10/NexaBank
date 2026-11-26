#!/usr/bin/env bash
# One extension for every YAML file in this repo: .yml
#
# Why it matters: scripts (configure.sh, deploy.sh) and ArgoCD Applications name files explicitly.
# A file called gateway.yaml when the script says gateway.yml is silently skipped (or aborts the
# script halfway), which is how "HTTPS never turned on" happened. This check fails loudly instead.
#
# The only allowed .yaml names are the two Helm itself requires:
#   helm/<chart>/Chart.yaml and helm/<chart>/values.yaml
#
#   ./scripts/check-yml.sh          # check (exit 1 on a stray .yaml)
#   ./scripts/check-yml.sh --fix    # git mv every stray .yaml to .yml, then run the check again
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

list() {
  if git rev-parse --git-dir >/dev/null 2>&1; then git ls-files; else find . -type f | sed 's#^\./##'; fi \
    | grep -E '\.yaml$' | grep -vE '^backend/' | grep -vE '^helm/[^/]+/(Chart|values)\.yaml$' || true
}

BAD="$(list)"
if [ -n "$BAD" ] && [ "${1:-}" = "--fix" ]; then
  while IFS= read -r f; do
    git mv "$f" "${f%.yaml}.yml" 2>/dev/null || mv "$f" "${f%.yaml}.yml"
    echo "renamed $f -> ${f%.yaml}.yml"
  done <<<"$BAD"
  echo "Now update any reference to the old names (grep -rn '\.yaml' scripts gitops DEPLOY.md)."
  BAD="$(list)"
fi

if [ -n "$BAD" ]; then
  printf '\033[1;31m  ✗ These files use .yaml. This repo uses .yml everywhere:\033[0m\n' >&2
  sed 's/^/      /' <<<"$BAD" >&2
  echo "    Fix: ./scripts/check-yml.sh --fix   (then commit)" >&2
  exit 1
fi
printf '\033[1;32m  ✓ all YAML files use .yml\033[0m\n'
