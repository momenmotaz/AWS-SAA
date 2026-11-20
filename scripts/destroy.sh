#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CloudPulse Stack Teardown Script (Confirmed Terraform Destroy | --simulate)
# Usage:
#   ./scripts/destroy.sh --simulate
#   ./scripts/destroy.sh --region us-east-1 [--env prod] [--yes]
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
OUT_FILE="${ROOT_DIR}/.deployment-outputs.json"

REGION="us-east-1"
ENV="prod"
SIMULATE=false
AUTO_CONFIRM=false

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulate) SIMULATE=true; shift ;;
    --yes)      AUTO_CONFIRM=true; shift ;;
    --region)   REGION="$2"; shift 2 ;;
    --env)      ENV="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ./scripts/destroy.sh [--simulate | --region <region> --env <env> --yes]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo -e "${BOLD}======================================================================${NC}"
if [[ "$SIMULATE" == true ]]; then
  echo -e "${YELLOW}${BOLD}  CloudPulse — MOCK Teardown Simulation (NO AWS RESOURCES TOUCHED)${NC}"
else
  echo -e "${RED}${BOLD}  CloudPulse — LIVE AWS Resource Teardown (${REGION} / ${ENV})${NC}"
fi
echo -e "${BOLD}======================================================================${NC}"

if [[ "$SIMULATE" == true ]]; then
  echo -e "\n${BLUE}${BOLD}==> [SIMULATED] Reverse dependency teardown${NC}"
  for res in \
    "aws_route53_record.app_alias & health check" \
    "aws_cloudfront_distribution.web" \
    "aws_wafv2_web_acl_association.alb & aws_wafv2_web_acl.alb" \
    "aws_autoscaling_group.app & EC2 instances" \
    "aws_lb.app & Target Group" \
    "aws_db_instance.postgres (Multi-AZ Primary + Standby)" \
    "aws_s3_bucket.app_artifacts & aws_kms_key.cloudpulse" \
    "aws_nat_gateway.nat[0..1] & Elastic IPs" \
    "aws_cloudwatch_dashboard, alarms & SNS topic" \
    "aws_vpc.main, subnets, route tables, NACLs & Security Groups"; do
    echo -e "  ${YELLOW}[SIMULATED DESTROY]${NC} ${res}"
  done
  if [[ -f "${OUT_FILE}" ]] && [[ "$(jq -r '.mode // ""' "${OUT_FILE}")" == "simulated" ]]; then
    rm -f "${OUT_FILE}"
  fi
  echo -e "\n${YELLOW}${BOLD}Simulated teardown complete.${NC}"
  exit 0
fi

for cmd in aws terraform jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required." >&2; exit 1; }
done

aws sts get-caller-identity --output table

if [[ "$AUTO_CONFIRM" != true ]]; then
  read -r -p "Type 'DESTROY' to permanently delete all CloudPulse AWS resources in ${REGION}: " CONFIRM
  if [[ "$CONFIRM" != "DESTROY" ]]; then
    echo "Aborted by user."
    exit 1
  fi
fi

cd "${TF_DIR}"
terraform destroy -auto-approve -var="aws_region=${REGION}" -var="environment=${ENV}"
rm -f "${OUT_FILE}" "${TF_DIR}/tfplan"
echo -e "\n${GREEN}${BOLD}All live AWS resources destroyed cleanly.${NC}"
