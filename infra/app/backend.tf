# Partial backend configuration. The bucket differs per AWS account and is
# supplied at init time: terraform init -backend-config=<env>.backend.hcl
# The key must stay under backend/ ; the deploy role can reach nothing else.
terraform {
  backend "s3" {}
}
