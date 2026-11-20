# Shared secret header verified on ALB to ensure requests come strictly through CloudFront
resource "random_password" "cloudfront_origin_verify" {
  length  = 32
  special = false
}

resource "aws_lb" "app" {
  name                       = "${var.project_name}-${var.environment}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.project_name}-${var.environment}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name                 = "${var.project_name}-${var.environment}-tg"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# HTTP Listener: redirects to HTTPS when ALB ACM certificate is configured; otherwise enforces CloudFront header
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = var.alb_acm_certificate_arn != "" ? "redirect" : (var.enforce_cloudfront_origin_only ? "fixed-response" : "forward")

    dynamic "redirect" {
      for_each = var.alb_acm_certificate_arn != "" ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = var.alb_acm_certificate_arn == "" && var.enforce_cloudfront_origin_only ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "Forbidden: access must route through CloudFront"
        status_code  = "403"
      }
    }

    target_group_arn = var.alb_acm_certificate_arn == "" && !var.enforce_cloudfront_origin_only ? aws_lb_target_group.app.arn : null
  }
}

resource "aws_lb_listener_rule" "http_cloudfront_verify" {
  count        = var.alb_acm_certificate_arn == "" && var.enforce_cloudfront_origin_only ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    http_header {
      http_header_name = "X-CloudFront-Verify"
      values           = [random_password.cloudfront_origin_verify.result]
    }
  }
}

# HTTPS Listener (recommended for production end-to-end TLS: Viewer -> CloudFront -> ALB)
resource "aws_lb_listener" "https" {
  count             = var.alb_acm_certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.alb_acm_certificate_arn

  default_action {
    type = var.enforce_cloudfront_origin_only ? "fixed-response" : "forward"

    dynamic "fixed_response" {
      for_each = var.enforce_cloudfront_origin_only ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "Forbidden: access must route through CloudFront"
        status_code  = "403"
      }
    }

    target_group_arn = !var.enforce_cloudfront_origin_only ? aws_lb_target_group.app.arn : null
  }
}

resource "aws_lb_listener_rule" "https_cloudfront_verify" {
  count        = var.alb_acm_certificate_arn != "" && var.enforce_cloudfront_origin_only ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    http_header {
      http_header_name = "X-CloudFront-Verify"
      values           = [random_password.cloudfront_origin_verify.result]
    }
  }
}

# AWS WAFv2 Regional Web ACL protecting ALB against OWASP Top 10 + volumetric bursts
resource "aws_wafv2_web_acl" "alb" {
  name        = "${var.project_name}-${var.environment}-waf"
  description = "OWASP Top 10 managed rules and IP rate limit for ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-waf-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 20
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-waf-sqli"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 30
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-waf-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "PerIPRateLimit"
    priority = 40
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-waf-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf-acl"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.app.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}
