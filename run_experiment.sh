#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  run_experiment.sh  —  Full 30-trial Blue-Green experiment + Math Modelling
#
#  What this does (end to end):
#    1.  Checks prerequisites (Docker, wrk2, Python3, Ansible)
#    2.  Brings up a clean BLUE environment  (make init)
#    3.  Runs N=30 switchover trials, each:
#          a. Pre-warm GREEN JVMs (100 direct HTTP requests)
#          b. Run wrk2 at 50 req/s for 180s with mid-flight blue→green switch
#          c. Parse results into CSV
#          d. Rollback to BLUE for next trial
#    4.  Aggregates all CSVs → master_results.csv
#    5.  Runs analyse.py → 4 CDF/downtime plots + console summary
#
#  Estimated runtime:  ~2.5 hours  (30 × ~5 min/trial)
#  Usage:
#    cd /home/udit/SummerProject
#    bash run_experiment.sh
#    bash run_experiment.sh --trials 5      # quick smoke test
#    bash run_experiment.sh --skip-trials   # modelling only (use existing CSVs)
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_TEST_DIR="$PROJECT_ROOT/load-test"
RESULTS_DIR="$LOAD_TEST_DIR/results"
MATH_DIR="$PROJECT_ROOT/math-models"
LOG_FILE="$PROJECT_ROOT/experiment_run.log"

N_TRIALS=30
SKIP_TRIALS=false
TRIAL_DURATION=180      # wrk2 duration per trial (s)
SWITCHOVER_DELAY=60     # seconds before triggering switchover inside trial
RATE=50                 # req/s
CONNECTIONS=50
THREADS=4
GREEN_PREWARM_URL="http://localhost:8205/"
PREWARM_REQUESTS=100
PREWARM_PAUSE=0.1
TARGET_URL="http://localhost/"

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --trials)   N_TRIALS="$2"; shift 2 ;;
    --skip-trials) SKIP_TRIALS=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

log() { echo -e "$@" | tee -a "$LOG_FILE"; }

# ── Banner ────────────────────────────────────────────────────────────────────
clear
log "${BOLD}${CYAN}"
log "╔══════════════════════════════════════════════════════════════╗"
log "║   Blue-Green Deployment — Full 30-Trial Experiment           ║"
log "║   M/M/c Queueing Mathematical Model                         ║"
log "╚══════════════════════════════════════════════════════════════╝${NC}"
log ""
log "  Project root : $PROJECT_ROOT"
log "  Trials       : $N_TRIALS"
log "  Rate         : ${RATE} req/s  |  Duration: ${TRIAL_DURATION}s/trial"
log "  Est. runtime : $(( N_TRIALS * 5 )) min  (~$N_TRIALS × 5 min/trial)"
log "  Log file     : $LOG_FILE"
log "  Started      : $(date)"
log ""

# ── Step 0: Prerequisites ─────────────────────────────────────────────────────
log "${BOLD}[STEP 0/4] Checking prerequisites...${NC}"

fail() { log "${RED}  ✗ $1${NC}"; exit 1; }
ok()   { log "${GREEN}  ✓ $1${NC}"; }

command -v docker      >/dev/null 2>&1 && ok "docker"         || fail "docker not found"
command -v ansible-playbook >/dev/null 2>&1 && ok "ansible"   || fail "ansible-playbook not found"
command -v python3     >/dev/null 2>&1 && ok "python3"        || fail "python3 not found"

# wrk2 binary (local preferred)
LOCAL_WRK2="$LOAD_TEST_DIR/wrk2_bin"
if [[ -x "$LOCAL_WRK2" ]]; then
  WRK_CMD="$LOCAL_WRK2"
  ok "wrk2 (local binary)"
elif command -v wrk2 >/dev/null 2>&1; then
  WRK_CMD="wrk2"
  ok "wrk2 (system)"
else
  fail "wrk2 not found. Build it or place binary at load-test/wrk2_bin"
fi

# Python deps
python3 -c "import numpy, scipy, matplotlib" 2>/dev/null \
  && ok "python deps (numpy/scipy/matplotlib)" \
  || { log "  Installing python deps..."; pip3 install numpy scipy matplotlib --quiet --break-system-packages && ok "python deps installed"; }

mkdir -p "$RESULTS_DIR" "$MATH_DIR/figures"
log ""

# ══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_TRIALS" == "false" ]]; then

# ── Step 1: Environment setup ─────────────────────────────────────────────────
log "${BOLD}[STEP 1/4] Starting BLUE environment...${NC}"
cd "$PROJECT_ROOT"

# Stop any stale green
docker compose --profile green stop 2>/dev/null || true
# Ensure nginx is up and blue is running
docker compose up -d nginx
docker compose --profile blue up -d --build
log "  Waiting 30s for Blue JVMs to warm up..."
sleep 30

# Verify nginx health
for i in $(seq 1 20); do
  if curl -sf "http://localhost/nginx-health" >/dev/null 2>&1; then
    ok "Nginx is healthy"; break
  fi
  [[ $i -eq 20 ]] && fail "Nginx not ready after 20s — run 'make init' manually"
  sleep 1
done
log ""

# ── Step 2: 30 trials ─────────────────────────────────────────────────────────
log "${BOLD}[STEP 2/4] Running $N_TRIALS trials...${NC}"
log "  Each trial: prewarm GREEN → wrk2 180s → switchover → parse CSV → rollback"
log ""

TRIAL_START_ALL=$(date +%s)

for TRIAL in $(seq 1 "$N_TRIALS"); do
  TRIAL_TS=$(date +"%Y%m%d_%H%M%S")
  RESULT_FILE="$RESULTS_DIR/run_${TRIAL_TS}.txt"
  CSV_FILE="$RESULTS_DIR/run_${TRIAL_TS}.csv"

  log "${BOLD}  ┌─ Trial ${TRIAL}/${N_TRIALS}  [$(date +%T)]  ───────────────────────────────┐${NC}"

  # ── 2a. Pre-warm GREEN ───────────────────────────────────────────────────
  log "  │  Building + starting GREEN..."
  docker compose --profile green build  >/dev/null 2>&1
  docker compose --profile green up -d  >/dev/null 2>&1

  # Wait for green epsilon to be healthy
  GREEN_READY=0
  for i in $(seq 1 40); do
    if curl -sf "${GREEN_PREWARM_URL}health" >/dev/null 2>&1; then
      GREEN_READY=1; break
    fi
    sleep 2
  done
  [[ $GREEN_READY -eq 0 ]] && { log "  │  ${YELLOW}⚠ GREEN not ready, skipping trial${NC}"; continue; }

  log "  │  Prewarming GREEN JVMs (${PREWARM_REQUESTS} requests)..."
  for i in $(seq 1 "$PREWARM_REQUESTS"); do
    curl -sf "${GREEN_PREWARM_URL}" >/dev/null 2>&1 &
    if (( i % 10 == 0 )); then wait; sleep "$PREWARM_PAUSE"; fi
  done
  wait
  log "  │  GREEN is warm ✓"

  # ── 2b. Run wrk2 in background ───────────────────────────────────────────
  log "  │  Starting wrk2 at ${RATE} req/s for ${TRIAL_DURATION}s..."
  "$WRK_CMD" \
    -t"$THREADS" -c"$CONNECTIONS" -d"${TRIAL_DURATION}s" -R"$RATE" \
    --latency -s "$LOAD_TEST_DIR/report.lua" \
    "$TARGET_URL" > "$RESULT_FILE" 2>&1 &
  WRK_PID=$!

  # ── 2c. Wait then switchover ─────────────────────────────────────────────
  log "  │  Waiting ${SWITCHOVER_DELAY}s then triggering switchover..."
  sleep "$SWITCHOVER_DELAY"
  SW_START=$(date +%s%3N)
  ansible-playbook \
    -i "$PROJECT_ROOT/ansible/inventory/hosts.ini" \
    "$PROJECT_ROOT/ansible/deploy.yml" \
    >> "$RESULT_FILE" 2>&1
  SW_END=$(date +%s%3N)
  SW_MS=$(( SW_END - SW_START ))

  # ── 2d. Wait for wrk2 ───────────────────────────────────────────────────
  wait "$WRK_PID" || true

  # ── 2e. Parse CSV ────────────────────────────────────────────────────────
  echo "timestamp,switchover_duration_ms,non2xx_errors,requests_sec,latency_p50,latency_p99" > "$CSV_FILE"
  NON2XX=$(grep -oP 'Non-2xx or 3xx responses: \K[0-9]+' "$RESULT_FILE" 2>/dev/null || echo "0")
  REQ_SEC=$(grep -oP 'Requests/sec:\s+\K[0-9.]+' "$RESULT_FILE" 2>/dev/null | head -1 || echo "N/A")
  P50=$(grep -oP 'Latency p50\s+:\s+\K\S+' "$RESULT_FILE" 2>/dev/null \
        || grep -oP '50\.000%\s+\K\S+' "$RESULT_FILE" 2>/dev/null || echo "N/A")
  P99=$(grep -oP 'Latency p99\s+:\s+\K\S+' "$RESULT_FILE" 2>/dev/null \
        || grep -oP '99\.000%\s+\K\S+' "$RESULT_FILE" 2>/dev/null || echo "N/A")
  echo "${TRIAL_TS},${SW_MS},${NON2XX},${REQ_SEC},${P50},${P99}" >> "$CSV_FILE"

  STATUS_COLOR="$GREEN"
  [[ "$NON2XX" != "0" && "$NON2XX" != "" ]] && STATUS_COLOR="$YELLOW"
  log "  │  ${STATUS_COLOR}Errors=${NON2XX}  Switchover=${SW_MS}ms  p50=${P50}  p99=${P99}${NC}"

  # ── 2f. Rollback to BLUE for next trial ──────────────────────────────────
  log "  │  Rolling back to BLUE..."
  ansible-playbook \
    -i "$PROJECT_ROOT/ansible/inventory/hosts.ini" \
    "$PROJECT_ROOT/ansible/rollback.yml" \
    >> "$RESULT_FILE" 2>&1 || true
  docker compose --profile green stop >/dev/null 2>&1 || true

  ELAPSED=$(( $(date +%s) - TRIAL_START_ALL ))
  REMAINING=$(( (N_TRIALS - TRIAL) * ELAPSED / TRIAL ))
  log "  └─ Done  (elapsed: ${ELAPSED}s, est. remaining: ${REMAINING}s)"
  log ""
done

log "${GREEN}${BOLD}  ✓ All $N_TRIALS trials complete.${NC}"
log ""

fi  # end SKIP_TRIALS

# ── Step 3: Build master_results.csv ─────────────────────────────────────────
log "${BOLD}[STEP 3/4] Building master_results.csv...${NC}"
python3 "$MATH_DIR/build_master_csv.py"
log ""

# ── Step 4: Run mathematical modelling ───────────────────────────────────────
log "${BOLD}[STEP 4/4] Running M/M/c analysis + generating figures...${NC}"
python3 "$MATH_DIR/01_queueing_model.py"
python3 "$MATH_DIR/analyse.py"
log ""

# ── Final summary ─────────────────────────────────────────────────────────────
log "${BOLD}${CYAN}"
log "╔══════════════════════════════════════════════════════════════╗"
log "║   Experiment Complete                                        ║"
log "╚══════════════════════════════════════════════════════════════╝${NC}"
log ""
log "  Outputs:"
log "  ├─ Raw trial logs   : load-test/results/run_*.txt"
log "  ├─ Trial CSVs       : load-test/results/run_*.csv"
log "  ├─ master_results   : math-models/master_results.csv"
log "  ├─ Queueing figure  : math-models/figures/fig1_queueing_saturation.png"
log "  ├─ CDF switchover   : math-models/figures/fig_cdf_switchover.png"
log "  ├─ CDF p99          : math-models/figures/fig_cdf_p99.png"
log "  ├─ Errors by trial  : math-models/figures/fig_errors_by_trial.png"
log "  ├─ Downtime bound   : math-models/figures/fig_downtime_bound.png"
log "  ├─ JSON summary     : math-models/figures/analysis_summary.json"
log "  ├─ Dashboard        : dashboard.html  (open in browser)"
log "  └─ Math appendix    : MATH_APPENDIX.md"
log ""
log "  Completed : $(date)"
log "  Full log  : $LOG_FILE"
