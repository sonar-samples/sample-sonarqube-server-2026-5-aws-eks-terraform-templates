output "sonarqube_url" {
  description = "Public HTTPS address of SonarQube Server. Point CI scanners and agent clients here."
  value       = local.sonarqube_url
}

output "alb_hostname" {
  description = "DNS name of the internet-facing ALB created by the AWS Load Balancer Controller."
  value = try(
    kubernetes_ingress_v1.sonarqube.status[0].load_balancer[0].ingress[0].hostname,
    null
  )
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_api_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubernetes_version" {
  value = module.eks.cluster_version
}

output "postgres_endpoint" {
  description = "RDS hostname. Resolves inside the VPC."
  value       = aws_db_instance.sonarqube.address
}

output "rds_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "storage_backend" {
  description = "Which storage backend the agentic components are configured against."
  value       = var.enable_agentic ? var.storage_backend : "n/a (agentic disabled)"
}

output "s3_jobs_bucket" {
  value = local.s3_jobs_bucket
}

output "s3_vortex_bucket" {
  value = local.s3_vortex_bucket
}

output "get_credentials_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "port_forward_command" {
  description = "Troubleshooting fallback when the ALB backend is unhealthy."
  value       = "kubectl port-forward -n ${local.ns} svc/sonarqube-sonarqube 9000:9000"
}
