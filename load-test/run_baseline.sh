#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  run_baseline.sh — Steady-state baseline (NO switchover)
#
#  Purpose: Measure clean p50/p99 against the BLUE environment
#  with zero switchover noise. Run this BEFORE the switchover test
#  to establish reference numbers.
#
#  Usage: cd load-test && ./run_baseline.sh
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_FILE="$RESULTS_DIR/baseline_${TIMESTAMP}.txt"
CSV_FILE="$RESULTS_DIR/baseline_${TIMESTAMP}.csv"

TARGET_URL="http://localhost/"
BLUE_DIRECT_URL="http://localhost:8105/"   # bypass Nginx — prewarm blue JVMs directly
THREADS=4
CONNECTIONS=50
DURATION=60    # 60s is enough for a clean baseline
RATE=50        # same rate as the switchover test
PREWARM_REQUESTS=100
PREWARM_PAUSE=0.1

mkdir -p "$RESULTS_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BASELINE (Blue only, no switchover) — $(date)"
echo "  Target : $TARGET_URL"
echo "  Rate   : ${RATE} req/s  |  Duration: ${DURATION}s"
echo "  Output : $RESULT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LOCAL_WRK2="${SCRIPT_DIR}/wrk2_bin"
if [ -x "$LOCAL_WRK2" ]; then
  WRK_CMD="$LOCAL_WRK2 -t${THREADS} -c${CONNECTIONS} -d${DURATION}s -R${RATE} --latency -s ${SCRIPT_DIR}/report.lua"
  echo "[INFO] Using local wrk2 binary: $LOCAL_WRK2"
elif command -v wrk2 &>/dev/null; then
  WRK_CMD="wrk2 -t${THREADS} -c${CONNECTIONS} -d${DURATION}s -R${RATE} --latency -s ${SCRIPT_DIR}/report.lua"
elif command -v wrk &>/dev/null; then
  WRK_CMD="wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION}s"
else
  echo "[ERROR] Neither wrk2 nor wrk found."
  exit 1
fi

# ── Wait for Nginx ─────────────────────────────────────────────────
echo "[$(date +%T)] Waiting for Nginx..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost/nginx-health" > /dev/null 2>&1; then
    echo "[$(date +%T)] Nginx ready."; break
  fi
  sleep 1
done

# ── Wait for Blue epsilon to be healthy (direct port) ──────────────
echo "[$(date +%T)] Waiting for Blue epsilon on :8105..."
for i in $(seq 1 30); do
  if curl -sf "${BLUE_DIRECT_URL}health" > /dev/null 2>&1; then
    echo "[$(date +%T)] Blue epsilon healthy (attempt $i)."
    break
  fi
  echo "[$(date +%T)]   Not ready yet ($i/30)..."
  sleep 1
done

# ── JIT Prewarm: fire real load at Blue before measuring ───────────
echo "[$(date +%T)] >>> JIT Prewarm: firing ${PREWARM_REQUESTS} requests at Blue (:8105)..."
for i in $(seq 1 "$PREWARM_REQUESTS"); do
  curl -sf "${BLUE_DIRECT_URL}" > /dev/null 2>&1 &
  if (( i % 10 == 0 )); then
    wait
    sleep "$PREWARM_PAUSE"
    echo "[$(date +%T)]   Burst $i/${PREWARM_REQUESTS} done..."
  fi
done
wait
echo "[$(date +%T)] JIT Prewarm complete. Blue JVMs are hot. Starting measurement..."

echo "[$(date +%T)] Running baseline at ${RATE} req/s for ${DURATION}s..."
$WRK_CMD "$TARGET_URL" > "$RESULT_FILE" 2>&1

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Baseline complete. Raw output: $RESULT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NON2XX=$(grep -oP 'Non-2xx or 3xx responses: \K[0-9]+' "$RESULT_FILE" || echo "0")
REQ_SEC=$(grep -oP 'Requests/sec:\s+\K[0-9.]+' "$RESULT_FILE" | head -1 || echo "N/A")
P50=$(grep -oP 'Latency p50\s+:\s+\K\S+' "$RESULT_FILE" || grep -oP '50\.000%\s+\K\S+' "$RESULT_FILE" || echo "N/A")
P99=$(grep -oP 'Latency p99\s+:\s+\K\S+' "$RESULT_FILE" || grep -oP '99%\s+\K\S+' "$RESULT_FILE" || echo "N/A")

echo "timestamp,non2xx_errors,requests_sec,latency_p50,latency_p99" > "$CSV_FILE"
echo "${TIMESTAMP},${NON2XX},${REQ_SEC},${P50},${P99}" >> "$CSV_FILE"

echo ""
echo "  BASELINE METRICS:"
echo "  ├─ Non-2xx errors : ${NON2XX}"
echo "  ├─ Throughput     : ${REQ_SEC} req/s"
echo "  ├─ Latency p50    : ${P50}  ← reference"
echo "  └─ Latency p99    : ${P99}  ← reference"
echo ""
echo "  CSV saved: $CSV_FILE"
echo ""
echo "  Next: run 'make load-test-prewarm' to see switchover impact vs this baseline."
