#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CloudPulse Elasticity & RDS Multi-AZ Failover Load Test
# Usage:
#   ./scripts/simulate-load.sh --simulate
#   ./scripts/simulate-load.sh [--url https://<cloudfront-domain>/api/status] [--requests 200]
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${ROOT_DIR}/.deployment-outputs.json"
SIMULATE=false
TARGET_URL=""
REQUESTS=200

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulate) SIMULATE=true; shift ;;
    --url)      TARGET_URL="$2"; shift 2 ;;
    --requests) REQUESTS="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ./scripts/simulate-load.sh [--simulate | --url <https-url> --requests N]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo -e "${BOLD}======================================================================${NC}"
if [[ "$SIMULATE" == true ]]; then
  echo -e "${YELLOW}${BOLD}  CloudPulse — MOCK Scaling & Failover Walkthrough (NOT LIVE AWS)${NC}"
else
  echo -e "${BOLD}  CloudPulse — Live HTTP Concurrency Test${NC}"
fi
echo -e "${BOLD}======================================================================${NC}"

if [[ "$SIMULATE" == true ]]; then
  echo -e "\n${BLUE}${BOLD}==> [SIMULATED] Phase 1: Traffic Surge & ASG Target-Tracking Scale-Out${NC}"
  echo -e "  ${CYAN}[T+00s]${NC} Baseline: 2 EC2 instances (us-east-1a, us-east-1b) | Avg CPU: 18%"
  echo -e "  ${YELLOW}[T+30s]${NC} Load surge hitting CloudFront -> WAF -> ALB | Avg CPU: 78% (target: 60%)"
  echo -e "  ${YELLOW}[T+60s]${NC} CloudWatch Alarm 'cloudpulse-ec2-high-cpu' -> ALARM | SNS email sent"
  echo -e "  ${GREEN}[T+90s]${NC} ASG TargetTracking + StepScaling launches 2 additional private EC2 instances"
  echo -e "  ${GREEN}[T+140s]${NC} Capacity: 4/4 healthy | Avg CPU stabilized at 41%"

  echo -e "\n${BLUE}${BOLD}==> [SIMULATED] Phase 2: RDS Multi-AZ Automated Failover${NC}"
  echo -e "  ${CYAN}[T+00s]${NC} RebootWithFailover initiated on Primary RDS (us-east-1a)"
  echo -e "  ${YELLOW}[T+18s]${NC} Synchronous Standby in us-east-1b promoted to Primary"
  echo -e "  ${GREEN}[T+41s]${NC} Endpoint restored automatically (RPO=0)"

  echo -e "\n${BLUE}${BOLD}==> [SIMULATED] Phase 3: Cool-Down & Scale-In${NC}"
  echo -e "  ${GREEN}[T+300s]${NC} ASG drains & terminates excess instances back to desired=2"
  exit 0
fi

if [[ -z "${TARGET_URL}" ]]; then
  [[ -f "${OUT_FILE}" ]] || { echo "Provide --url or deploy live infrastructure first." >&2; exit 1; }
  MODE=$(jq -r '.mode // "unknown"' "${OUT_FILE}")
  [[ "$MODE" == "live" ]] || { echo -e "${RED}ERROR:${NC} ${OUT_FILE} is '${MODE}'. Use --simulate for mock output or deploy live first." >&2; exit 1; }
  TARGET_URL="https://$(jq -r '.cloudfront_domain_name' "${OUT_FILE}")/api/status"
fi

echo "Sending ${REQUESTS} concurrent HTTPS requests to ${TARGET_URL} (WAF allows up to 2,000 req / 5 min per IP)..."
seq 1 "${REQUESTS}" | xargs -P 20 -I{} curl -s -o /dev/null -w "%{http_code}\n" "${TARGET_URL}" | sort | uniq -c
