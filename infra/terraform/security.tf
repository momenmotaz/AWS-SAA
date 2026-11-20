# AWS-managed prefix list containing official Amazon CloudFront origin-facing edge IP ranges
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  # CloudFront connects to the ALB over HTTPS when an ALB certificate is provided, otherwise over HTTP (lab mode)
  alb_origin_port = var.alb_acm_certificate_arn != "" ? 443 : 80
}

# ALB Security Group — locked strictly to CloudFront origin-facing IPs by default (prevents direct ALB bypass)
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP/HTTPS ingress strictly from CloudFront edge locations (or 0.0.0.0/0 if origin-lock disabled)"
  vpc_id      = aws_vpc.main.id

  # A single ingress rule is used on purpose: the CloudFront origin-facing prefix list has ~55 entries and each
  # entry counts against the default quota of 60 inbound rules per Security Group (two ports would exceed it).
  ingress {
    description     = "Origin traffic from CloudFront on the active origin port (443 with ALB certificate, otherwise 80)"
    from_port       = local.alb_origin_port
    to_port         = local.alb_origin_port
    protocol        = "tcp"
    prefix_list_ids = var.enforce_cloudfront_origin_only ? [data.aws_ec2_managed_prefix_list.cloudfront.id] : []
    cidr_blocks     = var.enforce_cloudfront_origin_only ? [] : ["0.0.0.0/0"]
  }

  egress {
    description = "Forward traffic to application tier"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.private_app_subnet_cidrs
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

# EC2 App Security Group — ZERO SSH ingress; accepts traffic ONLY from ALB SG on port 8080
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Allow app traffic strictly from ALB; no inbound SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App HTTP from ALB Security Group only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "VPC DNS resolution (UDP)"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "VPC DNS resolution (TCP)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Outbound HTTPS via NAT Gateway (SSM, CloudWatch, Secrets Manager, npm/dnf)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "PostgreSQL to Private DB subnets"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.private_db_subnet_cidrs
  }

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}

# RDS Database Security Group — accepts PostgreSQL 5432 ONLY from EC2 App SG
resource "aws_security_group" "db" {
  name        = "${var.project_name}-db-sg"
  description = "Allow PostgreSQL strictly from EC2 App Security Group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from EC2 App SG only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = {
    Name = "${var.project_name}-db-sg"
  }
}

# Least-Privilege IAM Role for EC2 Instances (SSM Session Manager + CloudWatch + Single RDS Secret Read)
resource "aws_iam_role" "ec2_app" {
  name = "${var.project_name}-${var.environment}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.ec2_app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "read_rds_secret" {
  name = "${var.project_name}-read-rds-secret"
  role = aws_iam_role.ec2_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSpecificRDSSecretOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_db_instance.postgres.master_user_secret[0].secret_arn]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_app" {
  name = "${var.project_name}-${var.environment}-ec2-profile"
  role = aws_iam_role.ec2_app.name
}
