# TFLint configuration shared by infra/bootstrap and infra/app.
# Run: tflint --init && tflint --recursive --config "$(pwd)/.tflint.hcl"

tflint {
  required_version = ">= 0.66"
}

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Provider-aware checks: invalid instance/runtime names, malformed ARNs and other
# mistakes that `terraform validate` accepts and AWS rejects at apply time.
plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
