output "vpc_id" {
  value = aws_vpc.main.id
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.web.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.web.id
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.alb.arn
}

output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "rds_multi_az" {
  value = aws_db_instance.postgres.multi_az
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "cloudwatch_dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}
