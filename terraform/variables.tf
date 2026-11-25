variable "aws_region" {
  description = "AWS region for the cluster and every AWS resource. Single source of truth: scripts read it from terraform.tfvars (or TF_VAR_aws_region); deploy.sh applies the External Secrets store with it."
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name (also the VPC name and the prefix of IAM roles)"
  type        = string
  default     = "nexabank-eks"
}

variable "cluster_version" {
  description = "Kubernetes version. Check what your region supports: aws eks describe-cluster-versions"
  type        = string
  default     = "1.36"
}

variable "node_instance_type" {
  description = "Worker node type. App + observability stack request ~9 GiB, so t3.large (8 GiB) x2 is the minimum that fits."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_count" {
  description = "Desired and minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4
}

variable "node_disk_size" {
  description = "Root volume per node in GiB (Ollama model + images + control planes need more than the 20 GiB default)"
  type        = number
  default     = 30
}

variable "mysql_secret_name" {
  description = "Secrets Manager secret holding the MySQL credentials. helm/nexabank/values.yaml (secrets.mysql) must use the same name."
  type        = string
  default     = "nexabank/mysql"
}

variable "grafana_secret_name" {
  description = "Secrets Manager secret holding the Grafana admin login"
  type        = string
  default     = "nexabank/grafana"
}

variable "enable_argocd" {
  description = "Install ArgoCD from Terraform. Set false to install it by hand."
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (pinned)"
  type        = string
  default     = "10.18.2"
}
