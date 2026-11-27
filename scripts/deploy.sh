#!/usr/bin/env bash
# One command for everything after `terraform apply`:
#   preflight -> Envoy Gateway -> platform (ESO, cert-manager, observability) -> NexaBank
# Safe to re-run: every step is idempotent. Does NOT do HTTPS/DNS (see DEPLOY.md section 10).
#
#   ./scripts/deploy.sh                 # app from plain manifests in k8s/  (default)
#   ./scripts/deploy.sh --mode helm     # app from the Helm chart in helm/nexabank
# (or MODE=helm ./scripts/deploy.sh). Both deploy the same thing; see DEPLOY.md "Helm or plain manifests".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

MODE="${MODE:-raw}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$MODE" in raw|helm) ;; *) die "--mode must be raw or helm" ;; esac
APP_FILE="gitops/argocd/nexabank-$MODE.yml"

REGION="$(get_region)"
CLUSTER="${CLUSTER:-$(tfvar cluster_name nexabank-eks)}"
EG_VERSION="${EG_VERSION:-v1.10.0}"
MYSQL_SECRET="${MYSQL_SECRET:-nexabank/mysql}"
GRAFANA_SECRET="${GRAFANA_SECRET:-nexabank/grafana}"

# --- 0. Preflight: the same checks DEPLOY.md calls the HARD GATE -------------------------
say "Preflight (app mode: $MODE)"
[ -f "$APP_FILE" ] || die "missing $APP_FILE"

for bin in kubectl helm aws git; do
  command -v "$bin" >/dev/null || die "missing: $bin (run the Ansible playbooks first)"
done

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
ok "kubeconfig -> $(kubectl config current-context)"

kubectl get nodes >/dev/null || die "cannot reach the cluster. Run kubectl from the same identity that ran terraform apply (the EC2 machine)."
ok "$(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes reachable"

kubectl -n argocd get deploy argocd-server >/dev/null 2>&1 \
  || die "ArgoCD is not installed. Did terraform apply finish? (enable_argocd must be true)"
ok "ArgoCD is installed"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 \
  || die "Branch '$BRANCH' is not on origin. ArgoCD can only sync what it can fetch: git push -u origin $BRANCH"
if [ -n "$(git log "origin/$BRANCH..$BRANCH" --oneline 2>/dev/null)" ]; then
  warn "local commits not yet pushed: ArgoCD will deploy the REMOTE state"
fi
ok "branch '$BRANCH' is on origin"

ORIGIN="$(normalize_repo "$(git remote get-url origin)")"
BAD=0
while IFS= read -r url; do
  [ "$(normalize_repo "$url")" = "$ORIGIN" ] || { warn "repoURL $url differs from origin ($ORIGIN)"; BAD=1; }
done < <(grep -rhoE 'repoURL:[[:space:]]*https://github\.com/[^[:space:]]+' gitops/argocd | awk '{print $2}' | sort -u)
[ "$BAD" -eq 0 ] || die "gitops/argocd still points at another repo. Run: ./scripts/configure.sh --repo YOUR_USER/NexaBank, then commit and push."
ok "every repoURL matches origin ($ORIGIN)"

REV_BAD="$(grep -rhE '^[[:space:]]+targetRevision:[[:space:]]*[A-Za-z]' gitops/argocd | grep -vc "targetRevision: $BRANCH\$" || true)"
[ "${REV_BAD:-0}" -eq 0 ] || die "some targetRevision values are not '$BRANCH'. Run: ./scripts/configure.sh --branch $BRANCH, commit and push."
ok "every targetRevision is '$BRANCH'"

for s in "$MYSQL_SECRET" "$GRAFANA_SECRET"; do
  aws secretsmanager get-secret-value --secret-id "$s" --region "$REGION" >/dev/null 2>&1 \
    || die "Secrets Manager secret '$s' has no value yet. Run: ./scripts/set-secrets.sh"
done
ok "secrets have values"

# --- 1. Envoy Gateway -------------------------------------------------------------------
say "Envoy Gateway ($EG_VERSION)"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$EG_VERSION" \
  -n envoy-gateway-system --create-namespace \
  --wait --timeout 10m >/dev/null
ok "controller ready (also installed the Gateway API CRDs)"

kubectl apply -f gitops/gateway/gatewayclass.yml >/dev/null
ok "GatewayClass 'envoy' applied (AWS NLB)"

# --- 2. Platform (app-of-apps) ----------------------------------------------------------
say "Platform: External Secrets, cert-manager, Prometheus, Grafana, Loki, Tempo, Promtail, OTel"
kubectl apply -f gitops/argocd/platform.yml >/dev/null
ok "app-of-apps applied: ArgoCD is now creating its children in sync-wave order"

say "Waiting for External Secrets Operator"
if wait_for external-secrets deploy/external-secrets 900 &&
   kubectl -n external-secrets rollout status deploy/external-secrets --timeout=8m >/dev/null 2>&1; then
  ok "ESO ready"
else
  warn "not ready: kubectl -n argocd get app external-secrets"
fi

say "ClusterSecretStore (region $REGION, taken from Terraform settings, not from Git)"
sed "s|__REGION__|${REGION}|" scripts/templates/cluster-secret-store.yml | kubectl apply -f - >/dev/null \
  || die "could not apply the ClusterSecretStore. Is External Secrets installed? kubectl -n argocd get app external-secrets"
ok "ClusterSecretStore applied for $REGION"

say "Waiting for the ClusterSecretStore (proves region + Pod Identity + IAM policy in one check)"
ready=""
for _ in $(seq 1 60); do
  ready="$(kubectl get clustersecretstore aws-secrets-manager \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$ready" = "True" ] && break
  sleep 10
done
if [ "$ready" = "True" ]; then
  ok "ClusterSecretStore is Valid"
else
  warn "ClusterSecretStore is not Valid: check aws_region in terraform/terraform.tfvars and"
  warn "  kubectl -n external-secrets logs deploy/external-secrets --tail=50"
fi

say "Waiting for cert-manager"
if wait_for cert-manager deploy/cert-manager 900 &&
   kubectl -n cert-manager rollout status deploy/cert-manager --timeout=8m >/dev/null 2>&1; then
  ok "cert-manager ready"
  # the chart passes gatewayAPI through --config, so read the ConfigMap rather than the args
  if kubectl -n cert-manager get cm cert-manager -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
       | grep -A1 'gatewayAPI' | grep -q 'enabled: true'; then
    ok "Gateway API support on"
  else
    warn "Gateway API support off: kubectl -n cert-manager rollout restart deploy cert-manager"
  fi
else
  warn "not ready: kubectl -n argocd get app cert-manager"
fi

# --- 3. The application -----------------------------------------------------------------
say "NexaBank ($MODE mode -> namespace 'nexabank-ns')"
kubectl apply -f "$APP_FILE" >/dev/null
ok "nexabank Application applied from $APP_FILE (same name for both modes: switching later is safe)"

# --- 4. Verify --------------------------------------------------------------------------
say "Waiting for the app (MySQL starts first; Ollama downloads its model, which takes a few minutes)"
if wait_for nexabank-ns deploy/nexabank 900 &&
   kubectl -n nexabank-ns wait --for=condition=available --timeout=15m deploy/nexabank >/dev/null 2>&1; then
  ok "nexabank is available"
else
  warn "app not ready yet: see the PVC / secret checks below"
fi

say "Status"
echo "--- ArgoCD applications ---"
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null || true
echo
echo "--- PersistentVolumeClaims (all must be Bound, not Pending) ---"
kubectl get pvc -A 2>/dev/null || true
echo
echo "--- keys of the Secret ESO built from AWS ---"
kubectl -n nexabank-ns get secret nexabank-secret -o jsonpath='{.data}' 2>/dev/null \
  | tr ',' '\n' | cut -d'"' -f2 | sed 's/^/    /' || true
echo
echo "--- pods ---"
kubectl get pods -A 2>/dev/null | grep -E 'NAMESPACE|nexabank-ns|observability' | head -30 || true

say "Public URL"
ADDR=""
for _ in $(seq 1 30); do
  ADDR="$(kubectl -n nexabank-ns get gateway nexabank-gateway \
          -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  [ -n "$ADDR" ] && break
  sleep 10
done

if [ -n "$ADDR" ]; then
  ok "http://$ADDR   (the NLB can take 2-3 more minutes before it answers)"
  echo
  echo "    ArgoCD : kubectl -n argocd port-forward svc/argocd-server 8080:80   -> http://localhost:8080"
  echo "    Grafana: kubectl -n observability port-forward svc/grafana 3000:80  -> http://localhost:3000"
else
  warn "Gateway has no address yet: kubectl -n nexabank-ns get gateway nexabank-gateway"
fi

say "Done. HTTPS: DEPLOY.md section 10. Tear down with ./scripts/destroy.sh (namespaces BEFORE terraform destroy)."
