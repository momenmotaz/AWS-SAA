#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CloudPulse Elasticity & RDS Multi-AZ Failover Simulator
# Usage:
#   ./scripts/simulate-load.sh --simulate
#   ./scripts/simulate-load.sh --url http://<alb-dns> --requests 500
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${ROOT_DIR}/.deployment-outputs.json"
SIMULATE=false
TARGET_URL=""
REQUESTS=200

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulate|--dry-run) SIMULATE=true; shift ;;
    --url)      TARGET_URL="$2"; shift 2 ;;
    --requests) REQUESTS="$2"; shift 2 ;;
    -h|--help)  sed -n '3,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -f "${OUT_FILE}" ]] && [[ "$(jq -r '.mode' "${OUT_FILE}")" == "simulated" ]]; then
  SIMULATE=true
fi

echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  CloudPulse — Auto Scaling & Multi-AZ Failover Exercise${NC}"
echo -e "${BOLD}======================================================================${NC}"

if [[ "$SIMULATE" == true ]]; then
  echo -e "\n${BLUE}${BOLD}==> Phase 1: Traffic Surge & ASG Target-Tracking Scale-Out${NC}"
  sleep 0.3
  echo -e "  ${CYAN}[T+00s]${NC} Baseline: 2 EC2 instances (us-east-1a, us-east-1b) | Avg CPU: 18% | ALB p95: 24ms"
  sleep 0.3
  echo -e "  ${YELLOW}[T+30s]${NC} Load surge: 1,450 req/s hitting CloudFront -> WAF -> ALB | Avg CPU: 78% (threshold: 60%)"
  sleep 0.3
  echo -e "  ${YELLOW}[T+60s]${NC} CloudWatch Alarm 'cloudpulse-ec2-high-cpu' -> ALARM | SNS alert emailed to Ops"
  sleep 0.3
  echo -e "  ${GREEN}[T+90s]${NC} ASG TargetTracking + StepScaling launched 2 new EC2 instances:"
  echo -e "           + i-07d2e4f6a8b0c1234 (us-east-1a, 10.0.11.73) -> Healthy"
  echo -e "           + i-08e3f5a7b9c1d5678 (us-east-1b, 10.0.12.91) -> Healthy"
  sleep 0.3
  echo -e "  ${GREEN}[T+140s]${NC} Capacity: 4/4 healthy | Avg CPU stabilized at 41% | ALB p95: 29ms | 5xx: 0"

  echo -e "\n${BLUE}${BOLD}==> Phase 2: RDS Multi-AZ Automated Failover Test${NC}"
  sleep 0.3
  echo -e "  ${CYAN}[T+00s]${NC} Initiating RebootWithFailover on Primary RDS (us-east-1a)..."
  sleep 0.3
  echo -e "  ${YELLOW}[T+18s]${NC} Promoting synchronous Standby in us-east-1b to Primary..."
  sleep 0.3
  echo -e "  ${GREEN}[T+41s]${NC} DNS CNAME updated automatically -> same RDS endpoint restored!"
  echo -e "           Primary is now in us-east-1b | Standby rebuilding in us-east-1a | Zero data loss (RPO=0)"

  echo -e "\n${BLUE}${BOLD}==> Phase 3: Cool-Down & Scale-In${NC}"
  sleep 0.3
  echo -e "  ${GREEN}[T+300s]${NC} Load subsided (Avg CPU: 14%) -> ASG gracefully drained & terminated 2 instances (desired=2)"
  echo -e "  ${GREEN}[DONE]${NC}   Elasticity & Multi-AZ resilience simulation completed."
  exit 0
fi

if [[ -z "${TARGET_URL}" ]] && [[ -f "${OUT_FILE}" ]]; then
  TARGET_URL="http://$(jq -r '.alb_dns_name' "${OUT_FILE}")/api/status"
fi

if [[ -z "${TARGET_URL}" ]]; then
  echo "Provide --url http://<alb-dns>/api/status or run with --simulate." >&2
  exit 1
fi

echo "Sending ${REQUESTS} concurrent test requests to ${TARGET_URL}..."
seq 1 "${REQUESTS}" | xargs -P 20 -I{} curl -s -o /dev/null -w "%{http_code}\n" "${TARGET_URL}" | sort | uniq -c
