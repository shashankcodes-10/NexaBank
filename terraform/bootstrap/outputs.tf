output "bucket_name" {
  description = "S3 bucket that holds the main config's state"
  value       = aws_s3_bucket.state.id
}

output "backend_hcl" {
  description = "Ready-to-use backend config: terraform output -raw backend_hcl > ../backend.hcl"

  value = <<-EOT
    bucket = "${aws_s3_bucket.state.id}"
    key    = "nexabank/terraform.tfstate"
    region = "${var.region}"

    encrypt = true

    # S3-native state locking (Terraform >= 1.11). Replaces the old DynamoDB lock table.
    use_lockfile = true
  EOT
}
