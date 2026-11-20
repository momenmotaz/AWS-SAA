#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CloudPulse Stack Teardown Script (Real Terraform Destroy + --simulate)
# Usage:
#   ./scripts/destroy.sh --simulate
#   ./scripts/destroy.sh --region us-east-1
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
OUT_FILE="${ROOT_DIR}/.deployment-outputs.json"

REGION="us-east-1"
SIMULATE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulate|--dry-run) SIMULATE=true; shift ;;
    --region) REGION="$2"; shift 2 ;;
    -h|--help) sed -n '3,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -f "${OUT_FILE}" ]] && [[ "$(jq -r '.mode' "${OUT_FILE}")" == "simulated" ]]; then
  SIMULATE=true
fi

echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  CloudPulse — AWS Resource Teardown ($([[ "$SIMULATE" == true ]] && echo "SIMULATION" || echo "LIVE AWS"))${NC}"
echo -e "${BOLD}======================================================================${NC}"

if [[ "$SIMULATE" == true ]]; then
  echo -e "\n${BLUE}${BOLD}==> Tearing down simulated AWS resources in reverse dependency order${NC}"
  for res in \
    "aws_route53_record.app_alias & health check" \
    "aws_cloudfront_distribution.web" \
    "aws_wafv2_web_acl_association.alb & aws_wafv2_web_acl.alb" \
    "aws_autoscaling_group.app & EC2 instances (2/2 terminated)" \
    "aws_lb.app & Target Group" \
    "aws_db_instance.postgres (Multi-AZ Primary + Standby)" \
    "aws_nat_gateway.nat[0..1] & Elastic IPs (stopped hourly billing)" \
    "aws_cloudwatch_dashboard, alarms & SNS topic" \
    "aws_vpc.main, subnets, route tables, NACLs & Security Groups"; do
    sleep 0.15
    echo -e "  ${RED}[DESTROYED]${NC} ${res}"
  done
  rm -f "${OUT_FILE}"
  echo -e "\n${GREEN}${BOLD}Simulated teardown complete. Local state cleaned up.${NC}"
  exit 0
fi

cd "${TF_DIR}"
terraform destroy -auto-approve -var="aws_region=${REGION}"
rm -f "${OUT_FILE}"
echo -e "\n${GREEN}${BOLD}All live AWS resources destroyed cleanly.${NC}"
