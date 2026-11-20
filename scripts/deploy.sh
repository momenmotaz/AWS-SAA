#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CloudPulse AWS Deployment Script (Real Terraform Deploy + Realistic --simulate)
# Usage:
#   ./scripts/deploy.sh --simulate [--region us-east-1] [--domain app.cloudpulse.demo]
#   ./scripts/deploy.sh --region us-east-1 [--email ops@example.com] [--domain ...]
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
OUT_FILE="${ROOT_DIR}/.deployment-outputs.json"

REGION="us-east-1"
ENV="prod"
PROJECT="cloudpulse"
DOMAIN=""
ZONE_ID=""
CERT_ARN=""
ALERT_EMAIL="ops-alerts@example.com"
SIMULATE=false

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }
log_ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
log_info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}[SIM]${NC} $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulate|--dry-run) SIMULATE=true; shift ;;
    --region)   REGION="$2"; shift 2 ;;
    --env)      ENV="$2"; shift 2 ;;
    --domain)   DOMAIN="$2"; shift 2 ;;
    --zone-id)  ZONE_ID="$2"; shift 2 ;;
    --cert-arn) CERT_ARN="$2"; shift 2 ;;
    --email)    ALERT_EMAIL="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,10p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  CloudPulse — AWS Multi-AZ Scalable Web App Deployment${NC}"
echo -e "${BOLD}  Region: ${REGION} | Environment: ${ENV} | Mode: $([[ "$SIMULATE" == true ]] && echo "SIMULATION (Mock AWS Data)" || echo "LIVE AWS (Terraform)")${NC}"
echo -e "${BOLD}======================================================================${NC}"

if [[ "$SIMULATE" == true ]]; then
  ACCOUNT_ID="123456789012"
  DOMAIN_EFFECTIVE="${DOMAIN:-app.cloudpulse.example.com}"
  VPC_ID="vpc-0a91f4c2e8b31d701"
  ALB_DNS="${PROJECT}-${ENV}-alb-184920341.${REGION}.elb.amazonaws.com"
  CF_ID="E2Q9X8K4M1P7Z"
  CF_DOMAIN="d2x9k4m8q1p7z.cloudfront.net"
  RDS_ENDPOINT="${PROJECT}-${ENV}-pg.c9x2k4m8q1p7.${REGION}.rds.amazonaws.com:5432"
  WAF_ARN="arn:aws:wafv2:${REGION}:${ACCOUNT_ID}:regional/webacl/${PROJECT}-${ENV}-waf/4b7e91a2-8c3d-4f10-9e21-7a5c8d3b2e01"
  SNS_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${PROJECT}-${ENV}-alerts"
  ASG_NAME="${PROJECT}-${ENV}-asg"
  DASHBOARD="${PROJECT}-${ENV}-overview"

  log_step "1/7 Validating IAM caller identity & Terraform configuration"
  sleep 0.3
  log_warn "Caller Identity: arn:aws:iam::${ACCOUNT_ID}:user/saa-architect (simulated)"
  log_ok   "Terraform modules verified under infra/terraform/ (9 .tf files)"

  log_step "2/7 Provisioning Multi-AZ VPC (${REGION}a & ${REGION}b)"
  sleep 0.4
  log_ok "aws_vpc.main                     -> ${VPC_ID} (10.0.0.0/16)"
  log_ok "aws_internet_gateway.igw         -> igw-0f32b8e1c9d4a5012"
  log_ok "aws_subnet.public[0..1]          -> subnet-01a1... (10.0.1.0/24, ${REGION}a), subnet-01b2... (10.0.2.0/24, ${REGION}b)"
  log_ok "aws_subnet.private_app[0..1]     -> subnet-02a1... (10.0.11.0/24, ${REGION}a), subnet-02b2... (10.0.12.0/24, ${REGION}b)"
  log_ok "aws_subnet.private_db[0..1]      -> subnet-03a1... (10.0.21.0/24, ${REGION}a), subnet-03b2... (10.0.22.0/24, ${REGION}b)"
  log_ok "aws_nat_gateway.nat[0..1]        -> nat-08a4c1d2e3f45011a (${REGION}a), nat-09b5d2e3f4a56022b (${REGION}b)"
  log_ok "aws_network_acl.private_db       -> acl-07c6d5e4f3a2b1098 (TCP/5432 strictly from Private App CIDRs)"

  log_step "3/7 Configuring Security Groups, IAM Role & AWS WAFv2"
  sleep 0.3
  log_ok "aws_security_group.alb           -> sg-0a11111111111111a (80/443 from 0.0.0.0/0)"
  log_ok "aws_security_group.app           -> sg-0b22222222222222b (8080 from alb-sg only; ZERO SSH)"
  log_ok "aws_security_group.db            -> sg-0c33333333333333c (5432 from app-sg only)"
  log_ok "aws_iam_role.ec2_app             -> AmazonSSMManagedInstanceCore + CloudWatchAgent + SecretsManager"
  log_ok "aws_wafv2_web_acl.alb            -> ${WAF_ARN}"
  log_info "WAF Rules Active: CommonRuleSet, SQLiRuleSet, KnownBadInputs, RateLimit(2000 req/5m)"

  log_step "4/7 Launching Amazon RDS PostgreSQL 16 (Multi-AZ)"
  sleep 0.4
  log_ok "aws_db_instance.postgres         -> ${RDS_ENDPOINT}"
  log_info "Multi-AZ: enabled (Primary: ${REGION}a | Standby: ${REGION}b | Sync Replication)"
  log_info "Storage Encrypted: true (gp3 KMS) | Publicly Accessible: false | Secrets Manager: active"

  log_step "5/7 Deploying Application Load Balancer & EC2 Auto Scaling Group"
  sleep 0.4
  log_ok "aws_lb.app                       -> ${ALB_DNS}"
  log_ok "aws_launch_template.app          -> lt-0e98a7b6c5d4f3210 (AL2023, t3.micro, IMDSv2 required)"
  log_ok "aws_autoscaling_group.app        -> ${ASG_NAME} (min=2, desired=2, max=6)"
  log_ok "EC2 Targets Healthy (2/2)        -> i-04f8a2c91d7e30b12 (${REGION}a, 10.0.11.42) & i-09c3b7e42a1f60d88 (${REGION}b, 10.0.12.87)"
  log_info "Scaling Policy: TargetTrackingScaling (ASGAverageCPUUtilization = 60%) + StepScaling"

  log_step "6/7 Provisioning Amazon CloudFront & Route 53 Alias + Health Check"
  sleep 0.3
  log_ok "aws_cloudfront_distribution.web  -> https://${CF_DOMAIN} (ID: ${CF_ID})"
  log_info "Cache Behaviors: /static/* (TTL 86400s edge cache) | /* (dynamic origin -> ALB)"
  log_ok "aws_route53_record.app_alias     -> ${DOMAIN_EFFECTIVE} -> ALIAS ${ALB_DNS}"
  log_ok "aws_route53_health_check.alb     -> hc-7a6b5c4d-3e2f-1a0b-9c8d (HTTP /health, 30s)"

  log_step "7/7 Creating CloudWatch Dashboard, Alarms & SNS Notifications"
  sleep 0.3
  log_ok "aws_sns_topic.alerts             -> ${SNS_ARN} (subscriber: ${ALERT_EMAIL})"
  log_ok "aws_cloudwatch_metric_alarm[3]   -> ec2-high-cpu (>75%), alb-target-5xx (>5), rds-high-cpu (>80%)"
  log_ok "aws_cloudwatch_dashboard.main    -> ${DASHBOARD}"

  cat <<EOF > "${OUT_FILE}"
{
  "mode": "simulated",
  "deployed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "region": "${REGION}",
  "environment": "${ENV}",
  "vpc_id": "${VPC_ID}",
  "subnets": {
    "public": ["10.0.1.0/24 (${REGION}a)", "10.0.2.0/24 (${REGION}b)"],
    "private_app": ["10.0.11.0/24 (${REGION}a)", "10.0.12.0/24 (${REGION}b)"],
    "private_db": ["10.0.21.0/24 (${REGION}a)", "10.0.22.0/24 (${REGION}b)"]
  },
  "alb_dns_name": "${ALB_DNS}",
  "cloudfront_distribution_id": "${CF_ID}",
  "cloudfront_domain_name": "${CF_DOMAIN}",
  "route53_domain": "${DOMAIN_EFFECTIVE}",
  "waf_web_acl_arn": "${WAF_ARN}",
  "asg_name": "${ASG_NAME}",
  "instances": [
    {"id": "i-04f8a2c91d7e30b12", "az": "${REGION}a", "private_ip": "10.0.11.42", "public_ip": null, "ssm_status": "Online"},
    {"id": "i-09c3b7e42a1f60d88", "az": "${REGION}b", "private_ip": "10.0.12.87", "public_ip": null, "ssm_status": "Online"}
  ],
  "rds_endpoint": "${RDS_ENDPOINT}",
  "rds_multi_az": true,
  "sns_topic_arn": "${SNS_ARN}",
  "cloudwatch_dashboard_name": "${DASHBOARD}"
}
EOF

  echo -e "\n${GREEN}${BOLD}Deployment simulation complete!${NC}"
  echo -e "  Outputs saved to : ${OUT_FILE}"
  echo -e "  Application URL  : https://${CF_DOMAIN}"
  echo -e "  ALB Endpoint     : http://${ALB_DNS}"
  echo -e "  SSM Access Cmd   : aws ssm start-session --target i-04f8a2c91d7e30b12 --region ${REGION}"
  echo -e "  Next step        : ./scripts/verify.sh --simulate"
  exit 0
fi

# ------------------------------------------------------------------------------
# REAL AWS DEPLOYMENT MODE (Terraform + AWS CLI)
# ------------------------------------------------------------------------------
for cmd in aws terraform jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required for live AWS deployment." >&2; exit 1; }
done

log_step "1/4 Verifying AWS credentials"
aws sts get-caller-identity --output table

log_step "2/4 Initializing & validating Terraform stack"
cd "${TF_DIR}"
terraform init -upgrade
terraform validate

log_step "3/4 Applying Terraform plan in ${REGION}"
terraform apply -auto-approve \
  -var="aws_region=${REGION}" \
  -var="environment=${ENV}" \
  -var="alert_email=${ALERT_EMAIL}" \
  -var="domain_name=${DOMAIN}" \
  -var="hosted_zone_id=${ZONE_ID}" \
  -var="acm_certificate_arn=${CERT_ARN}"

log_step "4/4 Exporting live stack outputs"
terraform output -json | jq 'with_entries(.value = .value.value) + {mode: "live", region: "'"${REGION}"'"}' > "${OUT_FILE}"
log_ok "Live deployment complete. Outputs saved to ${OUT_FILE}"
log_info "Run ./scripts/verify.sh to verify endpoints, WAF, SSM, and RDS Multi-AZ."
