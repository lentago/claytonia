terraform {
  # Remote state in the shared tfstate bucket — same account and pattern as
  # kalmia/drosera, isolated key. Local runs authenticate as the cpitzi-iac
  # IAM user; a claytonia-scoped OIDC role (S3 r/w on this key + the lock
  # table) arrives with the apply-on-merge phase (#51).
  backend "s3" {
    bucket         = "foundry-tfstate-365184644049"
    key            = "claytonia/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "foundry-tfstate-lock"
    encrypt        = true
  }
}
