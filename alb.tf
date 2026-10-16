#
# Public Application Load Balancer
#
# Terminates HTTPS on 443 with the ACM certificate, redirects HTTP to HTTPS, and forwards to SonarQube Server on 9000.
# Idle timeout is 300s so large analysis-report and analyzer-context uploads can complete.
#

resource "kubernetes_ingress_v1" "sonarqube" {
  wait_for_load_balancer = true

  metadata {
    name      = "sonarqube"
    namespace = local.ns

    annotations = {
      "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/listen-ports"             = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"             = "443"
      "alb.ingress.kubernetes.io/certificate-arn"          = aws_acm_certificate_validation.sonarqube.certificate_arn
      "alb.ingress.kubernetes.io/backend-protocol"         = "HTTP"
      "alb.ingress.kubernetes.io/healthcheck-protocol"     = "HTTP"
      "alb.ingress.kubernetes.io/healthcheck-path"         = "/api/system/status"
      "alb.ingress.kubernetes.io/success-codes"            = "200"
      "alb.ingress.kubernetes.io/load-balancer-name"       = local.alb_name
      "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=300"
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = local.sonarqube_fqdn

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "sonarqube-sonarqube"

              port {
                number = 9000
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.sonarqube,
    helm_release.lbc
  ]
}
