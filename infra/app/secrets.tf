# ==============================================================================
# SSM Parameter Store: secret containers
# ==============================================================================
# Terraform creates the parameter with a placeholder so the name, type and
# encryption are managed as code. The REAL value is entered once by an operator
# (console or CLI) and never passes through Git, GitHub or Terraform state:
# `value_wo` is write-only and later changes to it are ignored.
#
# SecureString with the AWS-managed aws/ssm key: no customer-managed KMS key and
# no Secrets Manager, so there is no monthly charge.

resource "aws_ssm_parameter" "google_api_key" {
  name             = "${local.ssm_parameter_prefix}/google_api_key"
  description      = "Google AI Studio API key for the Ambrace ${var.environment} backend. Placeholder until an operator sets the real value."
  type             = "SecureString"
  tier             = "Standard"
  key_id           = "alias/aws/ssm"
  value_wo         = "AMBRACE_REPLACE_ME"
  value_wo_version = 1

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      value_wo,
      value_wo_version,
    ]
  }
}

# ------------------------------------------------------------------------------
# Google sign-in credentials: created by an operator, only READ by Terraform
# ------------------------------------------------------------------------------
# One SecureString parameter per environment, holding one JSON value:
#   name:  /ambrace/<env>/google_oauth
#   value: {"client_id":"...apps.googleusercontent.com","client_secret":"..."}
#
# It must exist before the first deployment; the plan stops with a clear error
# if it is missing. Terraform does not create it because Cognito needs the real
# values at the moment the Google provider is created: a placeholder would
# create a broken provider and need a second deployment to repair it.
#
# Unlike the Gemini key, this value IS copied into the Terraform state file,
# because Terraform has to hand it to Cognito. The state lives in the private,
# encrypted state bucket. Cognito offers no way to avoid this.
data "aws_ssm_parameter" "google_oauth" {
  name            = "${local.ssm_parameter_prefix}/google_oauth"
  with_decryption = true
}
