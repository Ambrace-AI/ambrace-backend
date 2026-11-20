provider "aws" {
  region = var.aws_region

  # Hard stop if the pipeline credentials belong to a different account than
  # the one this var-file targets.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = "Ambrace"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Component   = "Backend"
      Repository  = "ambrace-backend"
    }
  }
}
