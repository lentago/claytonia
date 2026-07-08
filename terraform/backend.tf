terraform {
  # Remote state in the shared tfstate bucket — same account and pattern as
  # kalmia/drosera, isolated key. Local runs authenticate as the cpitzi-iac
  # IAM user; CI assumes the claytonia-github-actions-terraform OIDC role
  # (S3 r/w on this key + the lock table only) — see
  # ../.github/workflows/terraform.yml.
  backend "s3" {
    bucket         = "solidago-tfstate-365184644049"
    key            = "claytonia/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "solidago-tfstate-lock"
    encrypt        = true
  }
}
