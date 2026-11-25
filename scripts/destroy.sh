#!/usr/bin/env bash
# Tears everything down in the order that avoids the usual hang.
#
# Terraform did not create the load balancer or the EBS volumes behind the PVCs, so
# `terraform destroy` alone would stall on the VPC. This script removes them first.
#
#   ./scripts/destroy.sh              # cluster + everything on it
#   ./scripts/destroy.sh --bootstrap  # ... and finally the state bucket too
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

REGION="$(get_region)"
CLUSTER="${CLUSTER:-$(tfvar cluster_name nexabank-eks)}"
WITH_BOOTSTRAP=0; [ "${1:-}" = "--bootstrap" ] && WITH_BOOTSTRAP=1

echo "This DELETES the EKS cluster '$CLUSTER' in $REGION, its volumes (database + models) and the load balancer."
read -r -p "Type the cluster name to continue: " answer
[ "$answer" = "$CLUSTER" ] || die "cancelled"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

say "1/6 Stop ArgoCD managing anything"
kubectl -n argocd delete applications --all --wait=false >/dev/null 2>&1 || true
sleep 10
ok "applications removed (their resources stay until their namespaces go)"

say "2/6 Delete the namespaces: this is what removes the load balancer and the volumes"
# nexabank-ns first: deleting the Gateway makes Envoy Gateway remove the NLB
for ns in nexabank-ns observability cert-manager external-secrets; do
  kubectl delete namespace "$ns" --ignore-not-found --timeout=10m || warn "$ns is slow to delete (finalizers?)"
done

say "3/6 Wait until no load balancer or volume claim is left"
for _ in $(seq 1 30); do
  LB="$(kubectl get svc -A --no-headers 2>/dev/null | grep -c LoadBalancer || true)"
  PVC="$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$LB" = "0" ] && [ "$PVC" = "0" ] && break
  echo "    waiting... load balancers: $LB, PVCs: $PVC"
  sleep 20
done
[ "$LB" = "0" ] && [ "$PVC" = "0" ] || die "LoadBalancer services or PVCs remain: delete them, then re-run"
ok "none left"

say "4/6 Remove Envoy Gateway and detach ArgoCD from Terraform"
helm uninstall eg -n envoy-gateway-system >/dev/null 2>&1 || true
(
  cd terraform
  # create_namespace=true would make destroy block on the argocd namespace, so drop it from state first
  terraform state rm 'helm_release.argocd[0]' >/dev/null 2>&1 || true
  terraform state rm 'kubernetes_storage_class_v1.gp3' >/dev/null 2>&1 || true
)
kubectl delete namespace argocd envoy-gateway-system --ignore-not-found --timeout=5m || true
ok "done"

say "5/6 Check for orphans that would stall the VPC delete"
VPC="$(cd terraform && terraform output -raw vpc_id 2>/dev/null || true)"
if [ -n "$VPC" ]; then
  SG="$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=k8s-elb-*" \
        --query 'SecurityGroups[].GroupId' --output text)"
  CLB="$(aws elb describe-load-balancers --region "$REGION" \
        --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" --output text)"
  NLB="$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerName" --output text)"
  [ -z "$SG$CLB$NLB" ] || die "orphans in the VPC: SG=[$SG] CLB=[$CLB] NLB=[$NLB]. Delete them and re-run."
  ok "no orphans"
fi

say "6/6 terraform destroy (about 15 minutes)"
(cd terraform && terraform destroy -auto-approve)

say "Leftover EBS volumes (PVC volumes survive if something was force-deleted)"
aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size]' --output table || true

if [ "$WITH_BOOTSTRAP" -eq 1 ]; then
  say "State bucket"
  (cd terraform/bootstrap && terraform destroy -auto-approve -var="region=$REGION")
fi

say "Done. Remember: delete the DNS CNAME for your domain (a CNAME to a released AWS name can be taken over)."
echo "The EC2 machine you created by hand is separate: terminate it (and its role and security group) when you are done."
