#!/usr/bin/env python3
"""
=============================================================================
Model 1: M/M/c Queueing Theory — System Capacity & Saturation Analysis
=============================================================================

Architecture note:
  Each client request hits Nginx -> epsilon (gateway) -> 4 backends in parallel.
  So the SYSTEM has c=1 gateway chain per environment (one epsilon + 4 backends).
  However, each BACKEND microservice is a separate server.

  Modelling approach:
    - epsilon aggregates 4 parallel backend calls, so effective service time
      E[S] = max(alpha, beta, gamma, delta) ≈ p50_baseline (dominated by slowest)
    - We model the NGINX->epsilon path as M/M/1 (single chain per color)
    - For multi-instance analysis we use M/M/c with c=number of replicas

  Real measured values (from load test results):
    Baseline p50  = 182.40 ms  (warm, pre-warmed Blue)
    Baseline p99  = 2891.78 ms
    Baseline mean = 380.34 ms  (from wrk2 stats)
    Baseline std  = 539.11 ms
    Test rate λ   = 50 req/s   (chosen safe rate)
    Observed saturation empirically ~75 req/s on this hardware

  Key insight: With a SINGLE chain (c=1), mu=1/0.38 ≈ 2.63/s.
  But with 50 concurrent connections over 4 threads, effective parallelism
  is c = CONNECTIONS = 50 (HTTP keep-alive, wrk2 pipeline model).

  We use c=50 connections, mu = 1/mean_service_time.
  This gives rho = lambda / (c * mu) which must be < 1 for stability.
=============================================================================
"""
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from math import factorial
import os, json

FIGURES_DIR = os.path.join(os.path.dirname(__file__), "figures")
os.makedirs(FIGURES_DIR, exist_ok=True)

# ── Real measured constants ───────────────────────────────────────────────────
# From baseline_20260718_234310.txt (warm, pre-warmed):
MEAN_MS       = 380.34   # ms — mean service time (warm state)
P50_MS        = 182.40   # ms
P99_MS        = 2891.78  # ms
STD_MS        = 539.11   # ms

# From run_20260718_153126.txt (with switchover, cold JVM):
P50_COLD_MS   = 5861.38  # ms
P99_COLD_MS   = 9199.61  # ms

# wrk2 parameters (from run scripts):
C_CONNS       = 50       # concurrent HTTP connections (wrk2 -c50)
LAMBDA_TEST   = 50       # req/s — chosen safe test rate
LAMBDA_UNSAFE = 200      # req/s — rate used in initial (unstable) test

MU = 1000.0 / MEAN_MS    # service rate per server = 2.63 req/s
# With 50 connections as parallel "servers":
C = C_CONNS              # effective parallelism = connection pool size

# Empirically observed saturation (the script comment says ~75 req/s)
LAMBDA_SAT = 75

# ── Erlang-C formula ─────────────────────────────────────────────────────────
def erlang_c(lam, mu, c):
    """Return (P_wait, W_q_sec, rho). If rho>=1, W_q=inf."""
    rho = lam / (c * mu)
    if rho >= 1.0:
        return 1.0, np.inf, rho
    # P0 denominator
    s = sum((c * rho)**k / factorial(k) for k in range(min(c, 170)))
    heavy = (c * rho)**c / (factorial(min(c, 170)) * (1 - rho))
    P0 = 1.0 / (s + heavy)
    Cp = heavy * P0          # P(arriving request must wait)
    Wq = Cp / (c * mu - lam) # mean waiting time in queue (s)
    return Cp, Wq, rho

# ── Sweep λ ──────────────────────────────────────────────────────────────────
lam_max  = C * MU           # theoretical max throughput
lambdas  = np.linspace(0.5, lam_max * 0.999, 600)
wq_ms, rho_arr, cp_arr = [], [], []
for lam in lambdas:
    Cp, Wq, rho = erlang_c(lam, MU, C)
    rho_arr.append(rho)
    cp_arr.append(Cp)
    wq_ms.append(Wq * 1000 if np.isfinite(Wq) else np.nan)
wq_ms, rho_arr, cp_arr = np.array(wq_ms), np.array(rho_arr), np.array(cp_arr)

# Key operating points
_, wq_t, rho_t = erlang_c(LAMBDA_TEST,   MU, C)
_, wq_s, rho_s = erlang_c(LAMBDA_SAT,    MU, C)
_, wq_u, rho_u = erlang_c(LAMBDA_UNSAFE, MU, C)
Cp_t, _, _     = erlang_c(LAMBDA_TEST,   MU, C)
Cp_s, _, _     = erlang_c(LAMBDA_SAT,    MU, C)

print("=" * 65)
print("  MODEL 1: M/M/c Queueing Theory — Blue-Green Capacity Analysis")
print("=" * 65)
print(f"\n  System parameters (from measured data):")
print(f"    Mean service time E[S] = {MEAN_MS:.2f} ms  (baseline warm mean)")
print(f"    Service rate per conn  μ = {MU:.4f} req/s")
print(f"    Effective parallelism  c = {C} (HTTP connections, wrk2 -c{C_CONNS})")
print(f"    Theoretical max throughput c·μ = {lam_max:.2f} req/s")
print()
print(f"  Operating point  λ={LAMBDA_TEST} req/s (TEST rate — chosen safe):")
print(f"    Traffic intensity  ρ = {rho_t:.6f}  ({'STABLE ✓' if rho_t < 1 else 'UNSTABLE ✗'})")
print(f"    Mean queue wait   Wq = {wq_t*1000:.4f} ms  (negligible)")
print(f"    P(wait)              = {Cp_t:.6f}")
print()
print(f"  Operating point  λ={LAMBDA_SAT} req/s (saturation, empirically observed):")
print(f"    Traffic intensity  ρ = {rho_s:.6f}")
print(f"    Mean queue wait   Wq = {wq_s*1000:.4f} ms")
print(f"    P(wait)              = {Cp_s:.6f}")
print()
print(f"  Operating point  λ={LAMBDA_UNSAFE} req/s (UNSAFE — initial experiment):")
print(f"    Traffic intensity  ρ = {rho_u:.6f}  ({'STABLE' if rho_u < 1 else 'DIVERGES ✗ → queue unbounded'})")
if np.isfinite(wq_u):
    print(f"    Mean queue wait   Wq = {wq_u*1000:.1f} ms")
else:
    print(f"    Queue is UNBOUNDED — confirmed by p99={P99_COLD_MS}ms, mean={5397:.0f}ms in test data")
print()

# ── Figures ──────────────────────────────────────────────────────────────────
fig, axes = plt.subplots(1, 2, figsize=(14, 6))
fig.patch.set_facecolor('#0d1117')
for ax in axes:
    ax.set_facecolor('#161b22')
    ax.tick_params(colors='#c9d1d9', which='both')
    for s in ax.spines.values():
        s.set_edgecolor('#30363d')
    ax.grid(True, color='#21262d', linewidth=0.8, alpha=0.8)

# ─ Left panel: W_q vs λ ──────────────────────────────────────────────────────
ax1 = axes[0]
valid = ~np.isnan(wq_ms)
ax1.plot(lambdas[valid], wq_ms[valid], color='#58a6ff', lw=2.5,
         label='$W_q$ — Mean queue wait')

# Vertical reference lines
ax1.axvline(LAMBDA_TEST, color='#3fb950', lw=2, ls='--',
            label=f'λ={LAMBDA_TEST} req/s (test)  ρ={rho_t:.4f}')
ax1.axvline(LAMBDA_SAT,  color='#f0883e', lw=2, ls='--',
            label=f'λ={LAMBDA_SAT} req/s (saturation)')
ax1.axvline(LAMBDA_UNSAFE, color='#f85149', lw=2, ls=':',
            label=f'λ={LAMBDA_UNSAFE} req/s (UNSAFE)')

# Measured p99 annotation at lambda_unsafe
ax1.annotate(f'Measured p99={P99_COLD_MS:.0f}ms\nat λ={LAMBDA_UNSAFE}',
             xy=(LAMBDA_UNSAFE, wq_ms[valid][-1] * 0.85),
             xytext=(LAMBDA_UNSAFE - 50, wq_ms[valid][-1] * 0.7),
             color='#f85149', fontsize=8.5,
             arrowprops=dict(arrowstyle='->', color='#f85149', lw=1.5))

ax1.set_xlabel('Arrival Rate λ (req/s)', color='#c9d1d9', fontsize=11)
ax1.set_ylabel('Mean Queue Wait $W_q$ (ms)', color='#c9d1d9', fontsize=11)
ax1.set_title('M/M/c: Queue Wait vs. Load', color='#e6edf3', fontsize=13, fontweight='bold')
ax1.set_ylim(0, np.nanmax(wq_ms) * 1.25)
ax1.set_xlim(0, lam_max * 1.02)
ax1.legend(facecolor='#21262d', edgecolor='#30363d', labelcolor='#c9d1d9', fontsize=9)

# ─ Right panel: ρ vs λ with safe/danger shading ──────────────────────────────
ax2 = axes[1]
ax2.plot(lambdas, rho_arr, color='#d2a8ff', lw=2.5, label='Server utilization ρ = λ/(c·μ)')
ax2.axhline(1.0, color='#f85149', lw=2, ls=':', label='ρ=1  (stability boundary)')
ax2.axvline(LAMBDA_TEST,   color='#3fb950', lw=2, ls='--', label=f'ρ={rho_t:.4f} @ λ={LAMBDA_TEST}')
ax2.axvline(LAMBDA_SAT,    color='#f0883e', lw=2, ls='--', label=f'ρ={rho_s:.4f} @ λ={LAMBDA_SAT}')
ax2.axvline(LAMBDA_UNSAFE, color='#f85149', lw=2, ls=':',  label=f'ρ={rho_u:.4f} @ λ={LAMBDA_UNSAFE}')

safe   = lambdas <= LAMBDA_SAT
danger = (lambdas > LAMBDA_SAT) & (lambdas < lam_max)
ax2.fill_between(lambdas[safe],   0, rho_arr[safe],   alpha=0.15, color='#3fb950', label='Safe zone')
ax2.fill_between(lambdas[danger], 0, rho_arr[danger], alpha=0.15, color='#f85149', label='Danger zone')

ax2.set_xlabel('Arrival Rate λ (req/s)', color='#c9d1d9', fontsize=11)
ax2.set_ylabel('Utilization ρ = λ/(c·μ)', color='#c9d1d9', fontsize=11)
ax2.set_title('M/M/c: Server Utilization', color='#e6edf3', fontsize=13, fontweight='bold')
ax2.set_ylim(0, 1.2)
ax2.set_xlim(0, lam_max * 1.02)
ax2.legend(facecolor='#21262d', edgecolor='#30363d', labelcolor='#c9d1d9', fontsize=9)

fig.suptitle(
    f'Figure 1 — M/M/c Queueing Model  '
    f'(c={C} connections, μ={MU:.4f} req/s, E[S]={MEAN_MS}ms from measured baseline)',
    color='#e6edf3', fontsize=11, y=1.01
)
plt.tight_layout()
out = os.path.join(FIGURES_DIR, "fig1_queueing_saturation.png")
plt.savefig(out, dpi=150, bbox_inches='tight', facecolor='#0d1117')
plt.close()
print(f"  ✓ Figure saved: {out}")

# ── Save results for dashboard ────────────────────────────────────────────────
json.dump({
    "model":           "M/M/c Erlang-C",
    "c":               C,
    "mu":              round(MU, 6),
    "mean_service_ms": MEAN_MS,
    "lambda_max":      round(lam_max, 2),
    "lambda_test":     LAMBDA_TEST,
    "lambda_sat":      LAMBDA_SAT,
    "lambda_unsafe":   LAMBDA_UNSAFE,
    "rho_test":        round(rho_t, 6),
    "rho_sat":         round(rho_s, 6),
    "rho_unsafe":      round(rho_u, 6),
    "wq_test_ms":      round(wq_t * 1000, 6),
    "wq_sat_ms":       round(wq_s * 1000, 4),
    "p_wait_test":     round(Cp_t, 8),
    "p_wait_sat":      round(Cp_s, 6),
    "measured_p50_warm_ms":  P50_MS,
    "measured_p99_warm_ms":  P99_MS,
    "measured_p50_cold_ms":  P50_COLD_MS,
    "measured_p99_cold_ms":  P99_COLD_MS,
}, open(os.path.join(FIGURES_DIR, "model1_results.json"), "w"), indent=2)
print("  ✓ Results JSON saved.")
