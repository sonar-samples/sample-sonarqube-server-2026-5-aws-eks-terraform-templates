#
# Public DNS: an alias record in an existing Route 53 zone.
#

data "aws_lb_hosted_zone_id" "alb" {
  load_balancer_type = "application"
}

resource "aws_route53_record" "sonarqube" {
  zone_id = var.hosted_zone_id
  name    = local.sonarqube_fqdn
  type    = "A"

  alias {
    name                   = kubernetes_ingress_v1.sonarqube.status[0].load_balancer[0].ingress[0].hostname
    zone_id                = data.aws_lb_hosted_zone_id.alb.id
    evaluate_target_health = true
  }
}
