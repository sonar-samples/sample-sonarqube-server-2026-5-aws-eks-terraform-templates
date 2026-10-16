variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
}

variable "name" {
  type        = string
  default     = "sonarqube-eks"
  description = "Base name used for AWS and Kubernetes resources."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to supported AWS resources."
}

#
# Networking
#

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the VPC."
}

variable "azs" {
  type        = list(string)
  description = "Exactly two availability zones. Required for RDS Multi-AZ and the ALB."

  validation {
    condition     = length(var.azs) == 2
    error_message = "Exactly two AZs are required."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
  description = "Public subnets for NAT gateways and the internet-facing ALB."

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly two public subnet CIDRs are required."
  }
}

variable "app_subnet_cidrs" {
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
  description = "Private subnets for EKS nodes."

  validation {
    condition     = length(var.app_subnet_cidrs) == 2
    error_message = "Exactly two app subnet CIDRs are required."
  }
}

variable "data_subnet_cidrs" {
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
  description = "Private subnets for RDS PostgreSQL."

  validation {
    condition     = length(var.data_subnet_cidrs) == 2
    error_message = "Exactly two data subnet CIDRs are required."
  }
}

#
# Amazon EKS
#

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version used by the EKS cluster."
}

variable "admin_principal_arns" {
  type        = list(string)
  default     = []
  description = "IAM principal ARNs granted EKS cluster administrator access."
}

variable "system_instance_type" {
  type        = string
  default     = "m7i.xlarge"
  description = "Instance type for the system node group."
}

variable "system_node_count" {
  type        = number
  default     = 2
  description = "Desired size of the system node group."
}

variable "sonarqube_instance_type" {
  type        = string
  default     = "m7i.2xlarge"
  description = "Instance type for the SonarQube node group."
}

variable "agentic_instance_type" {
  type        = string
  default     = "m7i.2xlarge"
  description = "Instance type for the agentic node group."
}

variable "agentic_node_count" {
  type        = number
  default     = 2
  description = "Desired size of the agentic node group when enable_agentic is true."
}

#
# DNS and TLS
#

variable "hosted_zone_id" {
  type        = string
  description = "Route 53 hosted zone ID for the public SonarQube DNS record and ACM validation."
}

variable "domain_name" {
  type        = string
  description = "Existing Route 53 zone name, e.g. example.com."
}

variable "host_name" {
  type        = string
  default     = "sonarqube"
  description = "SonarQube Server is served at https://<host_name>.<domain_name>."
}

#
# PostgreSQL / RDS
#

variable "db_name" {
  type        = string
  default     = "sonarqube"
  description = "PostgreSQL database name used by SonarQube."
}

variable "db_username" {
  type        = string
  default     = "sonarqube"
  description = "PostgreSQL username used by SonarQube."
}

variable "db_instance_class" {
  type        = string
  default     = "db.m6g.large"
  description = "RDS PostgreSQL instance class."
}

variable "postgres_high_availability" {
  type        = bool
  default     = true
  description = "Enable RDS Multi-AZ. Set false in a region without multiple usable AZs."
}

variable "postgres_backup_retention_days" {
  type        = number
  default     = 7
  description = "RDS backup retention in days."
}

#
# SonarQube
#

variable "sonarqube_chart_version" {
  type        = string
  description = "SonarQube Helm chart version. Agentic support needs 2026.5.1000 or later."
}

variable "sonarqube_image_tag" {
  type        = string
  default     = ""
  description = "Optional Server image tag override. Empty uses the chart appVersion with edition=enterprise."
}

variable "enable_settings_encryption" {
  type        = bool
  default     = false
  description = "Set true on a SECOND apply, after creating the sonarqube-encryption-secret from a key generated in the SonarQube UI."
}

#
# Agentic components
#

variable "enable_agentic" {
  type        = bool
  default     = false
  description = "Deploy Vortex, the Agent Orchestrator, both agent runtimes, their node group, storage and secrets. Turning it off destroys that infrastructure and its data; use agentic_paused for upgrades."
}

variable "agentic_paused" {
  type        = bool
  default     = false
  description = "Remove agentic components from the Helm release so SonarQube Server can be upgraded while the agentic node group, storage and secrets stay."
}

variable "runtime_replica_count" {
  type        = number
  default     = 1
  description = "Fixed replica count for Hunter and Remediation. Each replica handles one job at a time."
}

variable "llm_allowed_domains" {
  type        = list(string)
  default     = ["api.anthropic.com"]
  description = "Hostnames the agent runtimes may reach through the egress proxy, in addition to S3."
}

variable "storage_backend" {
  type        = string
  default     = "s3"
  description = "Agentic storage backend: s3 (presigned URLs, recommended) or efs (shared filesystem mounts)."

  validation {
    condition     = contains(["s3", "efs"], var.storage_backend)
    error_message = "storage_backend must be s3 or efs."
  }
}

variable "jobs_storage_size" {
  type        = string
  default     = "100Gi"
  description = "EFS claim size for agent job artifacts. Used only when storage_backend is efs."
}

variable "vortex_storage_size" {
  type        = string
  default     = "100Gi"
  description = "EFS claim size for Vortex analyzer context. Used only when storage_backend is efs."
}

variable "agentic_images" {
  description = "Optional image overrides per agentic component. Empty repository uses the chart default."
  type = object({
    vortex       = object({ repository = string, tag = string })
    orchestrator = object({ repository = string, tag = string })
    hunter       = object({ repository = string, tag = string })
    remediation  = object({ repository = string, tag = string })
  })
  default = {
    vortex       = { repository = "", tag = "" }
    orchestrator = { repository = "", tag = "" }
    hunter       = { repository = "", tag = "" }
    remediation  = { repository = "", tag = "" }
  }
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "CloudWatch log retention for Container Insights."
}
