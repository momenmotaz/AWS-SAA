resource "aws_kms_key" "cloudpulse" {
  description             = "CMK for ${var.project_name}-${var.environment} RDS storage, Secrets Manager secret, and S3 artifacts"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-${var.environment}-kms"
  }
}

resource "aws_kms_alias" "cloudpulse" {
  name          = "alias/${var.project_name}-${var.environment}"
  target_key_id = aws_kms_key.cloudpulse.key_id
}

resource "aws_db_subnet_group" "postgres" {
  name       = "${var.project_name}-${var.environment}-db-subnets"
  subnet_ids = aws_subnet.private_db[*].id

  tags = {
    Name = "${var.project_name}-${var.environment}-db-subnet-group"
  }
}

resource "aws_db_instance" "postgres" {
  identifier            = "${var.project_name}-${var.environment}-pg"
  engine                = "postgres"
  engine_version        = "16.4"
  instance_class        = var.db_instance_class
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.cloudpulse.arn

  db_name                       = var.db_name
  username                      = var.db_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.cloudpulse.arn

  multi_az                   = true
  publicly_accessible        = false
  db_subnet_group_name       = aws_db_subnet_group.postgres.name
  vpc_security_group_ids     = [aws_security_group.db.id]
  backup_retention_period    = 7
  deletion_protection        = false
  skip_final_snapshot        = true
  auto_minor_version_upgrade = true

  tags = {
    Name = "${var.project_name}-${var.environment}-rds-multi-az"
  }
}
