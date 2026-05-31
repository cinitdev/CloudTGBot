#!/usr/bin/env bash
# 执行实际的 SSH 部署 / 回滚
set -euo pipefail
. "$GITHUB_WORKSPACE/.github/scripts/common.sh"

JOB="$RUNNER_TEMP/job.json"
ACTION="$(jq -r .action "$JOB")"
SSH_HOST="$(jq -r .ssh.host "$JOB")"
SSH_PORT="$(jq -r '.ssh.port // 22' "$JOB")"
SSH_USER="$(jq -r .ssh.username "$JOB")"
SSH_AUTH="$(jq -r .ssh.auth_type "$JOB")"
SSH_CRED="$(jq -r .ssh.credential "$JOB")"
SERVICE_NAME="$(jq -r .service_name "$JOB")"

LOG_OUT="$RUNNER_TEMP/job.out"
: > "$LOG_OUT"

# 后台日志推送：每 1 秒把 LOG_OUT 增量行批量 POST 到 Worker
push_logs() {
  local last=0
  while true; do
    local total
    total=$(wc -l < "$LOG_OUT" 2>/dev/null || echo 0)
    if [ "$total" -gt "$last" ]; then
      local tmp
      tmp="$RUNNER_TEMP/log_batch.json"
      sed -n "$((last+1)),${total}p" "$LOG_OUT" \
        | jq -R -s -c 'split("\n") | map(select(length>0)) | {lines: map({ts: now|floor, level:"info", line:.})}' \
        > "$tmp"
      worker_request POST "/internal/jobs/${JOB_ID}/log" "$tmp" > /dev/null || true
      last=$total
    fi
    sleep 1
  done
}

push_logs &
PUSH_PID=$!
trap 'kill $PUSH_PID 2>/dev/null || true' EXIT

# 关闭命令回显，避免凭据被打到 logs
set +x

# 准备 SSH 连接参数
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$SSH_PORT")
if [ "$SSH_AUTH" = "privkey" ]; then
  KEY_FILE="$RUNNER_TEMP/ssh_key"
  printf '%s' "$SSH_CRED" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  SSH_CMD=(ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" "${SSH_USER}@${SSH_HOST}")
  SCP_CMD=(scp -P "$SSH_PORT" -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
else
  # password
  export SSHPASS="$SSH_CRED"
  SSH_CMD=(sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}")
  SCP_CMD=(sshpass -e scp -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
fi

case "$ACTION" in
  deploy)
    R2_KEY="$(jq -r .r2_key "$JOB")"
    PROJECT_TYPE="$(jq -r .project_type "$JOB")"
    CONFIG_INI="$(jq -r .config_ini "$JOB")"
    RENDERED="$(jq -c .rendered_config "$JOB")"

    PKG="$RUNNER_TEMP/pkg.zip"
    echo "[info] download package from worker" >> "$LOG_OUT"

    # 通过 internal 端点拉项目压缩包
    ts="$(date +%s)"
    nonce="$(random_nonce)"
    sig="$(sign_payload "${JOB_ID}.${ts}.${nonce}")"
    http_code=$(curl -sS -o "$PKG" -w '%{http_code}' \
      -H "X-Job-Signature: $sig" \
      -H "X-Job-Timestamp: $ts" \
      -H "X-Job-Nonce: $nonce" \
      "${WORKER_BASE%/}/internal/jobs/${JOB_ID}/package")
    if [ "$http_code" != "200" ]; then
      echo "[fatal] package download failed http=$http_code" >> "$LOG_OUT"
      exit 1
    fi

    CONFIG_FILENAME="$(printf '%s' "$CONFIG_INI" | awk -F= '/^CONFIG_FILENAME=/{print $2;exit}' | tr -d '\r' || true)"
    SCRIPT_FILENAME="$(printf '%s' "$CONFIG_INI" | awk -F= '/^SCRIPT_FILENAME=/{print $2;exit}' | tr -d '\r' || true)"
    : "${CONFIG_FILENAME:=config.json}"
    : "${SCRIPT_FILENAME:=app}"

    REMOTE_DIR="/opt/apps/${SERVICE_NAME}"
    REMOTE_TMP="/tmp/${JOB_ID}.zip"
    REMOTE_CFG="/tmp/${JOB_ID}.${CONFIG_FILENAME}"

    echo "[info] upload package + rendered config" >> "$LOG_OUT"
    "${SCP_CMD[@]}" "$PKG" "${SSH_USER}@${SSH_HOST}:${REMOTE_TMP}" >> "$LOG_OUT" 2>&1
    printf '%s' "$RENDERED" > "$RUNNER_TEMP/rendered.json"
    "${SCP_CMD[@]}" "$RUNNER_TEMP/rendered.json" "${SSH_USER}@${SSH_HOST}:${REMOTE_CFG}" >> "$LOG_OUT" 2>&1

    echo "[info] deploy on $SSH_HOST" >> "$LOG_OUT"
    "${SSH_CMD[@]}" "bash -s" \
      "$SERVICE_NAME" "$SCRIPT_FILENAME" "$CONFIG_FILENAME" "$REMOTE_TMP" "$REMOTE_CFG" \
      >> "$LOG_OUT" 2>&1 <<'REMOTE'
set -euo pipefail
SERVICE_NAME="$1"
SCRIPT_FILENAME="$2"
CONFIG_FILENAME="$3"
PKG="$4"
CFG="$5"

APP_DIR="/opt/apps/${SERVICE_NAME}"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# 部署前快照
if [ -d current ]; then
  rm -rf previous
  cp -a current previous
fi
mkdir -p current
cd current
unzip -o "$PKG" >/dev/null
chmod +x "./${SCRIPT_FILENAME}" 2>/dev/null || true
mv "$CFG" "./${CONFIG_FILENAME}"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" 2>/dev/null || true
systemctl restart "$SERVICE_NAME"

# 健康检查 30s
for i in $(seq 1 30); do
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    rm -f "$PKG" "$CFG" 2>/dev/null || true
    exit 0
  fi
  sleep 1
done
echo "[fatal] service did not become active in 30s"
exit 1
REMOTE
    ;;

  rollback)
    echo "[info] rollback on $SSH_HOST service=$SERVICE_NAME" >> "$LOG_OUT"
    "${SSH_CMD[@]}" "bash -s" >> "$LOG_OUT" 2>&1 <<EOF
set -euo pipefail
APP_DIR="/opt/apps/${SERVICE_NAME}"
cd "\$APP_DIR"
if [ ! -d previous ]; then
  echo "no previous version"
  exit 1
fi
rm -rf current.bak
mv current current.bak
mv previous current
mv current.bak previous
systemctl daemon-reload
systemctl restart "${SERVICE_NAME}"
sleep 2
systemctl is-active --quiet "${SERVICE_NAME}"
EOF
    ;;

  metrics)
    SERVER_ID="$(jq -r .server_id "$JOB")"
    echo "[info] collect metrics from $SSH_HOST" >> "$LOG_OUT"
    METRICS_RAW="$RUNNER_TEMP/metrics.raw"
    if "${SSH_CMD[@]}" "bash -s" > "$METRICS_RAW" 2>>"$LOG_OUT" <<'EOF'
set -euo pipefail
# CPU：1s 区间内 user+sys 增量
read -r _ a b c d _ < /proc/stat
sleep 1
read -r _ e f g h _ < /proc/stat
total_a=$((a+b+c+d)); total_b=$((e+f+g+h))
busy_a=$((a+b+c));    busy_b=$((e+f+g))
dt=$((total_b-total_a)); db=$((busy_b-busy_a))
cpu=0
if [ "$dt" -gt 0 ]; then cpu=$(awk -v db="$db" -v dt="$dt" 'BEGIN{printf "%.1f", db*100.0/dt}'); fi
# MEM
mem=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.1f", (t-a)*100.0/t}' /proc/meminfo)
# DISK：根分区已用百分比
disk=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5+0}')
# NET：默认接口 rx/tx 字节数（瞬时值，前端可计算速率）
iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
rx=0; tx=0
if [ -n "${iface:-}" ] && [ -d "/sys/class/net/$iface" ]; then
  rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes")
  tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes")
fi
printf '{"cpu_pct":%s,"mem_pct":%s,"disk_pct":%s,"net_rx_bps":%s,"net_tx_bps":%s,"online":true}\n' \
  "$cpu" "$mem" "$disk" "$rx" "$tx"
EOF
    then
      ONLINE=true
      DATA="$(cat "$METRICS_RAW")"
    else
      ONLINE=false
      DATA='{"cpu_pct":null,"mem_pct":null,"disk_pct":null,"net_rx_bps":null,"net_tx_bps":null,"online":false}'
      echo "[warn] ssh failed; reporting offline" >> "$LOG_OUT"
    fi

    BODY="$RUNNER_TEMP/metrics.json"
    jq -c --arg sid "$SERVER_ID" --argjson data "$DATA" \
      '{server_id:$sid, ts: (now|floor)} + $data' \
      <<<'{}' > "$BODY"
    worker_request POST "/internal/jobs/${JOB_ID}/metrics" "$BODY" > /dev/null
    [ "$ONLINE" = "true" ] || exit 1
    ;;

  *)
    echo "[fatal] unknown action: $ACTION" >> "$LOG_OUT"
    exit 2
    ;;
esac

sleep 2  # 让 push_logs 把最后一批日志推完
