#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  run_wrk2.sh — Load test harness for blue-green switchover
#
#  What it does:
#    1. Runs wrk2 continuously against http://localhost/ (through Nginx)
#    2. Triggers the Ansible deploy playbook mid-test
#    3. Saves timestamped raw output + a summary CSV for Layer 2 analysis
#
#  Prerequisites: wrk2 installed (see README.md)
#  Usage: cd load-test && ./run_wrk2.sh
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$SCRIPT_DIR/results"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_FILE="$RESULTS_DIR/run_${TIMESTAMP}.txt"
CSV_FILE="$RESULTS_DIR/run_${TIMESTAMP}.csv"

# ── wrk2 parameters ───────────────────────────────────────────────
TARGET_URL="http://localhost/"
THREADS=4
CONNECTIONS=50
DURATION=90           # total test duration in seconds
RATE=200              # requests per second (constant rate — wrk2's key feature)
SWITCHOVER_DELAY=20   # seconds after test start before triggering switchover

mkdir -p "$RESULTS_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Blue-Green Load Test — $(date)"
echo "  Target : $TARGET_URL"
echo "  Rate   : ${RATE} req/s  |  Duration: ${DURATION}s"
echo "  Output : $RESULT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check wrk2 is available (local binary first, then PATH)
LOCAL_WRK2="${SCRIPT_DIR}/wrk2_bin"
if [ -x "$LOCAL_WRK2" ]; then
  WRK_CMD="$LOCAL_WRK2 -t${THREADS} -c${CONNECTIONS} -d${DURATION}s -R${RATE} --latency -s ${SCRIPT_DIR}/report.lua"
  echo "[INFO] Using local wrk2 binary: $LOCAL_WRK2"
elif command -v wrk2 &>/dev/null; then
  WRK_CMD="wrk2 -t${THREADS} -c${CONNECTIONS} -d${DURATION}s -R${RATE} --latency -s ${SCRIPT_DIR}/report.lua"
elif command -v wrk &>/dev/null; then
  echo "[FALLBACK] wrk2 not found. Using wrk (no constant rate)..."
  WRK_CMD="wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION}s"
else
  echo "[ERROR] Neither wrk2 nor wrk found. See README for install instructions."
  exit 1
fi

# ── Wait for Nginx to be ready before starting ────────────────────
# Use /nginx-health (always 200 from Nginx itself, no upstream needed)
NGINX_READY=0
echo "[$(date +%T)] Waiting for Nginx to be ready..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost/nginx-health" > /dev/null 2>&1; then
    echo "[$(date +%T)] Nginx is ready (attempt $i)."
    NGINX_READY=1
    break
  fi
  echo "[$(date +%T)] Not ready yet (attempt $i/30), retrying in 1s..."
  sleep 1
done

if [ "$NGINX_READY" -eq 0 ]; then
  echo "[ERROR] Nginx did not become ready after 30s. Run 'make init' first."
  exit 1
fi

# ── Start load test in background ─────────────────────────────────
echo "[$(date +%T)] Starting load test..."
$WRK_CMD "$TARGET_URL" > "$RESULT_FILE" 2>&1 &
WRK_PID=$!
echo "[$(date +%T)] wrk PID: $WRK_PID"

# ── Wait, then trigger switchover ─────────────────────────────────
echo "[$(date +%T)] Waiting ${SWITCHOVER_DELAY}s before triggering switchover..."
sleep "$SWITCHOVER_DELAY"

SWITCHOVER_START=$(date +%s%3N)   # milliseconds
echo "[$(date +%T)] >>> Triggering blue→green switchover (Ansible)"
ansible-playbook \
  -i "${PROJECT_ROOT}/ansible/inventory/hosts.ini" \
  "${PROJECT_ROOT}/ansible/deploy.yml" \
  2>&1 | tee -a "$RESULT_FILE"
SWITCHOVER_END=$(date +%s%3N)

SWITCHOVER_DURATION_MS=$(( SWITCHOVER_END - SWITCHOVER_START ))
echo "[$(date +%T)] Switchover completed in ${SWITCHOVER_DURATION_MS}ms"

# ── Wait for wrk to finish ─────────────────────────────────────────
echo "[$(date +%T)] Waiting for load test to complete..."
wait "$WRK_PID" || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Load test complete."
echo "  Raw output : $RESULT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Parse key metrics from wrk output → CSV ───────────────────────
echo "timestamp,switchover_duration_ms,non2xx_errors,requests_sec,latency_p50,latency_p99" > "$CSV_FILE"

NON2XX=$(grep -oP 'Non-2xx or 3xx responses: \K[0-9]+' "$RESULT_FILE" || echo "0")
REQ_SEC=$(grep -oP 'Requests/sec:\s+\K[0-9.]+' "$RESULT_FILE" | head -1 || echo "N/A")
P50=$(grep -oP 'Latency p50\s+:\s+\K\S+' "$RESULT_FILE" || grep -oP '50\.000%\s+\K\S+' "$RESULT_FILE" || echo "N/A")
P99=$(grep -oP 'Latency p99\s+:\s+\K\S+' "$RESULT_FILE" || grep -oP '99%\s+\K\S+' "$RESULT_FILE" || echo "N/A")

echo "${TIMESTAMP},${SWITCHOVER_DURATION_MS},${NON2XX},${REQ_SEC},${P50},${P99}" >> "$CSV_FILE"

echo ""
echo "  KEY METRICS:"
echo "  ├─ Switchover duration : ${SWITCHOVER_DURATION_MS}ms"
echo "  ├─ Non-2xx errors      : ${NON2XX}"
echo "  ├─ Throughput          : ${REQ_SEC} req/s"
echo "  ├─ Latency p50         : ${P50}"
echo "  └─ Latency p99         : ${P99}"
echo ""
echo "  CSV saved: $CSV_FILE"
