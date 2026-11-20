# Offline contract tests: no AWS credentials or network calls to AWS are needed.
# Run with: terraform test

mock_provider "aws" {
  # The mock provider cannot render real policy JSON; give resources a valid
  # empty document so plan-time JSON validation passes.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "798299234172"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      name = "ap-south-1"
    }
  }
}

variables {
  environment             = "dev"
  aws_account_id          = "798299234172"
  github_environment_name = "development"
  api_domain_name         = "api-dev.ambrace.in"
}

run "names_follow_the_environment_prefix" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "ambrace-terraform-state-798299234172"
    error_message = "State bucket must be ambrace-terraform-state-<account_id>."
  }

  assert {
    condition     = aws_iam_role.deploy.name == "ambrace-github-deploy-dev"
    error_message = "Deploy role must be named ambrace-github-deploy-<env>."
  }

  assert {
    condition     = !startswith(aws_iam_role.deploy.name, "ambrace-dev-")
    error_message = "Deploy role must sit outside the ambrace-<env>-* range it is allowed to manage."
  }

  assert {
    condition     = aws_iam_policy.runtime_boundary.name == "ambrace-dev-runtime-boundary"
    error_message = "Runtime boundary must be named ambrace-<env>-runtime-boundary."
  }

  assert {
    condition     = output.app_state_key == "backend/terraform.tfstate"
    error_message = "infra/app state key is a contract with the deploy role's S3 policy."
  }
}

run "only_the_github_environment_can_assume_the_role" {
  command = plan

  assert {
    condition     = output.github_deploy_subject == "repo:Ambrace-AI@357749772/ambrace-backend@1462386177:environment:development"
    error_message = "Deploy subject must be the immutable repo prefix plus the GitHub Environment."
  }

  assert {
    condition     = !strcontains(output.github_deploy_subject, "*")
    error_message = "Deploy subject must never contain a wildcard."
  }
}

run "certificate_is_optional" {
  command = plan

  variables {
    api_domain_name = ""
  }

  assert {
    condition     = length(aws_acm_certificate.api) == 0
    error_message = "No certificate should be requested when api_domain_name is empty."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "rejects_wildcard_subject_prefix" {
  command = plan

  variables {
    github_subject_prefix = "repo:Ambrace-AI/*"
  }

  expect_failures = [var.github_subject_prefix]
}
