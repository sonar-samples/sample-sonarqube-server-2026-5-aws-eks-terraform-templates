#
# Database credentials
#

resource "random_password" "db" {
  length  = 32
  special = false
}

#
# Store the generated database credentials in AWS Secrets Manager.
#

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name}/sonarqube-db"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
  })
}

#
# RDS Security Group
#
# PostgreSQL is reachable only from the EKS worker nodes.
#

resource "aws_security_group" "rds" {
  name   = "${var.name}-rds"
  vpc_id = module.vpc.vpc_id
  tags   = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "rds_nodes" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "rds" {
  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

#
# Amazon RDS PostgreSQL 16, private, Multi-AZ.
#

resource "aws_db_instance" "sonarqube" {
  identifier = "${var.name}-postgres"

  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage     = 128
  max_allocated_storage = 256
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name = module.vpc.database_subnet_group_name

  vpc_security_group_ids = [
    aws_security_group.rds.id
  ]

  multi_az            = var.postgres_high_availability
  publicly_accessible = false

  backup_retention_period = var.postgres_backup_retention_days

  skip_final_snapshot = true
  deletion_protection = false

  tags = var.tags
}
