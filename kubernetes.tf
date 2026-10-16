#
# SonarQube Namespace
#

resource "kubernetes_namespace_v1" "sonarqube" {
  metadata {
    name = "sonarqube"

    labels = {
      "app.kubernetes.io/part-of" = "sonarqube"
    }
  }

  depends_on = [
    module.eks
  ]
}
