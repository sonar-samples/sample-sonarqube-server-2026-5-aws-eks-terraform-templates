#
# SonarQube Agentic Storage
#
# s3  - two private buckets (job artifacts vs Vortex context) plus a gateway VPC endpoint.
#       Server, Orchestrator and Vortex authenticate with IRSA. Runtimes receive presigned URLs.
# efs - two ReadWriteMany claims on a shared filesystem. Isolation is mount subPath scoping.
#

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = merge(var.tags, { Name = "${var.name}-s3" })
}

locals {
  agentic_buckets = local.use_s3 ? {
    jobs   = local.jobs_store
    vortex = local.vortex_store
  } : {}
}

resource "aws_s3_bucket" "agentic" {
  for_each = local.agentic_buckets

  bucket_prefix = "${var.name}-${each.key}-"

  tags = merge(var.tags, {
    Name    = "${var.name}-${each.value}"
    Purpose = "SonarQube ${each.value}"
  })
}

resource "aws_s3_bucket_public_access_block" "agentic" {
  for_each = aws_s3_bucket.agentic

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "agentic" {
  for_each = aws_s3_bucket.agentic

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "agentic" {
  for_each = aws_s3_bucket.agentic

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "agentic" {
  for_each = aws_s3_bucket.agentic

  bucket = each.value.id

  rule {
    id     = "expire-agent-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.agentic
  ]
}

#
# IRSA for Server, Orchestrator and Vortex. Runtimes never hold these credentials.
#

data "aws_iam_policy_document" "agentic_s3" {
  count = local.use_s3 ? 1 : 0

  statement {
    sid    = "AgenticBucketAccess"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = [for bucket in aws_s3_bucket.agentic : bucket.arn]
  }

  statement {
    sid    = "AgenticObjectAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [for bucket in aws_s3_bucket.agentic : "${bucket.arn}/*"]
  }
}

resource "aws_iam_policy" "agentic_s3" {
  count       = local.use_s3 ? 1 : 0
  name        = "${var.name}-agentic-s3"
  description = "S3 access for SonarQube agentic components"
  policy      = data.aws_iam_policy_document.agentic_s3[0].json
  tags        = var.tags
}

data "aws_iam_policy_document" "agentic_s3_assume" {
  count = local.use_s3 ? 1 : 0

  statement {
    sid     = "SonarQubeAgenticIRSA"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

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
        "system:serviceaccount:sonarqube:sonarqube",
        "system:serviceaccount:sonarqube:sonarqube-agent-orchestrator",
        "system:serviceaccount:sonarqube:sonarqube-vortex"
      ]
    }
  }
}

resource "aws_iam_role" "agentic_s3" {
  count              = local.use_s3 ? 1 : 0
  name               = "${var.name}-agentic-s3"
  assume_role_policy = data.aws_iam_policy_document.agentic_s3_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "agentic_s3" {
  count      = local.use_s3 ? 1 : 0
  role       = aws_iam_role.agentic_s3[0].name
  policy_arn = aws_iam_policy.agentic_s3[0].arn
}

#
# EFS filesystem backend
#

resource "aws_security_group" "efs" {
  count  = local.use_efs ? 1 : 0
  name   = "${var.name}-efs"
  vpc_id = module.vpc.vpc_id
  tags   = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "efs_nodes" {
  count                        = local.use_efs ? 1 : 0
  security_group_id            = aws_security_group.efs[0].id
  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

resource "aws_efs_file_system" "agentic" {
  count           = local.use_efs ? 1 : 0
  encrypted       = true
  throughput_mode = "elastic"

  tags = merge(var.tags, {
    Name = "${var.name}-agentic"
  })
}

resource "aws_efs_mount_target" "agentic" {
  for_each = local.use_efs ? toset(module.vpc.private_subnets) : toset([])

  file_system_id  = aws_efs_file_system.agentic[0].id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs[0].id]
}

resource "aws_eks_addon" "efs_csi" {
  count = local.use_efs ? 1 : 0

  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  service_account_role_arn    = aws_iam_role.efs_csi[0].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.efs_csi
  ]
}

resource "kubernetes_storage_class_v1" "efs" {
  count = local.use_efs ? 1 : 0

  metadata {
    name = "sonarqube-agentic-efs"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.agentic[0].id
    directoryPerms   = "700"
  }

  mount_options = ["tls"]

  depends_on = [
    aws_eks_addon.efs_csi,
    aws_efs_mount_target.agentic
  ]
}

resource "kubernetes_persistent_volume_claim_v1" "jobs" {
  count = local.use_efs ? 1 : 0

  metadata {
    name      = local.jobs_claim
    namespace = local.ns
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.efs[0].metadata[0].name

    resources {
      requests = {
        storage = var.jobs_storage_size
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "vortex" {
  count = local.use_efs ? 1 : 0

  metadata {
    name      = local.vortex_claim
    namespace = local.ns
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.efs[0].metadata[0].name

    resources {
      requests = {
        storage = var.vortex_storage_size
      }
    }
  }
}
