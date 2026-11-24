#!/usr/bin/env bash
# Points the repo at YOUR GitHub repo / region / domain in one go (the "fork and rewire" step).
#
#   ./scripts/configure.sh --repo YOUR_USER/NexaBank [--branch main] [--region ap-south-1] \
#                          [--email you@example.com] [--domain nexabank.example.com]
#
# Safe to re-run. Then: git add -A && git commit && git push
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

REPO="" BRANCH="" REGION="" EMAIL="" DOMAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="$2";   shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --email)  EMAIL="$2";  shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[ -n "$REPO$BRANCH$REGION$EMAIL$DOMAIN" ] || die "nothing to do: pass at least one option (see --help)"

# portable in-place sed (GNU and BSD)
sedi() { sed -i.bak -E "$1" "$2" && rm -f "$2.bak"; }

if [ -n "$REPO" ]; then
  [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "--repo must look like USER/NexaBank"
  say "Repo -> https://github.com/$REPO.git"
  for f in gitops/argocd/*.yaml gitops/argocd/platform/*.yaml; do
    sedi "s#(repoURL:[[:space:]]*)https://github\.com/[^[:space:]]+\.git#\1https://github.com/${REPO}.git#" "$f"
  done
  sedi "s#^(repo_url:[[:space:]]*).*#\1https://github.com/${REPO}.git#" ansible/group_vars/nexabank.yml
  ok "repoURL updated in gitops/argocd and ansible"
fi

if [ -n "$BRANCH" ]; then
  say "Branch -> $BRANCH"
  for f in gitops/argocd/*.yaml gitops/argocd/platform/*.yaml; do
    sedi "s#(targetRevision:[[:space:]]*)(main|master|[A-Za-z0-9._/-]+)([[:space:]]*)\$#\1${BRANCH}\3#" "$f"
  done
  # chart versions are quoted ("v1.2.3"); only unquoted targetRevision lines are branches, handled above
  sedi "s#^(repo_branch:[[:space:]]*).*#\1${BRANCH}#" ansible/group_vars/nexabank.yml
  ok "targetRevision updated"
fi

if [ -n "$REGION" ]; then
  say "Region -> $REGION (5 places: tfvars, bootstrap, secret store, ansible, aws cli)"
  sedi "s#^(aws_region[[:space:]]*=[[:space:]]*).*#\1\"${REGION}\"#" terraform/terraform.tfvars
  sedi "s|(region:[[:space:]]*)[a-z0-9-]+([[:space:]]*# configure:region)|\1${REGION}\2|" gitops/external-secrets/cluster-secret-store.yaml
  sedi "s#^(aws_region:[[:space:]]*).*#\1${REGION}#" ansible/group_vars/nexabank.yml
  ok "updated. Also run: aws configure set region ${REGION}; and apply bootstrap with -var=region=${REGION}"
fi

if [ -n "$EMAIL" ]; then
  say "Let's Encrypt email -> $EMAIL"
  sedi "s|(email:[[:space:]]*)[^[:space:]]+([[:space:]]*# configure:email)|\1${EMAIL}\2|" gitops/cert-manager/clusterissuers.yaml
  ok "ClusterIssuers updated"
fi

if [ -n "$DOMAIN" ]; then
  say "Domain -> $DOMAIN (HTTPS on, staging certificate first)"
  # Helm mode
  sedi "s|(hostname:[[:space:]]*)\"[^\"]*\"([[:space:]]*# configure:domain)|\1\"${DOMAIN}\"\2|" gitops/argocd/nexabank-helm.yaml
  sedi "s|(enabled:[[:space:]]*)(true\|false)([[:space:]]*# configure:tls)|\1true\3|" gitops/argocd/nexabank-helm.yaml
  # Raw mode: fill in the HTTPS gateway and point the Application at it
  sedi "s|[A-Za-z0-9.-]+([[:space:]]*# configure:domain)|${DOMAIN}\1|" k8s/gateway-https/gateway.yaml
  sedi "s|(path:[[:space:]]*)k8s/gateway-(http\|https)([[:space:]]*# configure:gateway-path)|\1k8s/gateway-https\3|" gitops/argocd/nexabank-raw.yaml
  ok "both modes updated (nexabank-helm.yaml, nexabank-raw.yaml + k8s/gateway-https)"
  warn "Real email needed for HTTPS: ./scripts/configure.sh --email you@yourdomain.com"
fi

echo
echo "Now commit and push (ArgoCD reads GitHub, not your disk):"
echo "    git add -A && git commit -m 'configure for my environment' && git push"
