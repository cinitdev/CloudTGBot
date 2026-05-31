#!/usr/bin/env bash
# 拉取部署参数到 $RUNNER_TEMP/job.json
set -euo pipefail
. "$GITHUB_WORKSPACE/.github/scripts/common.sh"

OUT="$RUNNER_TEMP/job.json"
HTTP_CODE_FILE="$RUNNER_TEMP/job.http.code"

set +x
ts="$(date +%s)"
nonce="$(random_nonce)"
sig="$(sign_payload "${JOB_ID}.${ts}.${nonce}")"
http_code=$(curl -sS -o "$OUT" -w '%{http_code}' \
  -H "X-Job-Signature: $sig" \
  -H "X-Job-Timestamp: $ts" \
  -H "X-Job-Nonce: $nonce" \
  -H "X-GitHub-Run-Id: ${GH_RUN_ID:-}" \
  "${WORKER_BASE%/}/internal/jobs/${JOB_ID}")
echo "$http_code" > "$HTTP_CODE_FILE"

if [ "$http_code" != "200" ]; then
  echo "::error::fetch_job failed http=$http_code"
  cat "$OUT" >&2 || true
  exit 1
fi

# 基本健康校验
if ! jq -e .ssh.host "$OUT" > /dev/null; then
  echo "::error::malformed job payload"
  exit 1
fi

chmod 600 "$OUT"
echo "fetched job_id=$JOB_ID action=$(jq -r .action "$OUT")"
