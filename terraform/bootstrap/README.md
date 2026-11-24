# terraform/bootstrap

Creates the S3 bucket that stores the **main** configuration's Terraform state.

## Why a separate folder?

The main config keeps its state in S3, but something has to create that bucket first, and it
cannot be the config whose state lives in it. The answer is one tiny config with **local state**
that tracks exactly one bucket. If you lose that small local state file you can
`terraform import` the bucket again.

## Run

```bash
cd terraform/bootstrap
terraform init
terraform apply                                   # yes

terraform output -raw backend_hcl > ../backend.hcl
cd .. && terraform init -backend-config=backend.hcl
```

## What the bucket has

- Versioning (undo button after a bad destroy)
- SSE-S3 encryption (state contains cluster data)
- All four public-access blocks, ACLs disabled (BucketOwnerEnforced)
- TLS-only bucket policy
- Old state versions expire after 90 days

## Teardown

Last of all, after `terraform destroy` in `../`:

```bash
cd terraform/bootstrap && terraform destroy
```
