#!/usr/bin/env bash
# Tears everything down in the order that avoids the usual hang.
#
# Two separate layers exist, and this script can remove either or both:
#   main      the cluster, VPC, ArgoCD, secrets   (terraform/, state lives in the S3 bucket)
#   bootstrap the S3 bucket that holds main's state (terraform/bootstrap/, local state)
#
#   ./scripts/destroy.sh                  # main only. The state bucket stays.
#   ./scripts/destroy.sh --bootstrap      # main, then the state bucket. Works when the cluster is already gone.
#   ./scripts/destroy.sh --bootstrap-only # just the state bucket (main already destroyed)
#
# The bucket is only deleted when main's state is empty, so you cannot lose track of live resources.
# The cluster being absent is fine: the Kubernetes cleanup is skipped and Terraform still runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

DO_MAIN=1 DO_BOOT=0
case "${1:-}" in
  "")               ;;
  --bootstrap)      DO_BOOT=1 ;;
  --bootstrap-only) DO_MAIN=0; DO_BOOT=1 ;;
  -h|--help)        sed -n '2,13p' "$0"; exit 0 ;;
  *)                die "unknown option: $1 (see --help)" ;;
esac

REGION="$(get_region)"
CLUSTER="${CLUSTER:-$(tfvar cluster_name nexabank-eks)}"

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1
}

# main_state_count: how many resources the main Terraform state still tracks (0 if no state / no bucket)
main_state_count() {
  [ -f terraform/backend.hcl ] || { echo 0; return; }
  (cd terraform && terraform init -input=false -reconfigure -backend-config=backend.hcl >/dev/null 2>&1 \
     && terraform state list 2>/dev/null | wc -l | tr -d ' ') || echo 0
}

if [ "$DO_MAIN" -eq 1 ]; then
  echo "This DELETES the EKS cluster '$CLUSTER' in $REGION (if it exists), its volumes (database + models) and the load balancer."
  if [ "$DO_BOOT" -eq 1 ]; then echo "Afterwards it also DELETES the Terraform state bucket."; fi
else
  echo "This DELETES the Terraform state bucket in $REGION (the main infrastructure must already be gone)."
fi
read -r -p "Type the cluster name to continue: " answer
[ "$answer" = "$CLUSTER" ] || die "cancelled"

if [ "$DO_MAIN" -eq 1 ]; then
  if cluster_exists; then
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
    LB=1 PVC=1
    for _ in $(seq 1 30); do
      LB="$(kubectl get svc -A --no-headers 2>/dev/null | grep -c LoadBalancer || true)"
      PVC="$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
      [ "$LB" = "0" ] && [ "$PVC" = "0" ] && break
      echo "    waiting... load balancers: $LB, PVCs: $PVC"
      sleep 20
    done
    [ "$LB" = "0" ] && [ "$PVC" = "0" ] || die "LoadBalancer services or PVCs remain: delete them, then re-run"
    ok "none left"

    say "4/6 Remove Envoy Gateway"
    helm uninstall eg -n envoy-gateway-system >/dev/null 2>&1 || true
    kubectl delete namespace argocd envoy-gateway-system --ignore-not-found --timeout=5m || true
    ok "done"
  else
    warn "cluster '$CLUSTER' not found in $REGION: skipping the Kubernetes cleanup (steps 1-4)"
  fi

  say "5/6 Check for orphans that would stall the VPC delete"
  if [ -f terraform/backend.hcl ] && (cd terraform && terraform init -input=false -reconfigure -backend-config=backend.hcl >/dev/null 2>&1); then
    # Terraform must not try to talk to a cluster that is going (or gone): forget the in-cluster resources
    (
      cd terraform
      terraform state rm 'helm_release.argocd[0]' >/dev/null 2>&1 || true
      terraform state rm 'kubernetes_storage_class_v1.gp3' >/dev/null 2>&1 || true
    )
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
    else
      ok "no VPC in state"
    fi

    say "6/6 terraform destroy (about 15 minutes; instant when the state is already empty)"
    (cd terraform && terraform destroy -auto-approve)
  else
    warn "no terraform/backend.hcl or the state bucket is unreachable: nothing to destroy in the main layer"
  fi

  say "Leftover EBS volumes (PVC volumes survive if something was force-deleted)"
  aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size]' --output table || true
fi

if [ "$DO_BOOT" -eq 1 ]; then
  say "State bucket (terraform/bootstrap)"
  LEFT="$(main_state_count)"
  [ "$LEFT" = "0" ] || die "main state still tracks $LEFT resources. Deleting the bucket would orphan them. Run ./scripts/destroy.sh first."

  if [ ! -f terraform/bootstrap/terraform.tfstate ]; then
    warn "terraform/bootstrap/terraform.tfstate is missing (the bootstrap state is local to the machine that created the bucket)."
    BUCKET="nexabank-tfstate-$(aws sts get-caller-identity --query Account --output text)-${REGION}"
    echo "    Re-adopt the bucket, then re-run this script:"
    echo "      cd terraform/bootstrap && terraform init && terraform import -var=region=$REGION aws_s3_bucket.state $BUCKET"
    die "cannot destroy the bucket without its state"
  fi
  (
    cd terraform/bootstrap
    terraform init -input=false
    terraform destroy -auto-approve -var="region=$REGION"
  )
  rm -f terraform/backend.hcl
  ok "state bucket deleted"
fi

say "Done. Remember: delete the DNS CNAME for your domain (a CNAME to a released AWS name can be taken over)."
echo "The EC2 machine you created by hand is separate: terminate it (and its role and security group) when you are done."
