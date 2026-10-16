#
# AWS Load Balancer Controller
#

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.14.1"
  namespace  = "kube-system"

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      nodeSelector = {
        workload = "system"
      }
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Exists"
      }]
    })
  ]

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.lbc.arn
  }

  # IMDSv2 hop limit on the nodes is 1, so pods cannot read the VPC id from
  # instance metadata. Pass it explicitly or the controller crash-loops and its
  # mutating webhook rejects every Service.
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy.lbc
  ]
}

#
# GP3 Storage Class
#
# Used for the main SonarQube persistent volume.
#

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [
    module.eks
  ]
}
