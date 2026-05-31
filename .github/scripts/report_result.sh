#!/usr/bin/env bash
# 把最终结果回报 Worker；OUTCOME=success 或 failure
set -euo pipefail
. "$GITHUB_WORKSPACE/.github/scripts/common.sh"

LOG_OUT="$RUNNER_TEMP/job.out"

# 推完最后剩下的日志（不分批，简单全推）
if [ -f "$LOG_OUT" ]; then
  tmp="$RUNNER_TEMP/log_final.json"
  jq -R -s -c 'split("\n") | map(select(length>0))[-200:] | {lines: map({ts: now|floor, level:"info", line:.})}' \
    < "$LOG_OUT" > "$tmp" || echo '{"lines":[]}' > "$tmp"
  worker_request POST "/internal/jobs/${JOB_ID}/log" "$tmp" > /dev/null || true
fi

case "${OUTCOME:-failure}" in
  success) status="success" ;;
  *)       status="failed"  ;;
esac

body="$RUNNER_TEMP/result.json"
printf '{"status":"%s"}' "$status" > "$body"
worker_request POST "/internal/jobs/${JOB_ID}/result" "$body" > /dev/null || true
echo "reported status=$status"
