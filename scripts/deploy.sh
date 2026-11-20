#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CloudPulse AWS Deployment Script (Preflight + Plan + Confirmed Apply | --simulate)
# Usage:
#   ./scripts/deploy.sh --simulate [--region us-east-1] [--domain app.cloudpulse.example.com]
#   ./scripts/deploy.sh --region us-east-1 [--plan-only] [--email ops@example.com]
#   ./scripts/deploy.sh --region us-east-1 --domain app.example.com --zone-id Z123 \
#     --alb-cert-arn arn:aws:acm:us-east-1:... --cf-cert-arn arn:aws:acm:us-east-1:...
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
OUT_FILE="${ROOT_DIR}/.deployment-outputs.json"

REGION="us-east-1"
ENV="prod"
PROJECT="cloudpulse"
DOMAIN=""
ZONE_ID=""
ALB_CERT_ARN=""
CF_CERT_ARN=""
ALERT_EMAIL=""
SIMULATE=false
PLAN_ONLY=false
AUTO_CONFIRM=false

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }
log_ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
log_info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
log_sim()  { echo -e "  ${YELLOW}[SIMULATED]${NC} $1"; }
log_err()  { echo -e "  ${RED}[ERROR]${NC} $1" >&2; }

usage() {
  cat <<'EOF'
CloudPulse Deployment Script

Options:
  --simulate              Run local mock simulation (creates NO AWS resources)
  --plan-only             Run preflight, terraform init/validate/plan without applying
  --yes                   Skip interactive confirmation prompt for terraform apply
  --region <region>       AWS region (default: us-east-1)
  --env <name>            Environment name (default: prod)
  --email <address>       Optional SNS alarm subscription email
  --domain <fqdn>         Optional custom domain for Route 53 -> CloudFront
  --zone-id <id>          Route 53 Hosted Zone ID (required with --domain)
  --alb-cert-arn <arn>    ACM certificate ARN in --region for CloudFront->ALB HTTPS
  --cf-cert-arn <arn>     ACM certificate ARN in us-east-1 for CloudFront custom domain
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulate)     SIMULATE=true; shift ;;
    --plan-only)    PLAN_ONLY=true; shift ;;
    --yes)          AUTO_CONFIRM=true; shift ;;
    --region)       REGION="$2"; shift 2 ;;
    --env)          ENV="$2"; shift 2 ;;
    --domain)       DOMAIN="$2"; shift 2 ;;
    --zone-id)      ZONE_ID="$2"; shift 2 ;;
    --alb-cert-arn) ALB_CERT_ARN="$2"; shift 2 ;;
    --cf-cert-arn)  CF_CERT_ARN="$2"; shift 2 ;;
    --cert-arn)     ALB_CERT_ARN="$2"; shift 2 ;;
    --email)        ALERT_EMAIL="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) log_err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  CloudPulse — AWS Multi-AZ Scalable Web App Deployment${NC}"
if [[ "$SIMULATE" == true ]]; then
  echo -e "  ${YELLOW}${BOLD}MODE: MOCK / SIMULATION ONLY — NO REAL AWS RESOURCES CREATED${NC}"
else
  echo -e "  MODE: LIVE AWS (Terraform) | Region: ${REGION} | Env: ${ENV}"
fi
echo -e "${BOLD}======================================================================${NC}"

if [[ "$SIMULATE" == true ]]; then
  ACCOUNT_ID="123456789012"
  DOMAIN_EFFECTIVE="${DOMAIN:-app.cloudpulse.example.com}"
  EMAIL_EFFECTIVE="${ALERT_EMAIL:-ops-alerts@example.com}"
  VPC_ID="vpc-0a91f4c2e8b31d701"
  ALB_DNS="${PROJECT}-${ENV}-alb-184920341.${REGION}.elb.amazonaws.com"
  TG_ARN="arn:aws:elasticloadbalancing:${REGION}:${ACCOUNT_ID}:targetgroup/${PROJECT}-${ENV}-tg/6d4e2f1a8b9c0123"
  CF_ID="E2Q9X8K4M1P7Z"
  CF_DOMAIN="d2x9k4m8q1p7z.cloudfront.net"
  RDS_ID="${PROJECT}-${ENV}-pg"
  RDS_ENDPOINT="${RDS_ID}.c9x2k4m8q1p7.${REGION}.rds.amazonaws.com:5432"
  WAF_ARN="arn:aws:wafv2:${REGION}:${ACCOUNT_ID}:regional/webacl/${PROJECT}-${ENV}-waf/4b7e91a2-8c3d-4f10-9e21-7a5c8d3b2e01"
  KMS_ARN="arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/11112222-3333-4444-5555-666677778888"
  BUCKET="${PROJECT}-${ENV}-artifacts-${ACCOUNT_ID}-${REGION}"
  SNS_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${PROJECT}-${ENV}-alerts"
  ASG_NAME="${PROJECT}-${ENV}-asg"
  DASHBOARD="${PROJECT}-${ENV}-overview"

  log_step "1/7 [SIMULATION] Checking local project structure"
  log_sim "Mock Caller Identity: arn:aws:iam::${ACCOUNT_ID}:user/saa-architect"
  log_sim "Terraform configs verified in ${TF_DIR}"

  log_step "2/7 [SIMULATION] Multi-AZ VPC (${REGION}a & ${REGION}b)"
  log_sim "aws_vpc.main                -> ${VPC_ID} (10.0.0.0/16)"
  log_sim "aws_subnet.public[0..1]     -> 10.0.1.0/24 (${REGION}a), 10.0.2.0/24 (${REGION}b)"
  log_sim "aws_subnet.private_app[0..1]-> 10.0.11.0/24 (${REGION}a), 10.0.12.0/24 (${REGION}b)"
  log_sim "aws_subnet.private_db[0..1] -> 10.0.21.0/24 (${REGION}a), 10.0.22.0/24 (${REGION}b)"
  log_sim "aws_nat_gateway.nat[0..1]   -> nat-08a4c1d2e3f45011a (${REGION}a), nat-09b5d2e3f4a56022b (${REGION}b)"
  log_sim "aws_vpc_endpoint.s3         -> vpce-04e1a2b3c4d5f6789 (Gateway)"

  log_step "3/7 [SIMULATION] KMS, Private S3 Artifact Bucket, IAM & WAFv2"
  log_sim "aws_kms_key.cloudpulse      -> ${KMS_ARN}"
  log_sim "aws_s3_bucket.app_artifacts -> s3://${BUCKET}/releases/sim-release/ (versioned + KMS)"
  log_sim "aws_security_group.alb      -> sg-0a11111111111111a (CloudFront prefix list + X-CloudFront-Verify)"
  log_sim "aws_wafv2_web_acl.alb       -> ${WAF_ARN} (REGIONAL, FORWARDED_IP rate limit)"

  log_step "4/7 [SIMULATION] Amazon RDS PostgreSQL 16 (Multi-AZ)"
  log_sim "aws_db_instance.postgres    -> ${RDS_ENDPOINT} (Multi-AZ, KMS encrypted, private)"

  log_step "5/7 [SIMULATION] ALB & EC2 Auto Scaling Group"
  log_sim "aws_lb.app                  -> ${ALB_DNS}"
  log_sim "aws_autoscaling_group.app   -> ${ASG_NAME} (min=2, desired=2, max=6; npm ci + systemd)"

  log_step "6/7 [SIMULATION] CloudFront & Route 53"
  log_sim "aws_cloudfront_distribution -> https://${CF_DOMAIN} (ID: ${CF_ID})"
  log_sim "aws_route53_record          -> ${DOMAIN_EFFECTIVE} -> ALIAS ${CF_DOMAIN}"

  log_step "7/7 [SIMULATION] CloudWatch & SNS"
  log_sim "aws_sns_topic.alerts        -> ${SNS_ARN} (${EMAIL_EFFECTIVE})"
  log_sim "aws_cloudwatch_dashboard    -> ${DASHBOARD}"

  cat <<EOF > "${OUT_FILE}"
{
  "mode": "simulated",
  "note": "MOCK SIMULATION DATA — NO REAL AWS RESOURCES EXIST",
  "deployed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "region": "${REGION}",
  "environment": "${ENV}",
  "vpc_id": "${VPC_ID}",
  "artifact_bucket_name": "${BUCKET}",
  "alb_dns_name": "${ALB_DNS}",
  "alb_target_group_arn": "${TG_ARN}",
  "cloudfront_distribution_id": "${CF_ID}",
  "cloudfront_domain_name": "${CF_DOMAIN}",
  "route53_fqdn": "${DOMAIN_EFFECTIVE}",
  "waf_web_acl_arn": "${WAF_ARN}",
  "asg_name": "${ASG_NAME}",
  "rds_instance_id": "${RDS_ID}",
  "rds_endpoint": "${RDS_ENDPOINT}",
  "rds_multi_az": true,
  "kms_key_arn": "${KMS_ARN}",
  "sns_topic_arn": "${SNS_ARN}",
  "cloudwatch_dashboard_name": "${DASHBOARD}"
}
EOF

  echo -e "\n${YELLOW}${BOLD}Simulation complete (no AWS charges incurred).${NC}"
  echo -e "  Mock state file : ${OUT_FILE}"
  echo -e "  Next mock check : ./scripts/verify.sh --simulate"
  exit 0
fi

# ------------------------------------------------------------------------------
# REAL AWS PREFLIGHT CHECKS & DEPLOYMENT
# ------------------------------------------------------------------------------
log_step "1/5 Running preflight checks"
for cmd in aws terraform jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_err "Required tool '$cmd' is not installed or not in PATH."
    exit 1
  fi
done
log_ok "Found aws, terraform ($(terraform version -json | jq -r '.terraform_version')), and jq"

if [[ -n "$DOMAIN" ]]; then
  if [[ -z "$ZONE_ID" || -z "$CF_CERT_ARN" ]]; then
    log_err "--domain requires both --zone-id and --cf-cert-arn (an ACM certificate in us-east-1)."
    exit 1
  fi
  if [[ ! "$CF_CERT_ARN" =~ ^arn:aws:acm:us-east-1:[0-9]{12}:certificate/.+ ]]; then
    log_err "CloudFront ACM certificates MUST be in us-east-1. Received: ${CF_CERT_ARN}"
    exit 1
  fi
fi

if [[ -n "$ALB_CERT_ARN" ]] && [[ ! "$ALB_CERT_ARN" =~ ^arn:aws:acm:${REGION}:[0-9]{12}:certificate/.+ ]]; then
  log_err "ALB ACM certificate region must match --region (${REGION}). Received: ${ALB_CERT_ARN}"
  exit 1
fi

if ! aws sts get-caller-identity --output table; then
  log_err "AWS credentials are not configured or expired. Configure 'aws configure' or AWS_PROFILE first."
  exit 1
fi
log_ok "AWS caller identity verified for region ${REGION}"

echo -e "\n${YELLOW}${BOLD}Cost Warning:${NC} This architecture provisions billable resources (2x NAT Gateways, ALB, WAFv2, Multi-AZ RDS, 2x EC2) estimated around ~\$145/month if left running continuously."
echo -e "Remember to run ${BOLD}./scripts/destroy.sh --region ${REGION}${NC} after finishing your validation."

log_step "2/5 Initializing & validating Terraform (using locked provider versions)"
cd "${TF_DIR}"
terraform init -input=false
terraform fmt -check -recursive
terraform validate
log_ok "Terraform initialized and validated cleanly"

TF_VARS=(
  -var="aws_region=${REGION}"
  -var="environment=${ENV}"
  -var="alert_email=${ALERT_EMAIL}"
  -var="domain_name=${DOMAIN}"
  -var="hosted_zone_id=${ZONE_ID}"
  -var="alb_acm_certificate_arn=${ALB_CERT_ARN}"
  -var="cloudfront_acm_certificate_arn=${CF_CERT_ARN}"
)

log_step "3/5 Generating Terraform execution plan"
terraform plan -input=false -out=tfplan "${TF_VARS[@]}"
log_ok "Execution plan written to ${TF_DIR}/tfplan"

if [[ "$PLAN_ONLY" == true ]]; then
  echo -e "\n${GREEN}${BOLD}Plan-only mode requested. No AWS resources were modified.${NC}"
  exit 0
fi

log_step "4/5 Confirmation Gate"
if [[ "$AUTO_CONFIRM" != true ]]; then
  read -r -p "Type 'yes' to apply the plan above in ${REGION} (anything else aborts): " REPLY
  if [[ "$REPLY" != "yes" ]]; then
    rm -f "${TF_DIR}/tfplan"
    echo "Aborted by user. No resources created."
    exit 1
  fi
fi

terraform apply -input=false tfplan
rm -f "${TF_DIR}/tfplan"

log_step "5/5 Exporting live stack outputs"
terraform output -json | jq 'with_entries(.value = .value.value) + {mode: "live", region: "'"${REGION}"'"}' > "${OUT_FILE}"
log_ok "Live deployment complete. Outputs saved to ${OUT_FILE}"
log_info "Run ./scripts/verify.sh next to validate live endpoints, WAF, RDS Multi-AZ, ASG, and SSM."
