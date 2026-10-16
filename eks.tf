data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  # Cluster creator admin is already granted by the EKS module. Passing that same
  # principal again makes CreateAccessEntry fail with a duplicate principal.
  access_entries = {
    for i, arn in var.admin_principal_arns : "admin-${i}" => {
      principal_arn = arn

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

          access_scope = {
            type = "cluster"
          }
        }
      }
    } if arn != data.aws_iam_session_context.current.issuer_arn
  }

  #
  # Workload separation:
  #
  #   system    -> Kubernetes/platform infrastructure (CriticalAddonsOnly)
  #   sonarqube -> SonarQube Server
  #   agentic   -> Vortex / Orchestrator / Hunter / Remediation / egress proxy
  #

  node_group_system = {
    system = {
      name                     = "${var.name}-system"
      iam_role_name            = "${var.name}-sys-ng"
      iam_role_use_name_prefix = false
      subnet_ids               = module.vpc.private_subnets
      instance_types           = [var.system_instance_type]
      capacity_type            = "ON_DEMAND"
      min_size                 = var.system_node_count
      desired_size             = var.system_node_count
      max_size                 = max(var.system_node_count, 3)

      labels = {
        workload = "system"
      }

      taints = {
        critical = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      update_config = {
        max_unavailable = 1
      }

      tags = merge(var.tags, {
        Name     = "${var.name}-system"
        Workload = "system"
      })
    }
  }

  node_group_sonarqube = {
    sonarqube = {
      name                     = "${var.name}-sonarqube"
      iam_role_name            = "${var.name}-sq-ng"
      iam_role_use_name_prefix = false
      subnet_ids               = module.vpc.private_subnets
      instance_types           = [var.sonarqube_instance_type]
      capacity_type            = "ON_DEMAND"
      min_size                 = 1
      desired_size             = 1
      max_size                 = 2

      labels = {
        workload = "sonarqube"
      }

      taints = {
        workload = {
          key    = "workload"
          value  = "sonarqube"
          effect = "NO_SCHEDULE"
        }
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 128
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      update_config = {
        max_unavailable = 1
      }

      tags = merge(var.tags, {
        Name     = "${var.name}-sonarqube"
        Workload = "sonarqube"
      })
    }
  }

  node_group_agentic = var.enable_agentic ? {
    agentic = {
      name                     = "${var.name}-agentic"
      iam_role_name            = "${var.name}-agt-ng"
      iam_role_use_name_prefix = false
      subnet_ids               = module.vpc.private_subnets
      instance_types           = [var.agentic_instance_type]
      capacity_type            = "ON_DEMAND"
      min_size                 = var.agentic_node_count
      desired_size             = var.agentic_node_count
      max_size                 = max(var.agentic_node_count, 4)

      labels = {
        workload = "agentic"
      }

      taints = {
        workload = {
          key    = "workload"
          value  = "agentic"
          effect = "NO_SCHEDULE"
        }
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 128
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      update_config = {
        max_unavailable = 1
      }

      tags = merge(var.tags, {
        Name     = "${var.name}-agentic"
        Workload = "agentic"
      })
    }
  } : {}
}

#
# Amazon EKS
#

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  #
  # Public + private API so terraform apply can run from a laptop.
  #

  endpoint_public_access  = true
  endpoint_private_access = true

  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true
  access_entries                           = local.access_entries

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    coredns = {}

    kube-proxy = {}

    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }

    aws-ebs-csi-driver = {
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  eks_managed_node_groups = merge(
    local.node_group_system,
    local.node_group_sonarqube,
    local.node_group_agentic
  )

  tags = var.tags
}

#
# Amazon EBS CSI Driver IAM
#
# The SonarQube persistent volume uses the gp3 StorageClass with
# ebs.csi.aws.com. The EBS CSI controller therefore requires AWS
# permissions to create, attach, detach, modify, and delete EBS volumes.
#
# IRSA keeps these permissions on the CSI controller instead of
# granting EBS permissions to every EC2 worker node.
#

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

#
# AWS Load Balancer Controller IAM
#
# Policy is vendored from kubernetes-sigs/aws-load-balancer-controller v2.14.1.
# Attached inline because the JSON exceeds the default managed-policy size quota.
#

data "aws_iam_policy_document" "lbc_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.name}-lbc"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "lbc" {
  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.lbc.id
  policy = file("${path.module}/files/iam-policy-lbc.json")
}

#
# CloudWatch Container Insights IAM
#

data "aws_iam_policy_document" "cloudwatch_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent",
        "system:serviceaccount:amazon-cloudwatch:amazon-cloudwatch-observability"
      ]
    }
  }
}

resource "aws_iam_role" "cloudwatch" {
  name               = "${var.name}-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_xray" {
  role       = aws_iam_role.cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

#
# EFS CSI driver IAM (filesystem agentic backend only)
#

data "aws_iam_policy_document" "efs_csi_assume" {
  count = local.use_efs ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:kube-system:efs-csi-controller-sa",
        "system:serviceaccount:kube-system:efs-csi-node-sa"
      ]
    }
  }
}

resource "aws_iam_role" "efs_csi" {
  count              = local.use_efs ? 1 : 0
  name               = "${var.name}-efs-csi"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count      = local.use_efs ? 1 : 0
  role       = aws_iam_role.efs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}
