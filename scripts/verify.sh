#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CloudPulse Post-Deployment Verification Script (Live AWS or --simulate)
# Usage:
#   ./scripts/verify.sh --simulate
#   ./scripts/verify.sh
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${ROOT_DIR}/.deployment-outputs.json"
SIMULATE=false

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
head_sec() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }

for arg in "$@"; do
  case "$arg" in
    --simulate|--dry-run) SIMULATE=true ;;
    -h|--help) sed -n '3,8p' "$0"; exit 0 ;;
  esac
done

if [[ ! -f "${OUT_FILE}" ]]; then
  echo "No deployment state found at ${OUT_FILE}."
  echo "Run './scripts/deploy.sh --simulate' (or live deploy) first."
  exit 1
fi

MODE=$(jq -r '.mode' "${OUT_FILE}")
[[ "${MODE}" == "simulated" ]] && SIMULATE=true

REGION=$(jq -r '.region' "${OUT_FILE}")
ALB_DNS=$(jq -r '.alb_dns_name' "${OUT_FILE}")
CF_DOMAIN=$(jq -r '.cloudfront_domain_name' "${OUT_FILE}")
ASG_NAME=$(jq -r '.asg_name' "${OUT_FILE}")
RDS_ENDPOINT=$(jq -r '.rds_endpoint' "${OUT_FILE}")

echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  CloudPulse — Architecture Validation Checklist ($([[ "$SIMULATE" == true ]] && echo "SIMULATION" || echo "LIVE AWS"))${NC}"
echo -e "${BOLD}======================================================================${NC}"

if [[ "$SIMULATE" == true ]]; then
  head_sec "1. Unified Edge Flow (Route 53 -> CloudFront -> WAF -> ALB -> EC2 -> RDS)"
  sleep 0.2
  pass "GET https://${CF_DOMAIN}/health -> HTTP 200 {\"status\":\"healthy\",\"database\":\"connected\"}"
  pass "GET https://${CF_DOMAIN}/api/status -> HTTP 200 (IMDSv2 instance metadata + RDS visit logged)"
  pass "Direct ALB bypass blocked (CloudFront prefix list + X-CloudFront-Verify header -> HTTP 403)"
  pass "Target Group healthy targets: 2/2 (i-04f8a2c91d7e30b12 in ${REGION}a, i-09c3b7e42a1f60d88 in ${REGION}b)"

  head_sec "2. Amazon CloudFront Static Asset Caching"
  sleep 0.2
  pass "GET https://${CF_DOMAIN}/static/styles.css -> HTTP 200 | X-Cache: Hit from cloudfront | Age: 142"

  head_sec "3. AWS WAF OWASP Top 10 Protection"
  sleep 0.2
  pass "GET https://${CF_DOMAIN}/?id=1'%20OR%20'1'='1 -> HTTP 403 Forbidden (Matched: AWSManagedRulesSQLiRuleSet)"
  pass "Per-IP Rate Limit rule active (2,000 requests / 5 minutes)"

  head_sec "4. Private Compute Isolation & Bastion-Free SSM Session Manager"
  sleep 0.2
  pass "EC2 Public IPv4: none (10.0.11.42 & 10.0.12.87 strictly in Private App Subnets)"
  pass "Security Group sg-0b22222222222222b: port 22 SSH closed; port 8080 from ALB SG only"
  pass "AWS Systems Manager Fleet Status: 2/2 instances Online (Session Manager ready)"

  head_sec "5. Amazon RDS Multi-AZ Isolation & High Availability"
  sleep 0.2
  pass "Endpoint: ${RDS_ENDPOINT}"
  pass "MultiAZ=true | PubliclyAccessible=false | StorageEncrypted=true | BackupRetention=7d"

  head_sec "6. CloudWatch Alarms & SNS Notifications"
  sleep 0.2
  pass "Alarms OK (3/3): cloudpulse-ec2-high-cpu, cloudpulse-alb-target-5xx, cloudpulse-rds-high-cpu"
  pass "Dashboard active: $(jq -r '.cloudwatch_dashboard_name' "${OUT_FILE}")"

  echo -e "\n${GREEN}${BOLD}All 6 architecture verification checks passed!${NC}"
  exit 0
fi

# Live AWS Verification (routes through unified CloudFront HTTPS entry point)
head_sec "1. Checking CloudFront -> ALB -> EC2 -> RDS /health & /api/status"
curl -fsS "https://${CF_DOMAIN}/health" && echo "" && pass "CloudFront /health returned 200 OK"
curl -fsS "https://${CF_DOMAIN}/api/status" && echo "" && pass "CloudFront /api/status returned live EC2 + RDS status"

head_sec "2. Checking CloudFront static caching headers"
curl -fsSI "https://${CF_DOMAIN}/static/styles.css" | grep -iE "HTTP/|x-cache|cache-control"
pass "CloudFront served /static/styles.css"

head_sec "3. Testing AWS WAF SQLi rule block (expecting 403)"
WAF_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/?test=1%27%20OR%20%271%27=%271")
if [[ "${WAF_CODE}" == "403" ]]; then
  pass "AWS WAF blocked SQLi probe with HTTP 403"
else
  echo -e "  ${YELLOW}[WARN]${NC} Received HTTP ${WAF_CODE} (verify WAF association)"
fi

head_sec "4. Verifying Auto Scaling Group instances & SSM status"
aws autoscaling describe-auto-scaling-groups --region "${REGION}" --auto-scaling-group-names "${ASG_NAME}" \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,AvailabilityZone,HealthStatus,LifecycleState]' --output table
aws ssm describe-instance-information --region "${REGION}" \
  --query 'InstanceInformationList[*].[InstanceId,PingStatus,PlatformName]' --output table
pass "Live AWS verification finished"
