# Handoff — Final Experiment Data Bundle

**Author**: Joshua Duan
**Partner for the report**: S Karthikeyan S.
**Run region**: us-west-2
**LB instance count (Exp 1, 2): 2** (Exp 3 varies per run)

---

## How to use this bundle

1. Numbers and tables in this doc are the already-digested findings.
2. Per-run raw data lives in `results/final/<exp>/<run>/`.
3. Screenshots are in the same folders.
4. `RUNS.md` lists the exact commands used; `SCREENSHOTS.md` the capture checklist.
5. For the report, the most-compact way to write each experiment is: state the hypothesis → cite the table below → drop in the key screenshot.

---

## Exp 1 — Weighted on heterogeneous backends

**Hypothesis**: the weighted routing algorithm distributes traffic proportionally to the configured weights, enabling heterogeneous backends to be utilized efficiently without overloading the weaker tier.

**Setup**:
- 1 strong backend (Fargate 512 CPU / 1024 MB = 0.5 vCPU / 1 GiB)
- 1 weak backend (Fargate 256 CPU / 512 MB = 0.25 vCPU / 0.5 GiB)
- Weights: strong=70, weak=30 (via `config.yaml` + two DNS watchers)
- 2 LB instances, 500 concurrent users, 5 min, `AlgorithmCompareUser`

**Files**: `results/final/exp1/weighted_hetero_70_30/`

**Headline numbers** (client-side, from Locust `stats.csv`):

| Metric | Aggregate |
|--------|-----------|
| Total requests | 720,766 |
| Failures | 0 |
| Avg RPS | 2,405.7 |
| p50 latency | 76 ms |
| p95 latency | 170 ms |
| p99 latency | 190 ms |
| Max latency | 401 ms |

**Per-backend distribution** (server-side, aggregated across both LB tasks from `lb_snapshots_end/*_metrics.json`):

| Backend | Private IP | Requests | % of total |
|---------|-----------|----------|------------|
| Strong (0.5 vCPU) | 172.31.26.56 | 519,167 | **70.0%** |
| Weak (0.25 vCPU) | 172.31.51.33 | 222,525 | **30.0%** |

**The 70/30 split holds with 4 significant figures.** The weighted algorithm correctly follows the declared configuration.

**CPU utilization during run** (from CloudWatch dashboard screenshot `exp1-dashboard_end0.png`):

| Component | CPU |
|-----------|-----|
| LB (both tasks aggregated) | ~100% sustained during minutes 1-4 |
| Strong backend | ~45% |
| Weak backend | ~55% |
| Redis | near 0% |

**Interpretation**: the LB is the bottleneck at 500 users, not either backend. The weak backend is more stressed than the strong (55% vs 45%) despite handling only 30% of traffic — consistent with its half-size CPU allotment. There is NO retry activity (`RetryRate: 0`) because all backends are healthy throughout.

**Screenshots**:
- `exp1-dashboard_end0.png`, `exp1-dashboard_end1.png` — CloudWatch dashboard over the 5-min run window
- `ecs_strong_config.png`, `ecs_strong_tasks.png` — proves strong tier Fargate task ran at 0.5 vCPU / 1 GiB
- `ecs_weak_config.png`, `ecs_weak_tasks.png` — proves weak tier ran at 0.25 vCPU / 0.5 GiB

**Raw data**:
- `stats.csv` — Locust per-endpoint aggregate (GET /api/data, POST /api/data, GET /health)
- `stats_history.csv` — 10-second time-series
- `failures.csv` — empty (0 failures)
- `report.html` — self-contained Locust HTML report
- `lb_snapshots_mid/` and `lb_snapshots_end/` — per-LB-task JSON snapshots of `/metrics` and `/health/backends`, plus time-series CSV

**Caveats for the report**:
- **LB is the bottleneck, not backends.** At 500 users both LB tasks saturate at 100% CPU. Raising backend count or CPU wouldn't raise RPS further. Any claim about weighted algorithm efficiency should mention this.
- Heterogeneous RR and LC results are from milestone 1 (`docs/milestone_1/report.md`) and are still the canonical numbers for those algorithms on the same topology. The new weighted result completes the Exp 1 matrix.
- No retries happened — weighted-hetero isolates the routing algorithm from the retry layer. That's the right signal for this experiment.

---

## Exp 2 — (pending)

## Exp 3 — (pending)
