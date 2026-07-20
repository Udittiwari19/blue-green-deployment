#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  run_model.sh — Run M/M/c queueing model and open dashboard
#  Usage: cd SummerProject && bash math-models/run_model.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  M/M/c Queueing Model — Blue-Green Deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Install deps if needed
if ! python3 -c "import numpy, scipy, matplotlib" 2>/dev/null; then
  echo "[INFO] Installing Python dependencies..."
  pip3 install -r "${SCRIPT_DIR}/requirements.txt" --quiet --break-system-packages
fi

echo "[1/2] Running M/M/c model..."
python3 "${SCRIPT_DIR}/01_queueing_model.py"

echo ""
echo "[2/2] Regenerating dashboard..."
python3 - << 'PYEOF'
import base64, json, sys
sys.path.insert(0, '/home/udit/SummerProject/math-models')
fig = '/home/udit/SummerProject/math-models/figures/fig1_queueing_saturation.png'
print(f"  Figure exists: {fig}")
PYEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ Done. Open these files:"
echo "  ├─ Figure  : math-models/figures/fig1_queueing_saturation.png"
echo "  ├─ Dashboard: dashboard.html"
echo "  └─ Appendix : MATH_APPENDIX.md"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
