# Offline contract tests for the application stack. No AWS credentials needed.
# Requires the Lambda artifact to exist: python scripts/build_lambda.py

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::798299234172:role/mock-runtime"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "798299234172"
    }
  }
  mock_data "aws_region" {
    defaults = {
      name = "ap-south-1"
    }
  }
  mock_data "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:ap-south-1:798299234172:certificate/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  environment          = "dev"
  aws_account_id       = "798299234172"
  cors_allowed_origins = ["https://app-dev.ambrace.in", "http://localhost:3000"]
  custom_domain_name   = "api-dev.ambrace.in"
}

run "dev_sessions" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.sessions.name == "ambrace-dev-sessions"
    error_message = "DEV must use its own table."
  }
  assert {
    condition     = aws_lambda_function.backend.environment[0].variables.DYNAMODB_TABLE_NAME == "ambrace-dev-sessions"
    error_message = "DEV Lambda must receive the DEV table name."
  }
  assert {
    condition     = aws_dynamodb_table.sessions.hash_key == "pk" && aws_dynamodb_table.sessions.range_key == "sk"
    error_message = "Session table must use composite owner/session keys."
  }
  assert {
    condition     = aws_dynamodb_table.sessions.billing_mode == "PROVISIONED" && aws_dynamodb_table.sessions.read_capacity == 5 && aws_dynamodb_table.sessions.write_capacity == 5
    error_message = "Prototype capacity must retain the deliberate 5/5 allocation."
  }
  assert {
    condition     = length(aws_dynamodb_table.sessions.global_secondary_index) == 0 && length(aws_dynamodb_table.sessions.local_secondary_index) == 0
    error_message = "Current access patterns need no indexes."
  }
}

run "prod_sessions" {
  command = plan

  variables {
    environment          = "prod"
    aws_account_id       = "074259854866"
    cors_allowed_origins = ["https://app.ambrace.in"]
    custom_domain_name   = "api.ambrace.in"
  }

  assert {
    condition     = aws_dynamodb_table.sessions.name == "ambrace-prod-sessions"
    error_message = "PROD must use its own table."
  }
  assert {
    condition     = aws_lambda_function.backend.environment[0].variables.DYNAMODB_TABLE_NAME == "ambrace-prod-sessions"
    error_message = "PROD Lambda must receive the PROD table name."
  }
  assert {
    condition     = aws_dynamodb_table.sessions.deletion_protection_enabled
    error_message = "PROD table must have deletion protection."
  }
}

run "bootstrap_contract" {
  command = plan

  assert {
    condition     = aws_iam_role.lambda_runtime.permissions_boundary == "arn:aws:iam::798299234172:policy/ambrace-dev-runtime-boundary"
    error_message = "Runtime roles must carry the bootstrap boundary or the deploy role cannot create them."
  }
  assert {
    condition     = startswith(aws_iam_role.lambda_runtime.name, "ambrace-dev-")
    error_message = "Roles must be named ambrace-<env>-* to be within reach of the deploy role."
  }
  assert {
    condition     = aws_ssm_parameter.google_api_key.name == "/ambrace/dev/google_api_key"
    error_message = "Parameters must live under /ambrace/<env>/."
  }
  assert {
    condition     = aws_cloudwatch_log_group.lambda.name == "/aws/lambda/ambrace-dev-backend"
    error_message = "Log group must match the log scope of the deploy role."
  }
}

run "runtime_platform" {
  command = plan

  assert {
    condition     = aws_lambda_function.backend.runtime == "python3.13" && aws_lambda_function.backend.architectures[0] == "arm64"
    error_message = "The artifact is built for Python 3.13 on arm64."
  }
  assert {
    condition     = strcontains(aws_lambda_function.backend.layers[0], "LambdaAdapterLayerArm64")
    error_message = "The Web Adapter layer must match the function architecture."
  }
}

run "browser_origins_are_exact" {
  command = plan

  assert {
    condition     = aws_lambda_function.backend.environment[0].variables.CORS_ORIGINS == "https://app-dev.ambrace.in,http://localhost:3000"
    error_message = "The app must receive exactly the configured origins."
  }
}

run "rejects_wildcard_origin" {
  command = plan

  variables {
    cors_allowed_origins = ["https://*.vercel.app"]
  }

  expect_failures = [var.cors_allowed_origins]
}

run "auth_starts_unconfigured" {
  command = plan

  assert {
    condition     = aws_lambda_function.backend.environment[0].variables.COGNITO_USER_POOL_ID == "" && aws_lambda_function.backend.environment[0].variables.COGNITO_APP_CLIENT_ID == ""
    error_message = "Until a user pool exists the API runs fail-closed with empty identifiers."
  }
}

run "rejects_half_configured_auth" {
  command = plan

  variables {
    cognito_user_pool_id = "ap-south-1_Example"
  }

  expect_failures = [var.cognito_app_client_id]
}
