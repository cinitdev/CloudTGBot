#!/usr/bin/env bash
# 共用：算 HMAC、签名调用 Worker
set -euo pipefail

: "${WORKER_BASE:?}"
: "${ACTIONS_HMAC_SECRET:?}"
: "${JOB_ID:?}"

# 输出 hex 形式 HMAC-SHA256
sign_payload() {
  local data="$1"
  printf '%s' "$data" | openssl dgst -sha256 -hmac "$ACTIONS_HMAC_SECRET" | awk '{print $2}'
}

random_nonce() {
  openssl rand -hex 16
}

# 用法：worker_request METHOD PATH [BODY_FILE]
worker_request() {
  local method="$1"
  local path="$2"
  local body_file="${3:-}"
  local ts nonce sig
  ts="$(date +%s)"
  nonce="$(random_nonce)"
  sig="$(sign_payload "${JOB_ID}.${ts}.${nonce}")"

  local args=(
    -sS
    -X "$method"
    -H "X-Job-Signature: $sig"
    -H "X-Job-Timestamp: $ts"
    -H "X-Job-Nonce: $nonce"
    -H "X-GitHub-Run-Id: ${GH_RUN_ID:-}"
    -H "Content-Type: application/json"
  )
  if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    args+=(--data-binary "@$body_file")
  fi
  curl "${args[@]}" "${WORKER_BASE%/}${path}"
}

export -f sign_payload random_nonce worker_request
