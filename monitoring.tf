#
# CloudWatch Container Insights.
#

resource "aws_cloudwatch_log_group" "containerinsights" {
  for_each = toset([
    "performance",
    "application",
    "dataplane",
    "host",
  ])

  name              = "/aws/containerinsights/${module.eks.cluster_name}/${each.value}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_eks_addon" "cloudwatch" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  service_account_role_arn    = aws_iam_role.cloudwatch.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Every node pool is tainted. The controller is a Deployment, so unlike the
  # fluent-bit DaemonSet it will stay Pending unless it can land on the system pool.
  configuration_values = jsonencode({
    manager = {
      nodeSelector = {
        "kubernetes.io/os" = "linux"
        workload           = "system"
      }
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Exists"
      }]
    }
  })

  depends_on = [
    module.eks,
    helm_release.lbc,
    aws_iam_role_policy_attachment.cloudwatch_agent,
    aws_cloudwatch_log_group.containerinsights
  ]
}
