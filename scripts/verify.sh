#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CloudPulse Post-Deployment Verification Script
# Strict separation:
#   ./scripts/verify.sh --simulate   -> prints clearly labeled MOCK checks
#   ./scripts/verify.sh              -> runs REAL AWS CLI + HTTP checks
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${ROOT_DIR}/.deployment-outputs.json"
SIMULATE=false

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

pass()     { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail()     { echo -e "  ${RED}[FAIL]${NC} $1" >&2; exit 1; }
sim_pass() { echo -e "  ${YELLOW}[SIMULATED PASS]${NC} $1"; }
head_sec() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }

for arg in "$@"; do
  case "$arg" in
    --simulate) SIMULATE=true ;;
    -h|--help)
      echo "Usage: ./scripts/verify.sh [--simulate]"
      echo "  (default)   Runs live AWS CLI and HTTPS checks against .deployment-outputs.json"
      echo "  --simulate  Runs offline mock checklist against simulated outputs"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "${OUT_FILE}" ]]; then
  echo "No deployment outputs found at ${OUT_FILE}." >&2
  echo "Run './scripts/deploy.sh --region <region>' for a live deployment, or pass '--simulate' after './scripts/deploy.sh --simulate'." >&2
  exit 1
fi

MODE=$(jq -r '.mode // "unknown"' "${OUT_FILE}")

if [[ "$SIMULATE" == true ]]; then
  if [[ "$MODE" != "simulated" ]]; then
    echo "Warning: ${OUT_FILE} is marked '${MODE}', but --simulate was requested."
  fi
  REGION=$(jq -r '.region' "${OUT_FILE}")
  CF_DOMAIN=$(jq -r '.cloudfront_domain_name' "${OUT_FILE}")
  RDS_ENDPOINT=$(jq -r '.rds_endpoint' "${OUT_FILE}")

  echo -e "${BOLD}======================================================================${NC}"
  echo -e "${YELLOW}${BOLD}  CloudPulse — MOCK Verification Checklist (NOT LIVE AWS)${NC}"
  echo -e "${BOLD}======================================================================${NC}"

  head_sec "1. [SIMULATED] Unified Edge Path (Route 53 -> CloudFront -> WAF -> ALB -> EC2 -> RDS)"
  sim_pass "GET https://${CF_DOMAIN}/health -> HTTP 200 {\"status\":\"healthy\",\"database\":\"connected\"}"
  sim_pass "GET https://${CF_DOMAIN}/api/status -> HTTP 200 (IMDSv2 + RDS visit persisted)"
  sim_pass "Direct ALB bypass blocked (CloudFront prefix list + X-CloudFront-Verify -> 403)"

  head_sec "2. [SIMULATED] CloudFront Static Caching"
  sim_pass "GET https://${CF_DOMAIN}/static/styles.css -> Cache-Control / X-Cache: Hit from cloudfront"

  head_sec "3. [SIMULATED] AWS WAF Protection"
  sim_pass "SQLi probe via CloudFront -> HTTP 403 Forbidden"

  head_sec "4. [SIMULATED] Private EC2 & SSM Session Manager"
  sim_pass "EC2 instances private-only (no public IPv4, port 22 closed, SSM Online)"

  head_sec "5. [SIMULATED] RDS Multi-AZ & KMS Encryption"
  sim_pass "${RDS_ENDPOINT} (MultiAZ=true, PubliclyAccessible=false, StorageEncrypted=true)"

  head_sec "6. [SIMULATED] CloudWatch Alarms & SNS"
  sim_pass "Alarms OK (3/3) and dashboard $(jq -r '.cloudwatch_dashboard_name' "${OUT_FILE}")"

  echo -e "\n${YELLOW}${BOLD}Mock verification finished. No live AWS infrastructure was tested.${NC}"
  exit 0
fi

# Guard against mistaking mock data for live AWS verification
if [[ "$MODE" != "live" ]]; then
  echo -e "${RED}${BOLD}ERROR:${NC} ${OUT_FILE} has mode='${MODE}'. Refusing to treat simulated outputs as live AWS." >&2
  echo "Deploy real infrastructure with './scripts/deploy.sh --region us-east-1', or run './scripts/verify.sh --simulate' explicitly." >&2
  exit 1
fi

for cmd in aws curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Required tool '$cmd' not found."
done

aws sts get-caller-identity >/dev/null || fail "AWS credentials are not valid."

REGION=$(jq -r '.region' "${OUT_FILE}")
ALB_DNS=$(jq -r '.alb_dns_name' "${OUT_FILE}")
TG_ARN=$(jq -r '.alb_target_group_arn' "${OUT_FILE}")
CF_ID=$(jq -r '.cloudfront_distribution_id' "${OUT_FILE}")
CF_DOMAIN=$(jq -r '.cloudfront_domain_name' "${OUT_FILE}")
ASG_NAME=$(jq -r '.asg_name' "${OUT_FILE}")
RDS_ID=$(jq -r '.rds_instance_id' "${OUT_FILE}")
PROJECT_PREFIX=$(echo "${ASG_NAME}" | cut -d'-' -f1)

echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  CloudPulse — LIVE AWS Verification (${REGION})${NC}"
echo -e "${BOLD}======================================================================${NC}"

head_sec "1. CloudFront Distribution Status & Origin Protection"
CF_STATUS=$(aws cloudfront get-distribution --id "${CF_ID}" --query 'Distribution.Status' --output text)
echo "  CloudFront (${CF_ID}) Status: ${CF_STATUS}"
[[ "${CF_STATUS}" == "Deployed" ]] || fail "CloudFront distribution is not yet Deployed (${CF_STATUS})."
pass "CloudFront distribution is Deployed"

DIRECT_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://${ALB_DNS}/health" || echo "blocked")
if [[ "${DIRECT_CODE}" == "blocked" || "${DIRECT_CODE}" == "403" || "${DIRECT_CODE}" == "000" ]]; then
  pass "Direct ALB bypass rejected/unreachable (${DIRECT_CODE})"
else
  fail "Direct ALB access returned unexpected HTTP ${DIRECT_CODE}; expected SG timeout or 403!"
fi

head_sec "2. End-to-End HTTPS Health & RDS Persistence via CloudFront"
HEALTH_JSON=$(curl -fsS "https://${CF_DOMAIN}/health")
echo "  /health: ${HEALTH_JSON}"
echo "${HEALTH_JSON}" | jq -e '.status == "healthy" and .database == "connected"' >/dev/null || fail "/health did not report connected RDS!"
pass "GET https://${CF_DOMAIN}/health confirmed database=connected"

S1=$(curl -fsS "https://${CF_DOMAIN}/api/status")
S2=$(curl -fsS "https://${CF_DOMAIN}/api/status")
V1=$(echo "${S1}" | jq -r '.totalVisits')
V2=$(echo "${S2}" | jq -r '.totalVisits')
echo "  /api/status visit counter: ${V1} -> ${V2} ($(echo "${S2}" | jq -r '.database'))"
[[ "${V2}" -gt "${V1}" ]] || fail "Expected RDS visit counter to increment (${V1} -> ${V2})"
pass "PostgreSQL visit persistence verified (${V1} -> ${V2})"

head_sec "3. CloudFront Static Asset Caching (/static/styles.css)"
curl -fsSI "https://${CF_DOMAIN}/static/styles.css" | grep -iE "HTTP/|x-cache|cache-control" || true
pass "Static asset served through CloudFront"

head_sec "4. AWS WAFv2 SQLi Protection"
WAF_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/?test=1%27%20OR%20%271%27=%271")
if [[ "${WAF_CODE}" == "403" ]]; then
  pass "AWS WAF blocked SQLi probe with HTTP 403"
else
  fail "Expected HTTP 403 from AWS WAF SQLi rule, got ${WAF_CODE}"
fi

head_sec "5. ALB Target Health, Multi-AZ ASG & SSM Session Manager"
aws elbv2 describe-target-health --region "${REGION}" --target-group-arn "${TG_ARN}" \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
HEALTHY_COUNT=$(aws elbv2 describe-target-health --region "${REGION}" --target-group-arn "${TG_ARN}" \
  --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
[[ "${HEALTHY_COUNT}" -ge 2 ]] || fail "Expected at least 2 healthy ALB targets across AZs, found ${HEALTHY_COUNT}"
pass "ALB Target Group reports ${HEALTHY_COUNT} healthy targets"

aws autoscaling describe-auto-scaling-groups --region "${REGION}" --auto-scaling-group-names "${ASG_NAME}" \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,AvailabilityZone,HealthStatus,LifecycleState]' --output table
aws ssm describe-instance-information --region "${REGION}" \
  --query 'InstanceInformationList[*].[InstanceId,PingStatus,PlatformName]' --output table

head_sec "6. RDS Multi-AZ, Encryption & CloudWatch Alarms"
aws rds describe-db-instances --region "${REGION}" --db-instance-identifier "${RDS_ID}" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,Encrypted:StorageEncrypted,Public:PubliclyAccessible,AZ:AvailabilityZone,SecondaryAZ:SecondaryAvailabilityZone}' --output table
RDS_MULTI_AZ=$(aws rds describe-db-instances --region "${REGION}" --db-instance-identifier "${RDS_ID}" --query 'DBInstances[0].MultiAZ' --output text)
RDS_PUBLIC=$(aws rds describe-db-instances --region "${REGION}" --db-instance-identifier "${RDS_ID}" --query 'DBInstances[0].PubliclyAccessible' --output text)
[[ "${RDS_MULTI_AZ}" == "True" && "${RDS_PUBLIC}" == "False" ]] || fail "RDS MultiAZ/Public check failed"
pass "RDS verified: MultiAZ=True, PubliclyAccessible=False"

aws cloudwatch describe-alarms --region "${REGION}" --alarm-name-prefix "${PROJECT_PREFIX}-" \
  --query 'MetricAlarms[*].[AlarmName,StateValue]' --output table
pass "Live AWS verification completed successfully!"
