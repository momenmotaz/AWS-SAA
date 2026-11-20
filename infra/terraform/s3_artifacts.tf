data "aws_caller_identity" "current" {}

locals {
  app_files = {
    "package.json"      = "${path.module}/../../app/package.json"
    "package-lock.json" = "${path.module}/../../app/package-lock.json"
    "server.js"         = "${path.module}/../../app/server.js"
    "public/index.html" = "${path.module}/../../app/public/index.html"
    "public/styles.css" = "${path.module}/../../app/public/styles.css"
  }

  # Content-addressed release ID so EC2 instances always pull an immutable, versioned artifact bundle
  app_version = substr(sha256(join("", [for k in sort(keys(local.app_files)) : filesha256(local.app_files[k])])), 0, 16)
}

resource "aws_s3_bucket" "app_artifacts" {
  bucket        = "${var.project_name}-${var.environment}-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-${var.environment}-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "app_artifacts" {
  bucket                  = aws_s3_bucket.app_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "app_artifacts" {
  bucket = aws_s3_bucket.app_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_artifacts" {
  bucket = aws_s3_bucket.app_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudpulse.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "app_artifacts" {
  bucket = aws_s3_bucket.app_artifacts.id

  rule {
    id     = "expire-old-artifact-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "app_artifacts_tls_only" {
  bucket = aws_s3_bucket.app_artifacts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.app_artifacts.arn,
          "${aws_s3_bucket.app_artifacts.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_s3_object" "app_bundle" {
  for_each = local.app_files

  bucket     = aws_s3_bucket.app_artifacts.id
  key        = "releases/${local.app_version}/${each.key}"
  source     = each.value
  etag       = filemd5(each.value)
  kms_key_id = aws_kms_key.cloudpulse.arn

  depends_on = [
    aws_s3_bucket_public_access_block.app_artifacts,
    aws_s3_bucket_versioning.app_artifacts,
    aws_s3_bucket_server_side_encryption_configuration.app_artifacts,
    aws_s3_bucket_policy.app_artifacts_tls_only,
  ]
}

# Private Gateway VPC Endpoint for S3 (zero hourly cost, keeps artifact sync & AL2023 repo traffic off public NAT)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private_app[*].id

  tags = {
    Name = "${var.project_name}-${var.environment}-s3-endpoint"
  }
}
