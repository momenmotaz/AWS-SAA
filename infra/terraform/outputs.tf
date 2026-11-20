output "vpc_id" {
  value = aws_vpc.main.id
}

output "artifact_bucket_name" {
  value = aws_s3_bucket.app_artifacts.id
}

output "app_version" {
  value = local.app_version
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "alb_target_group_arn" {
  value = aws_lb_target_group.app.arn
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

output "rds_instance_id" {
  value = aws_db_instance.postgres.identifier
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "rds_multi_az" {
  value = aws_db_instance.postgres.multi_az
}

output "kms_key_arn" {
  value = aws_kms_key.cloudpulse.arn
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "cloudwatch_dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "route53_fqdn" {
  value = length(aws_route53_record.app_alias) > 0 ? aws_route53_record.app_alias[0].fqdn : null
}
