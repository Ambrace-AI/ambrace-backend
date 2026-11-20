variable "environment" {
  type        = string
  description = "Target deployment environment. One AWS account per environment."

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be dev or prod."
  }
}

variable "aws_account_id" {
  type        = string
  description = "AWS account this environment lives in. The provider refuses to run against any other account."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region to deploy the application runtime."
  default     = "ap-south-1"
}

# ------------------------------------------------------------------------------
# Viva behaviour
# ------------------------------------------------------------------------------

variable "gemini_live_model" {
  type        = string
  description = "Gemini Live model used to constrain ephemeral credentials."
  default     = "gemini-3.8-live"

  validation {
    condition     = can(regex("^\\S+$", var.gemini_live_model))
    error_message = "Gemini Live model must be non-empty and contain no whitespace."
  }
}

variable "viva_session_duration_minutes" {
  type        = number
  description = "Fixed viva duration, configured per environment."
  default     = 5

  validation {
    condition     = contains([5, 10, 15], var.viva_session_duration_minutes)
    error_message = "Viva duration must be 5, 10, or 15 minutes."
  }
}

# ------------------------------------------------------------------------------
# Lambda
# ------------------------------------------------------------------------------

variable "lambda_memory_size" {
  type        = number
  description = "Memory allocated to the Lambda function in MB."
  default     = 512
}

variable "lambda_timeout" {
  type        = number
  description = "Lambda function execution timeout in seconds."
  default     = 30
}

variable "log_retention_in_days" {
  type        = number
  description = "CloudWatch log retention period in days."
  default     = 14
}

variable "lambda_adapter_layer_arn" {
  type        = string
  description = "ARN of the AWS Lambda Web Adapter layer (arm64). Version from https://github.com/aws/aws-lambda-web-adapter."
  default     = "arn:aws:lambda:ap-south-1:753240598075:layer:LambdaAdapterLayerArm64:30"

  validation {
    condition     = can(regex(":753240598075:layer:LambdaAdapterLayerArm64:[0-9]+$", var.lambda_adapter_layer_arn))
    error_message = "The function is arm64; use the AWS-published LambdaAdapterLayerArm64 layer with a pinned version."
  }
}

variable "lambda_artifact_path" {
  type        = string
  description = "Relative path to the Lambda ZIP artifact from the Terraform root module."
  default     = "../../dist/ambrace-backend.zip"
}

# ------------------------------------------------------------------------------
# API
# ------------------------------------------------------------------------------

variable "custom_domain_name" {
  type        = string
  description = "Public hostname for the API (e.g. api-dev.ambrace.in). Its ACM certificate must already be ISSUED. Empty disables the custom domain."
  default     = ""
}

variable "cors_allowed_origins" {
  type        = list(string)
  description = "Exact browser origins allowed to call the API with credentials. No wildcards."

  validation {
    condition = alltrue([
      for origin in var.cors_allowed_origins :
      can(regex("^https://[a-z0-9.-]+$", origin)) || can(regex("^http://localhost:[0-9]+$", origin))
    ])
    error_message = "Each origin must be https://host with no path or wildcard, or http://localhost:<port>."
  }
}

variable "api_throttling_rate_limit" {
  type        = number
  description = "Steady-state requests per second allowed across the whole API."
  default     = 20
}

variable "api_throttling_burst_limit" {
  type        = number
  description = "Short burst of requests allowed across the whole API."
  default     = 40
}

# ------------------------------------------------------------------------------
# Authentication
# ------------------------------------------------------------------------------
# Both empty until the Cognito user pool exists. While empty, the API fails
# closed: public routes work and every protected route returns 401.

variable "cognito_user_pool_id" {
  type        = string
  description = "Cognito user pool that issues access tokens for this API."
  default     = ""
}

variable "cognito_app_client_id" {
  type        = string
  description = "Cognito app client whose access tokens this API accepts."
  default     = ""

  validation {
    condition     = (var.cognito_user_pool_id == "") == (var.cognito_app_client_id == "")
    error_message = "cognito_user_pool_id and cognito_app_client_id must be set together."
  }
}
