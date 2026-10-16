# SonarQube Server 2026.5 Enterprise Edition with agentic components - Amazon EKS Installation

> Last updated: October 2026
>
> The observed output reflects its recorded environment and may differ by release, organization, and entitlement. Check the current SonarQube documentation before using these instructions in a live environment.

This repository contains Terraform templates for deploying SonarQube Server 2026.5 Enterprise Edition on Amazon Elastic Kubernetes Service (EKS), optionally with the agentic components: Sonar Vortex analysis, the Agent Orchestrator, SonarQube Hunter Agent, and SonarQube Remediation Agent.

## Infrastructure Components

| Component | AWS Service |
|-----------|-------------|
| Container Orchestration | Amazon EKS, VPC CNI with Network Policy enforcement |
| Database | Amazon RDS for PostgreSQL (v16, Multi-AZ, private subnets) |
| Agentic Storage | Amazon S3 (two buckets, VPC gateway endpoint) or Amazon EFS |
| HTTPS / Ingress | Application Load Balancer via the AWS Load Balancer Controller |
| TLS Certificate | AWS Certificate Manager (ACM) with Route 53 DNS validation, renewed automatically |
| Networking | Amazon VPC across two Availability Zones, NAT gateway per AZ |
| DNS | Amazon Route 53 alias record |
| Monitoring | Amazon CloudWatch Container Insights |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) 1.6 or later
- [AWS CLI](https://aws.amazon.com/cli/) and `kubectl` installed, with credentials that can create EKS, VPC, RDS, S3, ACM, Route 53, and IAM resources
- A SonarQube Server Enterprise Edition license, plus entitlement for each agentic capability you enable
- SonarQube Server must be using the [new license management](https://docs.sonarsource.com/sonarqube-server/2025.4/instance-administration/license-administration/online-license-management) and not Server ID based licensing
- A registered domain with a Route 53 hosted zone that this AWS account can update
- Enough on-demand standard vCPU quota in the target region. The default node groups use 16 vCPUs, or 32 with the agentic node group, and a node group rollout needs headroom for one extra instance

These templates deploy the agent runtimes with the standard, supported Kubernetes configuration. They do not configure alternative runtime sandboxing technologies. Organizations with platform-mandated workload-isolation controls should validate those controls independently against their EKS environment and the released SonarQube chart.

## Quick Start

```bash
# Edit terraform.tfvars with your specific values
cp terraform.tfvars.example terraform.tfvars

# Run Terraform commands
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Access SonarQube at `https://<host_name>.<domain_name>`
Default login: `admin` / `admin` (change immediately)

ACM issues and renews the certificate automatically, so there is no renewal job to maintain and no need to re-run Terraform on a schedule.

## Configuration Values

Copy `terraform.tfvars.example` into `terraform.tfvars` and update the specific values for your environment:

```hcl
aws_region = "us-east-1"
name       = "sonarqube-eks"

azs = ["us-east-1a", "us-east-1b"]

vpc_cidr            = "10.0.0.0/16"
public_subnet_cidrs = ["10.0.0.0/24", "10.0.1.0/24"]
app_subnet_cidrs    = ["10.0.10.0/24", "10.0.11.0/24"]
data_subnet_cidrs   = ["10.0.20.0/24", "10.0.21.0/24"]

kubernetes_version = "1.35"

admin_principal_arns = [
  "arn:aws:iam::123456789012:role/REPLACE_WITH_EKS_ADMIN_ROLE"
]

hosted_zone_id = "REPLACE_WITH_ROUTE53_HOSTED_ZONE_ID"
domain_name    = "example.com"
host_name      = "sonarqube"

sonarqube_chart_version = "2026.5.1001"

enable_agentic        = false
agentic_paused        = false
runtime_replica_count = 1
storage_backend       = "s3"

llm_allowed_domains = ["api.anthropic.com"]

enable_settings_encryption = false

tags = { Team = "", Owner = "" }
```

**Notes:**
- `sonarqube_chart_version` - pin an exact published version, `2026.5.1000` or later
- `admin_principal_arns` - use the full IAM role ARN, **including any path**. `aws sts get-caller-identity` omits the path, and EKS rejects the path-less ARN with an `invalid principal` error. Any entry matching the identity running Terraform is skipped, because that principal already has cluster admin
- `enable_agentic` - also creates the agentic node group, storage, and secrets. Setting it back to `false` destroys them and their data; use `agentic_paused` for upgrades
- `storage_backend` - `s3` (default) creates two private, versioned, encrypted buckets reached through a VPC gateway endpoint; the server, Orchestrator, and Vortex authenticate with IRSA and runtimes receive presigned URLs. `efs` provides a shared filesystem instead
- `llm_allowed_domains` - every runtime destination (LLM, identity, DevOps). The S3 bucket hostnames are added automatically
- `runtime_replica_count` - concurrent jobs per agent runtime
- `enable_settings_encryption` - set `true` on a second apply, after creating the `sonarqube-encryption-secret` from a key generated in the SonarQube UI
- `postgres_high_availability` - set `false` where Multi-AZ is not wanted
- Subnet CIDRs must not overlap each other or any network you peer with
- Every input is documented in `variables.tf`

## Configuration Files

| File | Description |
|------|-------------|
| `versions.tf` | Terraform and provider versions, Kubernetes and Helm authentication |
| `network.tf` | VPC, public, app and data subnets, NAT gateways |
| `eks.tf` | EKS cluster, `system`, `sonarqube` and `agentic` node groups, access entries, IRSA roles |
| `addons.tf` | AWS Load Balancer Controller and the `gp3` storage class |
| `database.tf` | RDS PostgreSQL 16 and the credentials secret |
| `storage.tf` | S3 buckets or EFS, the S3 gateway endpoint, IRSA for the agentic components |
| `acm.tf` | ACM certificate and DNS validation |
| `alb.tf` | ALB ingress with HTTPS and HTTP redirect |
| `dns.tf` | Route 53 alias record to the ALB |
| `monitoring.tf` | CloudWatch Container Insights |
| `kubernetes.tf` | Namespace |
| `secrets.tf` | Kubernetes secrets, including the generated agentic signing secret |
| `sonarqube.tf` | SonarQube Helm release, including the agentic components |
| `sonarqube-values.yaml` | Static Helm chart values |
| `variables.tf` | Variable definitions |
| `outputs.tf` | Access URL, addresses, kubeconfig command |
| `files/iam-policy-lbc.json` | IAM policy for the AWS Load Balancer Controller |

## Resources Created

| Resource | Name |
|----------|------|
| VPC + Subnets | `<name>` (public, app and data subnets across two AZs) |
| EKS Cluster | `<name>` |
| System Node Group | `system` (`m7i.xlarge`, 2 nodes, tainted `CriticalAddonsOnly`) |
| SonarQube Node Group | `sonarqube` (`m7i.2xlarge`, 1 node, tainted `workload=sonarqube`) |
| Agentic Node Group | `agentic` (`m7i.2xlarge`, 2 nodes, tainted `workload=agentic`, `enable_agentic = true` only) |
| Application Load Balancer | `<name>-sonarqube` |
| RDS PostgreSQL | `<name>-postgres` (v16, Multi-AZ, private) |
| S3 Buckets | `<name>-jobs-*` and `<name>-vortex-*` (`enable_agentic = true` with `storage_backend = "s3"`) |
| TLS Certificate / DNS Record | `<host_name>.<domain_name>` |
| Secrets Manager Secret | `<name>/sonarqube-db` (database credentials) |
| Helm Release | `sonarqube` (Enterprise Edition) |

## Notes

- Before production use, confirm from inside each agent runtime pod that allowlisted hosts are reachable only through the egress proxy and that a direct connection is blocked. VPC CNI Network Policy is what enforces the chart's NetworkPolicies; without it, EKS accepts NetworkPolicy objects and enforces none of them.
- The chart defaults `gvisor.enabled` to `true`, which deploys a privileged installer DaemonSet that rewrites containerd configuration and is unsupported on EKS managed nodes. These templates set it to `false`, which is what gives the runtimes the standard Kubernetes configuration.
- The ALB enforces no request body limit. If you add AWS WAF in front of it later, raise its body size limits so analyzer-context uploads are not rejected with HTTP 413 - a rejected upload does not fail the scan, so Vortex silently loses context.
- SonarQube Server bundles Elasticsearch and keeps its indices on disk. Persistence is enabled on a 20 Gi encrypted `gp3` volume so a pod restart does not trigger a full reindex.
- Database and agentic signing secrets are generated by Terraform and stored in Terraform state. Use an encrypted remote backend.
- The Kubernetes and Helm providers call `aws eks get-token` on every connection, so long applies do not fail on an expired token. Keep that provider configuration.

## Upgrade

Set `agentic_paused` to `true` and update `sonarqube_chart_version`, then run `terraform apply`. Complete the database migration at `https://<host_name>.<domain_name>/setup`, wait for status `UP`, then set `agentic_paused` to `false` and apply again.

## Cleanup

```bash
terraform destroy
```

If the EKS cluster was deleted outside Terraform, first run `terraform state list | grep -E '^(helm_release|kubernetes_)' | xargs terraform state rm`.
