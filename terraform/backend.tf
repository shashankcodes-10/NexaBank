terraform {
  # Partial config on purpose: bucket names are globally unique, so the rest comes
  # from backend.hcl at init time (written by terraform/bootstrap, see DEPLOY.md).
  backend "s3" {}
}
