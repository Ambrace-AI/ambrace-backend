# ==============================================================================
# Amazon Cognito: user accounts and sign-in
# ==============================================================================
# One user pool per environment. People sign in either with an email and
# password or with Google. The web app receives an access token from Cognito
# and sends it to the API, which verifies it (app/core/auth/cognito.py).
#
# Cost: the Lite feature plan is the cheapest one and covers everything used
# here. No MFA text messages, no advanced security add-on, and Cognito's
# built-in email sender (no SES).

locals {
  cognito_domain_host = "${aws_cognito_user_pool_domain.main.domain}.auth.${local.aws_region}.amazoncognito.com"
}

resource "aws_cognito_user_pool" "main" {
  name           = "${local.name_prefix}-users"
  user_pool_tier = "LITE"

  # The email address is the sign-in name, and must be confirmed with a code
  # before a password account can be used.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  # Cognito's own sender: free, limited to a small number of emails per day.
  # Enough for the MVP; switch to SES before a large launch.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  mfa_configuration = "OFF"

  # Deleting the pool deletes every user account. Blocked in AWS and in
  # Terraform.
  deletion_protection = "ACTIVE"

  lifecycle {
    prevent_destroy = true
  }
}

# The address Cognito's sign-in endpoints live on:
#   https://<prefix>.auth.ap-south-1.amazoncognito.com
# Google is configured with this address, so changing the prefix means updating
# the Google OAuth client too.
resource "aws_cognito_user_pool_domain" "main" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.main.id

  # 1 = the classic hosted pages, the only version the Lite plan supports.
  managed_login_version = 1
}

resource "aws_cognito_identity_provider" "google" {
  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    # Entered by an operator in SSM and checked there (secrets.tf).
    client_id        = local.google_oauth.client_id
    client_secret    = local.google_oauth.client_secret
    authorize_scopes = "openid email profile"

    # Cognito fills these in for a Google provider. Declaring the same values
    # keeps every later plan free of a phantom difference.
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  # Google field on the right, Cognito user attribute on the left.
  attribute_mapping = {
    username       = "sub"
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    picture        = "picture"
  }
}

# The web app. A browser cannot keep a secret, so this client has none and uses
# the authorization-code flow with PKCE.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name_prefix}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  supported_identity_providers = [
    "COGNITO",
    aws_cognito_identity_provider.google.provider_name,
  ]

  callback_urls = var.auth_callback_urls
  logout_urls   = var.auth_logout_urls

  # Email and password sign-in from the app's own form (the password itself is
  # never sent, SRP proves knowledge of it), plus token refresh.
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # Do not reveal whether an email address has an account.
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}
