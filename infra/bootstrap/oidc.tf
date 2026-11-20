# ==============================================================================
# GitHub Actions -> AWS trust (no long-lived access keys anywhere)
# ==============================================================================
#
# GitHub signs a short-lived token for every workflow job. AWS verifies it against
# this provider and, if the token's `sub` and `aud` match the trust policy below,
# hands the job temporary credentials for the deploy role.

# thumbprint_list is intentionally omitted: AWS validates GitHub's certificate
# against its own trusted root CAs, so pinning thumbprints only adds a way for
# deployments to break when GitHub rotates certificates.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = [var.github_oidc_audience]

  tags = {
    Name = "github-actions"
  }
}

locals {
  # Exactly one subject may assume the role: a job in this repository that
  # declares this GitHub Environment. Branch pushes, pull requests and forks get
  # a different `sub` and are rejected. No wildcards.
  github_deploy_subject = "${var.github_subject_prefix}:environment:${var.github_environment_name}"

  deploy_role_name = "ambrace-github-deploy-${var.environment}"
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    sid     = "GitHubActionsEnvironmentOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [var.github_oidc_audience]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_deploy_subject]
    }
  }
}

# Named ambrace-github-deploy-<env>, NOT ambrace-<env>-*: the role must sit outside
# the name range it is allowed to manage, so it can never act on itself.
resource "aws_iam_role" "deploy" {
  name                 = local.deploy_role_name
  description          = "Assumed by GitHub Actions (environment ${var.github_environment_name}) to deploy the Ambrace backend to ${var.environment}."
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600

  tags = {
    Name = local.deploy_role_name
  }
}
