# Zero-Downtime Blue-Green Deployment Framework
### P08 — Ansible · Docker · Nginx · wrk2

> **Layer 1 Implementation** — What the project spec asks for.

---

## Architecture

```
                     ┌─────────────────────┐
  All traffic ──────▶│   Nginx :80         │
                     │  (upstream.conf)    │
                     └────────┬────────────┘
                              │ proxy_pass
               ┌──────────────┴──────────────┐
               ▼                             ▼
     epsilon-blue:5000            epsilon-green:5000
         (gateway v1)                 (gateway v2)
        /     |     \               /     |     \
   alpha  beta  gamma  delta   alpha  beta  gamma  delta
   -blue  -blue -blue  -blue   -green -green -green -green
```

Nginx decides which epsilon (gateway) receives traffic via `nginx/conf.d/upstream.conf`.  
Ansible writes that file and sends `docker exec nginx nginx -s reload` — **graceful, zero dropped connections**.

---

## Quickstart

### Prerequisites
- Docker + Docker Compose v2
- Ansible (`pip install ansible`)
- wrk2 (for load tests — see below)

```bash
# 1. Start blue environment
make init

# 2. Verify (should show "color": "blue", "version": "1.0")
curl http://localhost/health | python3 -m json.tool

# 3. Deploy green (full blue→green switchover with health gate)
make deploy

# 4. Verify (should now show "color": "green", "version": "2.0")
curl http://localhost/health | python3 -m json.tool

# 5. Manual rollback
make rollback
```

---

## Project Structure

```
SummerProject/
├── Makefile                        # All common operations
├── docker-compose.yml              # Blue + Green profiles + Nginx
├── nginx/
│   ├── nginx.conf                  # Main Nginx config
│   └── conf.d/upstream.conf        # ← Ansible writes here to switch traffic
├── services/
│   ├── svc-alpha/                  # User API      (v1.0 blue / v2.0 green)
│   ├── svc-beta/                   # Product API
│   ├── svc-gamma/                  # Order API
│   ├── svc-delta/                  # Inventory API
│   └── svc-epsilon/                # API Gateway (aggregates all 4)
├── ansible/
│   ├── inventory/hosts.ini
│   ├── group_vars/all.yml          # Thresholds + paths
│   ├── roles/
│   │   ├── blue_green_deploy/      # Spin up green + swap Nginx
│   │   ├── health_gate/            # Poll health, auto-rollback if needed
│   │   └── rollback/               # Idempotent restore to blue
│   ├── deploy.yml                  # Master: blue → green
│   ├── rollback.yml                # Master: green → blue (manual)
│   └── switchover.yml              # Nginx upstream swap only
└── load-test/
    ├── run_wrk2.sh                 # Triggers wrk2 + Ansible mid-flight
    ├── report.lua                  # Lua script: 5xx tracking + latency CDF
    └── results/                    # Timestamped output + CSV (auto-created)
```

---

## Ansible Roles

| Role | What it does |
|---|---|
| `blue_green_deploy` | Builds green containers, waits for green health, swaps Nginx, calls health_gate |
| `health_gate` | Polls `http://localhost/health` N times; triggers rollback if thresholds breached |
| `rollback` | Restores blue upstream, reloads Nginx, stops green, logs event to `rollback.log` |

**Health gate thresholds** (configurable in `ansible/group_vars/all.yml`):
```yaml
health_gate_retries: 6     # poll attempts
health_gate_delay:   5     # seconds between polls
```

---

## Installing wrk2

```bash
# Option A: build locally (no sudo required)
git clone https://github.com/giltene/wrk2
cd wrk2 && make
cp wrk /path/to/SummerProject/load-test/wrk2_bin   # run_wrk2.sh finds it here automatically

# Option B: install system-wide
git clone https://github.com/giltene/wrk2
cd wrk2 && make && sudo cp wrk /usr/local/bin/wrk2
```

---

## Running the Load Test

```bash
make load-test
# OR
cd load-test && ./run_wrk2.sh
```

The script:
1. Starts wrk2 at 500 req/s against `http://localhost/`
2. After 30s, triggers `ansible-playbook deploy.yml` (mid-test switchover)
3. Captures latency histogram, 5xx count, throughput
4. Saves results to `load-test/results/run_<timestamp>.txt` + `.csv`

The `.csv` feeds directly into **Layer 2 measurement**.

---

## Ports Reference

| Container | Host Port | Purpose |
|---|---|---|
| nginx | 80 | Main gateway (all traffic goes here) |
| epsilon-blue | 8105 | Direct blue health check (Ansible pre-switch) |
| epsilon-green | 8205 | Direct green health check (Ansible pre-switch) |

---

## Tutorial Article

See [`TUTORIAL.md`](./TUTORIAL.md) for a publication-quality writeup covering the architecture,
Ansible role design, and measured downtime results — suitable for The New Stack or DZone.

