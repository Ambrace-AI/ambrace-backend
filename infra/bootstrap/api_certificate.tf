# ==============================================================================
# TLS certificate for the API custom domain
# ==============================================================================
#
# Requested here, by an admin, rather than in the pipeline: issuing needs a DNS
# record added by hand at the registrar (ambrace.in DNS is hosted outside AWS to
# avoid a Route 53 hosted-zone charge), and a pipeline must never sit waiting on
# a human. The application stack only looks the certificate up once it is ISSUED.
#
# There is intentionally no aws_acm_certificate_validation resource: apply returns
# immediately and prints the record to create (output api_certificate_validation_records).

resource "aws_acm_certificate" "api" {
  count = var.api_domain_name != "" ? 1 : 0

  domain_name       = var.api_domain_name
  validation_method = "DNS"

  tags = {
    Name = var.api_domain_name
  }

  lifecycle {
    create_before_destroy = true
  }
}
