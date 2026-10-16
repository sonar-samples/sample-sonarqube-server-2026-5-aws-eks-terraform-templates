#
# Two-AZ VPC with three subnet roles:
#   public  -> NAT + internet-facing ALB
#   private -> EKS nodes
#   data    -> RDS PostgreSQL
#

module "vpc" {
  source                       = "terraform-aws-modules/vpc/aws"
  version                      = "~> 6.0"
  name                         = var.name
  cidr                         = var.vpc_cidr
  azs                          = var.azs
  public_subnets               = var.public_subnet_cidrs
  private_subnets              = var.app_subnet_cidrs
  database_subnets             = var.data_subnet_cidrs
  create_database_subnet_group = true
  enable_nat_gateway           = true
  single_nat_gateway           = false
  one_nat_gateway_per_az       = true
  enable_dns_support           = true
  enable_dns_hostnames         = true
  public_subnet_tags           = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags          = { "kubernetes.io/role/internal-elb" = "1" }
  tags                         = var.tags
}
