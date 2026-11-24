variable "region" {
  description = "Region of the state bucket. Keep it equal to aws_region of the main config."
  type        = string
  default     = "ap-south-1"
}

variable "bucket_name" {
  description = "Override the bucket name. null = nexabank-tfstate-<account-id>-<region> (unique per account, nothing to edit in the repo)."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete the bucket while it still holds state. Fine for learning, never for production."
  type        = bool
  default     = true
}
