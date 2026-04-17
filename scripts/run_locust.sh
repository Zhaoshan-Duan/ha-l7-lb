#!/usr/bin/env bash
# Drive a single Locust run on the AWS-hosted load generator via SSM.
#
# Usage:
#   ./scripts/run_locust.sh <run_id> <user_class> <users> <duration_min> [spawn_rate]
#
# Examples:
#   ./scripts/run_locust.sh exp1/weighted_hetero_500u AlgorithmCompareUser 500 5
#   ./scripts/run_locust.sh exp2/retry_on_100u       ChaosInjectionUser   100 5
#   ./scripts/run_locust.sh exp3/lb1_2000u_spike     ScalingSpikeUser     2000 3
#
# Assumes:
#   - terraform outputs available (locust_instance_id, nlb_dns_name, locust_results_bucket)
#   - AWS credentials configured
#   - Locust EC2 bootstrapped (SSM agent up, locust installed)
#
# Waits for the command to complete, streams a brief summary, and
# returns 0 on Locust success, non-zero otherwise.

set -euo pipefail

RUN_ID="${1:?run_id required (e.g. exp1/weighted_hetero_500u)}"
USER_CLASS="${2:?user class required}"
USERS="${3:?user count required}"
DURATION_MIN="${4:?duration in minutes required}"
SPAWN_RATE="${5:-$((USERS / 10))}"

cd "$(dirname "$0")/../terraform"

INSTANCE_ID=$(terraform output -raw locust_instance_id)
NLB_DNS=$(terraform output -raw nlb_dns_name)
BUCKET=$(terraform output -raw locust_results_bucket)
REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")

# Sanitize RUN_ID for use as a filename prefix (replace '/' with '_').
RUN_SLUG="${RUN_ID//\//_}"
S3_PREFIX="s3://${BUCKET}/${RUN_ID}"

echo "[run_locust] $RUN_ID -> nlb=$NLB_DNS users=$USERS rate=$SPAWN_RATE dur=${DURATION_MIN}m"

CMD=$(cat <<EOF
set -euo pipefail
cd /opt/locust
rm -f run-*.csv run-*.html
locust --headless \\
  -u $USERS -r $SPAWN_RATE -t ${DURATION_MIN}m \\
  --host http://${NLB_DNS} \\
  --csv run-${RUN_SLUG} \\
  --html run-${RUN_SLUG}.html \\
  --only-summary \\
  ${USER_CLASS}
aws s3 cp run-${RUN_SLUG}_stats.csv         ${S3_PREFIX}/stats.csv
aws s3 cp run-${RUN_SLUG}_stats_history.csv ${S3_PREFIX}/stats_history.csv
aws s3 cp run-${RUN_SLUG}_failures.csv      ${S3_PREFIX}/failures.csv
aws s3 cp run-${RUN_SLUG}.html              ${S3_PREFIX}/report.html
EOF
)

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "$RUN_ID" \
  --cloud-watch-output-config CloudWatchOutputEnabled=true \
  --parameters "commands=[$(jq -Rs . <<< "$CMD")]" \
  --query "Command.CommandId" --output text)

echo "[run_locust] SSM command id: $CMD_ID"
echo "[run_locust] polling every 10s..."

# Poll until the command finishes. Locust run itself is DURATION_MIN minutes.
for _ in $(seq 1 $((DURATION_MIN * 6 + 30))); do
  STATUS=$(aws ssm list-command-invocations \
    --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" \
    --output text 2>/dev/null || echo "Pending")

  case "$STATUS" in
    Success)
      echo "[run_locust] completed: $RUN_ID"
      exit 0
      ;;
    Cancelled|TimedOut|Failed)
      echo "[run_locust] failed: $STATUS"
      aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardErrorContent" --output text
      exit 1
      ;;
  esac
  sleep 10
done

echo "[run_locust] timeout waiting for command"
exit 2
