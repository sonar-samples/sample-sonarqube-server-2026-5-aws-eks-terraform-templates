#
# SonarQube Helm release
#
# Static values live in sonarqube-values.yaml. Everything environment-specific is overlaid here
# as separate YAML documents, which Helm merges in order.
#

locals {
  runtime_values = {
    for family, override in {
      hunter      = lookup(local.image_override, "hunter", {})
      remediation = lookup(local.image_override, "remediation", {})
      } : family => merge(override, local.agentic_scheduling, {
        enabled      = true
        replicaCount = var.runtime_replica_count
        networkPolicy = {
          enabled = true
        }
    })
  }

  agentic = {
    agenticSigningSecret = {
      existingSecret = one(kubernetes_secret_v1.agentic_instance[*].metadata[0].name)
      key            = "instance-secret"
    }

    # The chart DEFAULTS gvisor.enabled to true, which deploys a privileged installer DaemonSet
    # that rewrites containerd configuration — unsupported on EKS managed AL2023 nodes.
    gvisor = {
      enabled = false
    }

    agentKeyDerivation = local.agentic_scheduling

    vortexAnalysis = merge(lookup(local.image_override, "vortex", {}), local.agentic_scheduling, {
      enabled = true
    })

    agentOrchestrator = merge(lookup(local.image_override, "orchestrator", {}), local.agentic_scheduling, {
      enabled   = true
      scheduler = { enabled = true }
    })

    hunterAgent      = local.runtime_values["hunter"]
    remediationAgent = local.runtime_values["remediation"]

    agentEgressProxy = merge(local.agentic_scheduling, {
      allowedDomains = local.egress_domains
      networkPolicy = {
        enabled            = true
        egressPorts        = [80, 443]
        egressExcludeCidrs = ["169.254.0.0/16"]
      }
    })
  }

  s3_irsa_annotation = {
    "eks.amazonaws.com/role-arn" = one(aws_iam_role.agentic_s3[*].arn)
  }

  storage_s3 = {
    serviceAccount = {
      annotations = local.s3_irsa_annotation
    }

    sonarProperties = {
      "sonar.agentic.storage.type"   = "S3"
      "sonar.agentic.storage.bucket" = local.s3_vortex_bucket
      "sonar.agentic.storage.region" = var.aws_region
    }

    vortexAnalysis = {
      serviceAccount = {
        create         = true
        name           = "sonarqube-vortex"
        automountToken = true
        annotations    = local.s3_irsa_annotation
      }
      storage = {
        type            = "S3"
        region          = var.aws_region
        bucket          = local.s3_vortex_bucket
        pathStyleAccess = false
      }
    }

    agentOrchestrator = {
      serviceAccount = {
        create         = true
        name           = "sonarqube-agent-orchestrator"
        automountToken = true
        annotations    = local.s3_irsa_annotation
      }
      storage = {
        type      = "S3"
        region    = var.aws_region
        bucket    = local.s3_jobs_bucket
        pathStyle = false
      }
    }
  }

  storage_efs = {
    sonarProperties = {
      "sonar.agentic.storage.type"                = "FILESYSTEM"
      "sonar.agentic.storage.filesystem.base-dir" = local.vortex_base_dir
    }

    extraVolumes = [{
      name                  = "vortex-context"
      persistentVolumeClaim = { claimName = local.vortex_claim }
    }]

    extraVolumeMounts = [{
      name      = "vortex-context"
      mountPath = local.vortex_base_dir
    }]

    vortexAnalysis = {
      storage = {
        type       = "FILESYSTEM"
        filesystem = { baseDir = local.vortex_base_dir }
      }
      extraVolumes = [{
        name                  = "vortex-context"
        persistentVolumeClaim = { claimName = local.vortex_claim }
      }]
      extraVolumeMounts = [{
        name      = "vortex-context"
        mountPath = local.vortex_base_dir
        readOnly  = true
      }]
    }

    agentOrchestrator = {
      storage = {
        type       = "FILESYSTEM"
        filesystem = { baseDir = local.jobs_base_dir }
      }
      extraVolumes = [{
        name                  = "agentic-jobs"
        persistentVolumeClaim = { claimName = local.jobs_claim }
      }]
      extraVolumeMounts = [{
        name      = "agentic-jobs"
        mountPath = local.jobs_base_dir
      }]
    }

    hunterAgent      = local.runtime_storage_efs["hunter"]
    remediationAgent = local.runtime_storage_efs["remediation"]
  }

  runtime_storage_efs = {
    for family in ["hunter", "remediation"] : family => {
      storage = {
        type       = "FILESYSTEM"
        filesystem = { baseDir = "${local.jobs_base_dir}/${family}" }
      }
      extraVolumes = [{
        name                  = "agentic-jobs"
        persistentVolumeClaim = { claimName = local.jobs_claim }
      }]
      extraVolumeMounts = [{
        name      = "agentic-jobs"
        mountPath = "${local.jobs_base_dir}/${family}"
        subPath   = family
      }]
    }
  }
}

resource "helm_release" "sonarqube" {
  name       = "sonarqube"
  repository = "https://SonarSource.github.io/helm-chart-sonarqube"
  chart      = "sonarqube"
  version    = var.sonarqube_chart_version
  namespace  = local.ns
  timeout    = 1800
  wait       = true

  values = compact([
    file("${path.module}/sonarqube-values.yaml"),

    yamlencode({
      service = {
        type = "ClusterIP"
      }
    }),

    yamlencode({
      sonarProperties = {
        "sonar.core.serverBaseURL" = local.sonarqube_url
      }
    }),

    yamlencode({
      jdbcOverwrite = {
        enabled               = true
        jdbcUrl               = "jdbc:postgresql://${aws_db_instance.sonarqube.address}:5432/${var.db_name}?sslmode=require"
        jdbcUsername          = var.db_username
        jdbcSecretName        = kubernetes_secret_v1.db.metadata[0].name
        jdbcSecretPasswordKey = "password"
      }
    }),

    var.sonarqube_image_tag == "" ? "" : yamlencode({
      image = { tag = var.sonarqube_image_tag }
    }),

    var.enable_settings_encryption ? yamlencode({
      sonarSecretKey = "sonarqube-encryption-secret"
    }) : "",

    local.agentic_in_helm ? yamlencode(local.agentic) : "",
    local.use_s3 && local.agentic_in_helm ? yamlencode(local.storage_s3) : "",
    local.use_efs && local.agentic_in_helm ? yamlencode(local.storage_efs) : "",
  ])

  depends_on = [
    aws_db_instance.sonarqube,
    helm_release.lbc,
    kubernetes_storage_class_v1.gp3,
    kubernetes_secret_v1.db,
    kubernetes_secret_v1.monitoring,
    kubernetes_secret_v1.agentic_instance,
    aws_iam_role_policy_attachment.agentic_s3,
    kubernetes_persistent_volume_claim_v1.jobs,
    kubernetes_persistent_volume_claim_v1.vortex
  ]
}
