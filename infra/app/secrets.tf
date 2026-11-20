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
# Google sign-in credentials
# ------------------------------------------------------------------------------
# One SecureString parameter holding one JSON value:
#   {"client_id":"...apps.googleusercontent.com","client_secret":"..."}
#
# Same pattern as the Gemini key: Terraform creates it with a placeholder, an
# operator pastes the real JSON, and later Terraform runs never overwrite it.
#
# One difference: Terraform reads this value back (the data source below) to
# configure Google in Cognito. So after changing the value, run the deployment
# again to pass it on to Cognito. And the value IS copied into the Terraform
# state file, which lives in the private, encrypted state bucket; Cognito
# offers no way to avoid this.
resource "aws_ssm_parameter" "google_oauth" {
  name        = "${local.ssm_parameter_prefix}/google_oauth"
  description = "Google OAuth client id and secret (JSON) for Ambrace ${var.environment} sign-in. Placeholder until an operator sets the real value."
  type        = "SecureString"
  tier        = "Standard"
  key_id      = "alias/aws/ssm"
  value_wo = jsonencode({
    client_id     = local.google_oauth_placeholder_client_id
    client_secret = "AMBRACE_REPLACE_ME"
  })
  value_wo_version = 1

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      value_wo,
      value_wo_version,
    ]
  }
}

# Reads whatever the parameter currently holds: the placeholder at first, the
# real credentials once an operator has entered them.
data "aws_ssm_parameter" "google_oauth" {
  name            = aws_ssm_parameter.google_oauth.name
  with_decryption = true

  lifecycle {
    # Stops the deployment before Cognito is touched if the value was pasted
    # wrongly: not JSON, a field missing, the two values swapped, or an empty
    # secret.
    postcondition {
      condition = try(
        endswith(jsondecode(self.value).client_id, ".apps.googleusercontent.com") && length(jsondecode(self.value).client_secret) > 0,
        false
      )
      error_message = "The google_oauth SSM parameter must be JSON of the form {\"client_id\":\"<id>.apps.googleusercontent.com\",\"client_secret\":\"<secret>\"}."
    }
  }
}

locals {
  # Shaped like a real Google client id so the placeholder passes the check
  # above and the first deployment can create everything.
  google_oauth_placeholder_client_id = "replace-me.apps.googleusercontent.com"

  google_oauth = jsondecode(data.aws_ssm_parameter.google_oauth.value)
}
