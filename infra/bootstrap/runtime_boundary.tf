# ==============================================================================
# Runtime permissions boundary
# ==============================================================================
#
# The deploy role can create IAM roles (the Lambda execution roles). Without a
# limit, anyone who can change a workflow could create a role with admin rights
# and run code as it. The deploy role is therefore only allowed to create or
# modify roles that carry THIS boundary, and a role can never exceed its boundary
# no matter what policy is attached to it.
#
# Consequence: giving application code a new AWS capability (S3, Bedrock, SES,
# ...) is a reviewed change here, applied by an admin, not something a pipeline
# can grant itself.

data "aws_iam_policy_document" "runtime_boundary" {
  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${local.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-*:*",
    ]
  }

  statement {
    sid    = "ApplicationTables"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:BatchWriteItem",
      # Transactions are authorised through the item-level actions above plus
      # ConditionCheckItem; there are no separate Transact* IAM actions.
      "dynamodb:ConditionCheckItem",
      "dynamodb:DescribeTable",
    ]
    resources = [
      "arn:aws:dynamodb:${local.aws_region}:${local.account_id}:table/${local.name_prefix}-*",
      "arn:aws:dynamodb:${local.aws_region}:${local.account_id}:table/${local.name_prefix}-*/index/*",
    ]
  }

  statement {
    sid    = "ReadOwnParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${local.aws_region}:${local.account_id}:parameter/${local.ssm_parameter_path}/*",
    ]
  }

  # SecureString parameters are encrypted with the AWS-managed aws/ssm key. AWS
  # does not document whether that key's account-wide grant survives a permissions
  # boundary, so decrypt is allowed here explicitly, and only when the request
  # comes through Parameter Store.
  statement {
    sid       = "DecryptOwnParametersViaSsm"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:aws:kms:${local.aws_region}:${local.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.aws_region}.amazonaws.com"]
    }
  }

  # Needed by the Cognito pre-sign-up trigger that links a Google sign-in to an
  # existing email/password user with the same verified email.
  statement {
    sid    = "LinkFederatedUsers"
    effect = "Allow"
    actions = [
      "cognito-idp:ListUsers",
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminLinkProviderForUser",
    ]
    resources = [
      "arn:aws:cognito-idp:${local.aws_region}:${local.account_id}:userpool/*",
    ]
  }
}

resource "aws_iam_policy" "runtime_boundary" {
  name        = "${local.name_prefix}-runtime-boundary"
  description = "Maximum permissions any ${local.name_prefix} application role may hold. Roles created by the deploy pipeline must attach this as their permissions boundary."
  policy      = data.aws_iam_policy_document.runtime_boundary.json
}
