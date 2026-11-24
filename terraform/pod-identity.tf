# EKS Pod Identity (no ServiceAccount annotations, no OIDC trust policy to maintain).

# EBS CSI driver: creates the EBS volumes behind every PVC
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                      = "${local.name}-ebs-csi"
  attach_aws_ebs_csi_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
  }

  tags = local.tags
}

# External Secrets Operator: may read ONLY secrets whose name starts with nexabank/
module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                           = "${local.name}-external-secrets"
  attach_external_secrets_policy = true

  external_secrets_create_permission  = false
  external_secrets_ssm_parameter_arns = []
  external_secrets_secrets_manager_arns = [
    "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:nexabank/*",
  ]

  associations = {
    this = {
      cluster_name = module.eks.cluster_name
      namespace    = "external-secrets"
      # must match the ServiceAccount created by the ESO chart (gitops/argocd/platform/external-secrets.yaml)
      service_account = "external-secrets"
    }
  }

  tags = local.tags
}
