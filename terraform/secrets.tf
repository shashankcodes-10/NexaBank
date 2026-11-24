# Only the secret CONTAINERS are created here. The values are set by scripts/set-secrets.sh,
# so no password ever enters Terraform state or Git. External Secrets Operator copies them
# into Kubernetes Secrets.
resource "aws_secretsmanager_secret" "mysql" {
  name        = var.mysql_secret_name
  description = "NexaBank MySQL credentials (keys: root_password, username, password)"

  # 0 = delete immediately. The 30-day default blocks re-creating the name after a destroy.
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret" "grafana" {
  name        = var.grafana_secret_name
  description = "Grafana admin login (keys: username, password)"

  recovery_window_in_days = 0

  tags = local.tags
}
