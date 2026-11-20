terraform {
  required_version = ">= 1.11.4, < 2.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 5.81: first release where aws_iam_openid_connect_provider.thumbprint_list
      # is optional.
      version = "~> 5.81"
    }
  }

  # Partial configuration: the bucket differs per AWS account, so it is supplied
  # at init time with `-backend-config=<env>.backend.hcl`.
  #
  # The bucket is created by this very stack, so the FIRST apply in a new account
  # runs on a local backend via backend_override.tf (see README.md, step 3) and
  # the state is migrated into S3 immediately afterwards.
  backend "s3" {}
}
