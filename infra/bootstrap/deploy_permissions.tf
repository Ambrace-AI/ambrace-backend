# ==============================================================================
# What the GitHub deploy role may do
# ==============================================================================
#
# This is the contract for infra/app: that stack can manage exactly these
# resource types, and only ones named ambrace-<env>-*. Where AWS generates the
# identifier (API Gateway APIs, Cognito user pools) name scoping is impossible;
# the boundary there is the account itself, which holds a single environment.

# ------------------------------------------------------------------------------
# Terraform state
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_state" {
  statement {
    sid       = "ListAppStatePrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        local.app_state_prefix,
        "${local.app_state_prefix}/*",
      ]
    }
  }

  # Covers the state object and its S3-native lock file (<key>.tflock). The
  # bootstrap state under bootstrap/ is deliberately out of reach.
  statement {
    sid    = "ReadWriteAppState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.state.arn}/${local.app_state_prefix}/*"]
  }

  # Releasing a lock deletes the lock file. Terraform never deletes the state
  # object itself, so the pipeline is not allowed to either.
  statement {
    sid       = "ReleaseAppStateLock"
    effect    = "Allow"
    actions   = ["s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.app_state_prefix}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "deploy_state" {
  name   = "terraform-state"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_state.json
}

# ------------------------------------------------------------------------------
# Compute, API and data
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_app" {
  statement {
    sid    = "Lambda"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:DeleteFunction",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:GetFunctionEventInvokeConfig",
      "lambda:ListVersionsByFunction",
      "lambda:PublishVersion",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:ListTags",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:GetPolicy",
    ]
    resources = [
      "arn:aws:lambda:${local.aws_region}:${local.account_id}:function:${local.name_prefix}-*",
    ]
  }

  # AWS-published Lambda Web Adapter layer (arm64) that fronts FastAPI.
  statement {
    sid       = "LambdaWebAdapterLayer"
    effect    = "Allow"
    actions   = ["lambda:GetLayerVersion"]
    resources = ["arn:aws:lambda:${local.aws_region}:753240598075:layer:LambdaAdapterLayerArm64:*"]
  }

  statement {
    sid    = "ApiGatewayHttpApi"
    effect = "Allow"
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
      # Creating a tagged stage is authorized as TagResource on the stage
      # collection, not through the HTTP-verb actions above.
      "apigateway:TagResource",
      "apigateway:UntagResource",
    ]
    resources = [
      "arn:aws:apigateway:${local.aws_region}::/apis",
      "arn:aws:apigateway:${local.aws_region}::/apis/*",
      "arn:aws:apigateway:${local.aws_region}::/domainnames",
      "arn:aws:apigateway:${local.aws_region}::/domainnames/*",
      "arn:aws:apigateway:${local.aws_region}::/tags/*",
    ]
  }

  # Read-only: the API certificate is requested here in bootstrap and only
  # looked up by the application stack.
  statement {
    sid    = "CertificateLookup"
    effect = "Allow"
    actions = [
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "acm:GetCertificate",
      "acm:ListTagsForCertificate",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DynamoDbTables"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:UpdateTable",
      "dynamodb:DeleteTable",
      "dynamodb:DescribeTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:UpdateTimeToLive",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:ListTagsOfResource",
    ]
    resources = [
      "arn:aws:dynamodb:${local.aws_region}:${local.account_id}:table/${local.name_prefix}-*",
    ]
  }

  statement {
    sid       = "LogGroupDiscovery"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid    = "LambdaLogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:ListTagsForResource",
      "logs:TagResource",
      "logs:UntagResource",
    ]
    resources = [
      "arn:aws:logs:${local.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-*",
      "arn:aws:logs:${local.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-*:*",
    ]
  }

  statement {
    sid    = "Parameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ssm:${local.aws_region}:${local.account_id}:parameter/${local.ssm_parameter_path}/*",
    ]
  }

  statement {
    sid       = "ParameterDiscovery"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy_app" {
  name   = "application"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_app.json
}

# ------------------------------------------------------------------------------
# Identity: runtime roles (boundary-enforced) and Cognito
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_identity" {
  statement {
    sid    = "InspectAndRemoveRuntimeRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:DeleteRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"]
  }

  # Creating a role or changing what it may do is only allowed while the role
  # carries the runtime boundary. The deploy role holds no permission to remove
  # or replace a boundary. Its own role (ambrace-github-deploy-<env>) is outside
  # the ambrace-<env>-* range matched here, so it cannot modify itself.
  statement {
    sid    = "ShapeRuntimeRolesWithinBoundary"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.runtime_boundary.arn]
    }
  }

  statement {
    sid    = "ReadBoundaryPolicy"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
    ]
    resources = [aws_iam_policy.runtime_boundary.arn]
  }

  statement {
    sid       = "PassRuntimeRolesToLambda"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # API Gateway creates its own service-linked role the first time an API or
  # custom domain is created in an account, and requires the caller to be
  # allowed to create it. Limited to that one AWS service.
  statement {
    sid       = "ApiGatewayServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/ops.apigateway.amazonaws.com/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ops.apigateway.amazonaws.com"]
    }
  }

  # These Cognito actions do not support resource-level scoping.
  statement {
    sid    = "CognitoUnscoped"
    effect = "Allow"
    actions = [
      "cognito-idp:CreateUserPool",
      "cognito-idp:ListUserPools",
      "cognito-idp:DescribeUserPoolDomain",
    ]
    resources = ["*"]
  }

  # Configuration only. Deliberately no Admin* user actions: the pipeline can
  # shape the user pool but cannot create users, reset passwords or read the
  # user directory.
  statement {
    sid    = "CognitoUserPoolConfiguration"
    effect = "Allow"
    actions = [
      "cognito-idp:DescribeUserPool",
      "cognito-idp:UpdateUserPool",
      "cognito-idp:AddCustomAttributes",
      "cognito-idp:DeleteUserPool",
      "cognito-idp:GetUserPoolMfaConfig",
      "cognito-idp:SetUserPoolMfaConfig",
      "cognito-idp:CreateUserPoolClient",
      "cognito-idp:DescribeUserPoolClient",
      "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:ListUserPoolClients",
      "cognito-idp:CreateIdentityProvider",
      "cognito-idp:DescribeIdentityProvider",
      "cognito-idp:UpdateIdentityProvider",
      "cognito-idp:DeleteIdentityProvider",
      "cognito-idp:ListIdentityProviders",
      "cognito-idp:CreateUserPoolDomain",
      "cognito-idp:UpdateUserPoolDomain",
      "cognito-idp:DeleteUserPoolDomain",
      "cognito-idp:CreateGroup",
      "cognito-idp:GetGroup",
      "cognito-idp:UpdateGroup",
      "cognito-idp:DeleteGroup",
      "cognito-idp:ListGroups",
      "cognito-idp:TagResource",
      "cognito-idp:UntagResource",
      "cognito-idp:ListTagsForResource",
    ]
    resources = ["arn:aws:cognito-idp:${local.aws_region}:${local.account_id}:userpool/*"]
  }
}

resource "aws_iam_role_policy" "deploy_identity" {
  name   = "identity"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_identity.json
}
