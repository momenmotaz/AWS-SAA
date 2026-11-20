variable "project_name" {
  description = "Project prefix used for resource naming"
  type        = string
  default     = "cloudpulse"
}

variable "environment" {
  description = "Deployment environment (prod, staging, demo)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS Region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for Public Subnets across 2 AZs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly 2 public subnet CIDRs (one per Availability Zone) are required."
  }
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for Private Application Subnets across 2 AZs"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]

  validation {
    condition     = length(var.private_app_subnet_cidrs) == 2
    error_message = "Exactly 2 private application subnet CIDRs (one per Availability Zone) are required."
  }
}

variable "private_db_subnet_cidrs" {
  description = "CIDR blocks for Private Database Subnets across 2 AZs"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]

  validation {
    condition     = length(var.private_db_subnet_cidrs) == 2
    error_message = "Exactly 2 private database subnet CIDRs (one per Availability Zone) are required."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the Auto Scaling Group"
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  description = "Minimum EC2 instances in the ASG"
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Desired EC2 instances in the ASG"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum EC2 instances in the ASG"
  type        = number
  default     = 6
}

variable "db_instance_class" {
  description = "RDS PostgreSQL instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Initial PostgreSQL database name"
  type        = string
  default     = "cloudpulse"
}

variable "db_username" {
  description = "Master database username (password managed automatically in Secrets Manager)"
  type        = string
  default     = "cloudpulse_admin"
}

variable "alert_email" {
  description = "Optional email address subscribed to the CloudWatch SNS alarm topic"
  type        = string
  default     = ""
}

variable "enforce_cloudfront_origin_only" {
  description = "Restrict ALB Security Group to AWS CloudFront origin-facing prefix list and require X-CloudFront-Verify header"
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "Optional custom domain name for Route 53 Alias record pointing to CloudFront (requires hosted_zone_id and cloudfront_acm_certificate_arn in us-east-1)"
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Optional Route 53 Hosted Zone ID"
  type        = string
  default     = ""
}

variable "alb_acm_certificate_arn" {
  description = "Optional ACM TLS Certificate ARN in var.aws_region to encrypt CloudFront-to-ALB origin traffic over HTTPS"
  type        = string
  default     = ""

  validation {
    condition     = var.alb_acm_certificate_arn == "" || can(regex("^arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/.+", var.alb_acm_certificate_arn))
    error_message = "alb_acm_certificate_arn must be empty or a valid ACM certificate ARN in the deployment region."
  }
}

variable "cloudfront_acm_certificate_arn" {
  description = "Optional ACM TLS Certificate ARN in us-east-1 for custom domain HTTPS on CloudFront"
  type        = string
  default     = ""

  validation {
    condition     = var.cloudfront_acm_certificate_arn == "" || can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/.+", var.cloudfront_acm_certificate_arn))
    error_message = "CloudFront ACM certificates must be issued in us-east-1 (arn:aws:acm:us-east-1:<account>:certificate/...)."
  }
}
