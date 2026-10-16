locals {
  ns             = kubernetes_namespace_v1.sonarqube.metadata[0].name
  sonarqube_fqdn = "${var.host_name}.${var.domain_name}"
  sonarqube_url  = "https://${local.sonarqube_fqdn}"

  use_s3          = var.enable_agentic && var.storage_backend == "s3"
  use_efs         = var.enable_agentic && var.storage_backend == "efs"
  agentic_in_helm = var.enable_agentic && !var.agentic_paused
  jobs_store      = "agent-jobs"
  vortex_store    = "vortex-context"
  jobs_claim      = local.jobs_store
  vortex_claim    = local.vortex_store
  jobs_base_dir   = "/agentic-storage"
  vortex_base_dir = "/vortex-context"

  s3_jobs_bucket   = try(aws_s3_bucket.agentic["jobs"].bucket, "")
  s3_vortex_bucket = try(aws_s3_bucket.agentic["vortex"].bucket, "")
  s3_jobs_host     = local.use_s3 ? "${local.s3_jobs_bucket}.s3.${var.aws_region}.amazonaws.com" : ""
  s3_vortex_host   = local.use_s3 ? "${local.s3_vortex_bucket}.s3.${var.aws_region}.amazonaws.com" : ""

  egress_domains = concat(
    var.llm_allowed_domains,
    compact([local.s3_jobs_host, local.s3_vortex_host]),
  )

  agentic_scheduling = {
    nodeSelector = {
      workload = "agentic"
    }
    tolerations = [{
      key      = "workload"
      operator = "Equal"
      value    = "agentic"
      effect   = "NoSchedule"
    }]
  }

  image_override = {
    for name, img in var.agentic_images :
    name => { for k, v in { image = img } : k => v if img.repository != "" }
  }

  alb_name = substr("${var.name}-sonarqube", 0, 32)
}
