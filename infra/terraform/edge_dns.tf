# Unified Edge Path: Users -> Route 53 (Alias) -> CloudFront -> WAF + Origin Header -> ALB -> EC2
resource "aws_cloudfront_distribution" "web" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.project_name}-${var.environment} edge distribution"
  price_class     = "PriceClass_100"
  aliases         = var.domain_name != "" && var.cloudfront_acm_certificate_arn != "" ? [var.domain_name] : []

  origin {
    domain_name = aws_lb.app.dns_name
    origin_id   = "alb-origin"

    # Secret header verified by ALB listener rule to prevent direct-to-ALB bypass
    custom_header {
      name  = "X-CloudFront-Verify"
      value = random_password.cloudfront_origin_verify.result
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = var.alb_acm_certificate_arn != "" ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Dynamic application traffic (bypass cache, forward Host/Origin/Authorization & cookies)
  default_cache_behavior {
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Host", "Origin", "Authorization"]
      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # Static assets (/static/*) cached aggressively at CloudFront edge locations
  ordered_cache_behavior {
    path_pattern           = "/static/*"
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 3600
    default_ttl = 86400
    max_ttl     = 604800
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.cloudfront_acm_certificate_arn == "" ? true : false
    acm_certificate_arn            = var.cloudfront_acm_certificate_arn != "" ? var.cloudfront_acm_certificate_arn : null
    ssl_support_method             = var.cloudfront_acm_certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = var.cloudfront_acm_certificate_arn != "" ? "TLSv1.2_2021" : "TLSv1"
  }
}

# Optional Route 53 Alias Record pointing cleanly to CloudFront (unified edge entry point)
resource "aws_route53_record" "app_alias" {
  count   = var.domain_name != "" && var.hosted_zone_id != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.web.domain_name
    zone_id                = aws_cloudfront_distribution.web.hosted_zone_id
    evaluate_target_health = false
  }
}

# Route 53 Active Health Check monitoring /health via CloudFront HTTPS endpoint
resource "aws_route53_health_check" "web" {
  count             = var.domain_name != "" && var.hosted_zone_id != "" ? 1 : 0
  fqdn              = aws_cloudfront_distribution.web.domain_name
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${var.project_name}-${var.environment}-edge-health"
  }
}
