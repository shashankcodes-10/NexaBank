output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "VPC ID (used by the teardown checks)"
  value       = module.vpc.vpc_id
}

output "configure_kubectl" {
  description = "Point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "mysql_secret_name" {
  value = aws_secretsmanager_secret.mysql.name
}

output "grafana_secret_name" {
  value = aws_secretsmanager_secret.grafana.name
}

output "external_secrets_role_arn" {
  description = "IAM role External Secrets Operator assumes through Pod Identity"
  value       = module.external_secrets_pod_identity.iam_role_arn
}

output "next_steps" {
  value = <<-EOT
    1. ./scripts/set-secrets.sh        # puts MySQL + Grafana passwords in Secrets Manager
    2. git push                        # ArgoCD reads Git, not your disk
    3. ./scripts/deploy.sh             # Envoy Gateway + platform + app
  EOT
}

output "aws_region" {
  description = "Region of this deployment (single source of truth: var.aws_region)"
  value       = var.aws_region
}