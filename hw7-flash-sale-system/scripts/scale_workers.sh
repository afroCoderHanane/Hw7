
#!/usr/bin/env bash
# Scale worker capacity for the Flash Sale system.
# Supports:
#   1) ECS service desired count
#   2) EC2 Auto Scaling Group desired capacity
#
# Examples:
#   ECS: ./scale_workers.sh -m ecs -c flash-sale-cluster -s worker-service -d 50 -r us-west-2 --wait
#   ASG: ./scale_workers.sh -m asg -g flash-sale-worker-asg -d 20 -n 10 -x 40 -r us-west-2 --wait
#
# Requirements: awscli v2 configured with credentials/region.

set -euo pipefail

MODE=""
AWS_REGION="${AWS_REGION:-}"
CLUSTER=""
SERVICE=""
ASG_NAME=""
DESIRED=""
MIN_SIZE=""
MAX_SIZE=""
WAIT=false

usage() {
  cat >&2 <<USAGE
Usage: $0 -m <ecs|asg> [-r <aws-region>] [ecs: -c <cluster> -s <service>] [asg: -g <asg-name>] -d <desired> [-n <min>] [-x <max>] [--wait]

Options:
  -m   Mode: ecs | asg
  -r   AWS region (overrides configured default)

ECS options:
  -c   ECS cluster name/arn
  -s   ECS service name

ASG options:
  -g   Auto Scaling Group name
  -n   Min size (optional, ASG only)
  -x   Max size (optional, ASG only)

Common:
  -d   Desired count/capacity (required)
  --wait  Wait until scaling reaches a stable state

Examples:
  $0 -m ecs -c flash-sale -s worker-svc -d 25 -r us-west-2 --wait
  $0 -m asg -g worker-asg -d 50 -n 10 -x 100 --wait
USAGE
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Required binary not found: $1" >&2; exit 1; }
}

parse_args() {
  # Support long flag --wait
  LONG_WAIT=false
  while (( "$#" )); do
    case "$1" in
      --wait) WAIT=true; shift ;;
      -m) MODE="$2"; shift 2 ;;
      -r) AWS_REGION="$2"; shift 2 ;;
      -c) CLUSTER="$2"; shift 2 ;;
      -s) SERVICE="$2"; shift 2 ;;
      -g) ASG_NAME="$2"; shift 2 ;;
      -d) DESIRED="$2"; shift 2 ;;
      -n) MIN_SIZE="$2"; shift 2 ;;
      -x) MAX_SIZE="$2"; shift 2 ;;
      -h|--help) usage ;;
      --) shift; break ;;
      -*) echo "Unknown option: $1" >&2; usage ;;
      *) break ;;
    esac
  done
}

validate() {
  [[ -z "$MODE" ]] && usage
  [[ -z "$DESIRED" ]] && { echo "❌ -d <desired> is required" >&2; usage; }
  if [[ "$MODE" == "ecs" ]]; then
    [[ -z "$CLUSTER" || -z "$SERVICE" ]] && { echo "❌ ECS mode requires -c <cluster> and -s <service>" >&2; usage; }
  elif [[ "$MODE" == "asg" ]]; then
    [[ -z "$ASG_NAME" ]] && { echo "❌ ASG mode requires -g <asg-name>" >&2; usage; }
  else
    echo "❌ Unknown mode: $MODE" >&2; usage
  fi
}

resolve_region() {
  if [[ -z "${AWS_REGION}" ]]; then
    AWS_REGION=$(aws configure get region || true)
  fi
  if [[ -z "${AWS_REGION}" ]]; then
    echo "❌ AWS region not set. Pass -r or set AWS_REGION or configure a default with 'aws configure'." >&2
    exit 1
  fi
}

scale_ecs() {
  echo "➡️  Updating ECS service desired count to ${DESIRED} (cluster=${CLUSTER}, service=${SERVICE}, region=${AWS_REGION})"
  aws ecs update-service \
    --region "${AWS_REGION}" \
    --cluster "${CLUSTER}" \
    --service "${SERVICE}" \
    --desired-count "${DESIRED}" >/dev/null

  if $WAIT; then
    echo "⏳ Waiting for ECS service to become stable..."
    aws ecs wait services-stable --region "${AWS_REGION}" --cluster "${CLUSTER}" --services "${SERVICE}"
    echo "✅ ECS service is stable."
  fi
}

scale_asg() {
  local args=(--auto-scaling-group-name "${ASG_NAME}" --desired-capacity "${DESIRED}")
  [[ -n "${MIN_SIZE}" ]] && args+=(--min-size "${MIN_SIZE}")
  [[ -n "${MAX_SIZE}" ]] && args+=(--max-size "${MAX_SIZE}")

  echo "➡️  Updating ASG capacity (asg=${ASG_NAME}, desired=${DESIRED}, min=${MIN_SIZE:-keep}, max=${MAX_SIZE:-keep}, region=${AWS_REGION})"
  aws autoscaling update-auto-scaling-group --region "${AWS_REGION}" "${args[@]}"

  if $WAIT; then
    echo "⏳ Waiting for ASG to reach desired capacity..."
    # Poll until desired == InService instances
    for i in {1..60}; do
      read -r desired in_service < <(aws autoscaling describe-auto-scaling-groups \
        --region "${AWS_REGION}" \
        --auto-scaling-group-names "${ASG_NAME}" \
        --query 'AutoScalingGroups[0].[DesiredCapacity, length(Instances[?LifecycleState==`InService`])]' \
        --output text)
      echo "   • desired=${desired} in_service=${in_service}"
      if [[ "${desired}" == "${in_service}" && "${desired}" == "${DESIRED}" ]]; then
        echo "✅ ASG reached desired InService capacity."
        return 0
      fi
      sleep 10
    done
    echo "⚠️  Timed out waiting for ASG to reach desired capacity." >&2
    exit 2
  fi
}

main() {
  require_bin aws
  parse_args "$@"
  validate
  resolve_region

  case "$MODE" in
    ecs) scale_ecs ;;
    asg) scale_asg ;;
  esac
}

main "$@"