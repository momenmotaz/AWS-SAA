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
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for Private Application Subnets across 2 AZs"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "CIDR blocks for Private Database Subnets across 2 AZs"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
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

variable "domain_name" {
  description = "Optional custom domain name for Route 53 Alias record (e.g. app.example.com)"
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Optional Route 53 Hosted Zone ID"
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "Optional ACM TLS Certificate ARN in the deployment region for ALB HTTPS"
  type        = string
  default     = ""
}
