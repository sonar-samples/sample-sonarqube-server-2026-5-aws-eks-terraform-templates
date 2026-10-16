#
# ACM certificate for the public ALB, validated by DNS against the existing Route 53 zone.
# ACM renews the certificate automatically; no scheduled
# terraform apply is required for renewal.
#

resource "aws_acm_certificate" "sonarqube" {
  domain_name       = local.sonarqube_fqdn
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.sonarqube.domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "sonarqube" {
  certificate_arn         = aws_acm_certificate.sonarqube.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
