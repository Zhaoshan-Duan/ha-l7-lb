# Handoff — Final Experiment Data Bundle

**Author**: Joshua Duan
**Partner for the report**: S Karthikeyan S.
**Run region**: us-west-2
**LB count**: 2 (Exp 1, Exp 2); 1/2/4/8 (Exp 3)

---

## How to use this bundle

1. Numbers and tables in this doc are the already-digested findings.
2. Per-run raw data lives in `results/final/<exp>/<run>/`.
3. Screenshots are in the same folders.
4. `RUNS.md` lists the exact commands used; `SCREENSHOTS.md` the capture checklist.
5. For the report, the most-compact way to write each experiment is: state the hypothesis, cite the table below, drop in the key screenshot.

---

## Exp 1 — Weighted on heterogeneous backends

**Hypothesis**: the weighted routing algorithm distributes traffic proportionally to the configured weights, enabling heterogeneous backends to be utilized efficiently without overloading the weaker tier.

**Setup**:
- 1 strong backend (Fargate 512 CPU / 1024 MB = 0.5 vCPU / 1 GiB)
- 1 weak backend (Fargate 256 CPU / 512 MB = 0.25 vCPU / 0.5 GiB)
- Weights: strong=70, weak=30 (`config.yaml` + two DNS watchers)
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

**The 70/30 split holds with four significant figures.** The weighted algorithm correctly follows the declared configuration.

**CPU utilization during run** (from CloudWatch dashboard `exp1-dashboard_end0.png`):

| Component | CPU |
|-----------|-----|
| LB (both tasks aggregated) | ~100% sustained during minutes 1-4 |
| Strong backend | ~45% |
| Weak backend | ~55% |
| Redis | near 0% |

**Interpretation**: the LB is the bottleneck at 500 users, not either backend. The weak backend is more stressed than the strong (55% vs 45%) despite handling only 30% of traffic, consistent with its half-size CPU allotment. `RetryRate: 0` because all backends were healthy.

**Screenshots**:
- `exp1-dashboard_end0.png`, `exp1-dashboard_end1.png` — CloudWatch dashboard over the 5-min run window
- `ecs_strong_config.png`, `ecs_strong_tasks.png` — proves strong tier Fargate task ran at 0.5 vCPU / 1 GiB
- `ecs_weak_config.png`, `ecs_weak_tasks.png` — proves weak tier ran at 0.25 vCPU / 0.5 GiB

**Caveats for the report**:
- LB saturated at 100% CPU. Additional backend capacity wouldn't raise RPS — the LB is the limit.
- Heterogeneous RR and LC results from milestone 1 (`docs/milestone_1/report.md`) remain canonical for those algorithms. The new weighted result completes the matrix.
- No retry activity (retries_enabled=true default, but backends healthy).

---

## Exp 2 — Failure isolation and retry efficacy under chaos

**Hypothesis**: idempotent-method retry reduces client-visible error rate when individual backends fail.

**Setup**:
- 2 LB instances, homogeneous backends, `ChaosInjectionUser`
- 20% of requests forced to 500 via `X-Chaos-Error` header; ~10% delayed past proxy timeout via `X-Chaos-Delay` header
- 50 / 100 / 200 concurrent users × 5 min × 2 variants (`retries_enabled=true` / `=false`) = 6 runs

**Files**: `results/final/exp2/retry_{on,off}_{50,100,200}/`

**Headline table**:

| Users | retries_enabled | Total reqs | Failure % | p50 |
|-------|-----------------|-----------|-----------|-----|
| 50  | true  | 48,254  | **99%** | 1 ms  |
| 100 | true  | 96,403  | **99%** | 1 ms  |
| 200 | true  | 194,351 | **99%** | 1 ms  |
| 50  | false | 18,197  | 29%   | 19 ms |
| 100 | false | 36,183  | 29%   | 19 ms |
| 200 | false | 72,691  | 30%   | 19 ms |

**Counterintuitive finding**: enabling retries makes the system *dramatically worse* under sustained 5xx chaos, flipping client failure rate from roughly 30% (the injected chaos rate) to 99%.

**Mechanism**: each 5xx triggers `pool.MarkHealthy(backend, false)` in `proxy.go:181`. Under 20% chaos at 50+ users, both backends get marked DOWN within seconds. The LB then returns instant `503 No healthy backends` (p50=1 ms, LB-side) for all subsequent traffic until the 10s health checker re-UPs them. Under persistent chaos, the checker cannot outpace the ejection rate and the LB spends most of its time in cascade.

**Why retries_enabled=false avoids the cascade**: with the retry block disabled, failing requests return 504 immediately and backends are never marked DOWN via the retry path. The health checker then sees steady `/health` responses and keeps backends marked UP, so normal traffic (80% non-chaos) flows at real backend latency (p50=19 ms).

**Design gap, not a bug**: the retry policy assumes transient, uncorrelated failures. Under correlated 5xx (chaos here; a downstream outage in production), the "mark DOWN + retry elsewhere" policy amplifies rather than isolates the failure. Production L7 LBs (Envoy, NGINX, HAProxy) all add safeguards we don't have:
- Minimum-healthy-backends threshold (don't eject the last healthy one)
- Ejection rate limit (no more than N DOWN marks per second)
- Consecutive-failure requirement (N in a row, not one)
- Graduated half-open probe on re-admission

**Screenshots**:
- `retry_on_200/dashboard.png` — dashboard at the 23:25–23:30 UTC window. LB CPU low (instant 503s are cheap), backend CPU thrashes as it cycles between UP and DOWN.
- `retry_off_200/dashboard.png` — 23:47–23:52 UTC. LB CPU steady, backend CPU steady, real traffic flowing.

**Raw data per run**:
- `stats.csv` — per-endpoint aggregate (/api/data (normal), /api/data (chaos-500), /api/data (chaos-delay-Nms), /health)
- `stats_history.csv` — 10-second time-series
- `failures.csv` — failure class breakdown
- `report.html` — self-contained Locust HTML report

---

## Exp 3 — Horizontal scaling (LB count sweep)

**Hypothesis**: Redis Pub/Sub coordination overhead becomes the bottleneck as LB count grows, causing sublinear RPS scaling.

**Setup**:
- Homogeneous backends (auto-scaled 2-8 on 70% CPU target)
- `ScalingBaselineUser` at 500 and 2000 users (5 min each), `ScalingSpikeUser` at 2000 users (3 min)
- LB count swept at 1 / 2 / 4 / 8
- 12 runs total, all against `/api/data` (LB-isolation workload)

**Files**: `results/final/exp3/lb{1,2,4,8}_{u500,u2000,spike}/`

**Headline table**:

| LB | 500 u RPS | 500 u p99 | 2000 u RPS | 2000 u p99 | Spike RPS | Spike p99 |
|----|-----------|-----------|------------|------------|-----------|-----------|
| 1  | 2,427     | 370 ms    | **1,188** (collapse) | **11 s**  | 1,170     | 10 s      |
| 2  | 2,794     | 280 ms    | 2,699      | 10 s       | 2,690     | 10 s      |
| 4  | 4,308     | 170 ms    | 4,757      | 7.2 s      | 4,746     | 6.6 s     |
| 8  | 5,777     | 160 ms    | 5,093      | **250 ms** | 5,088     | 350 ms    |

**Findings**:

1. **Single LB collapses at 2000 users.** Throughput drops from 2,427 RPS (at 500 u) to 1,188 RPS (at 2000 u); p99 explodes from 370 ms to 11 s. Classic backpressure: with enough queueing the effective throughput falls below the unloaded single-user rate. This is a real and citeable finding about when a single LB tips over.

2. **Near-linear scaling 1→2→4 at 2000 users**: 1,188 → 2,699 → 4,757 RPS corresponds to multipliers of 2.3× and 4.0× (vs the ideal 2× and 4×). Linear scaling holds to 4 LBs with this workload.

3. **Sublinear scaling 4→8**: only +7% RPS (4,757 → 5,093) but p99 drops 29× (7.2 s → 250 ms). The RPS plateau plus the latency drop suggests the bottleneck shifted off the LB — the extra LB tasks are now just reducing queueing at the existing per-LB rate. Candidates for the new bottleneck: Locust client (c6i.xlarge, 4 vCPU), NLB, or backend autoscaling lag. Redis Pub/Sub overhead is NOT visible as a dominant factor under this workload; it would need a CPU-heavier backend to surface.

4. **Spike behavior mirrors baseline**: at each LB count the spike RPS is within 1% of the sustained 2000-user RPS, indicating the spike load is not materially different from the sustained case in our parameter range.

**Raw data per run**: `stats.csv`, `stats_history.csv`, `failures.csv`, `report.html`.

**Caveats for the report**:
- All runs use `/api/data` (trivial ~5-25 ms backend work). The scaling story isolates the LB; backend saturation is intentionally not a factor.
- 0 failures across all 12 runs. The scaling signal is clean.
- For LB counts beyond 4, Locust (single c6i.xlarge host, 4 vCPU) begins to compete for CPU with the LB fleet — the 4→8 plateau may be partially client-side. A multi-instance Locust harness would let us push this further.

---

## Exp 3b — Compute-heavy scaling (attempted, inconclusive)

**Hypothesis**: under CPU-heavy backend work the scaling curve differs from Exp 3's LB-isolation result — backends become the bottleneck and LB count matters less.

**Outcome**: attempted but did not produce clean numbers. See `results/final/exp3b/README.md` for the full analysis.

**Summary**: compute workload saturates the 256-CPU Fargate backends so heavily that the `/health` probe queues behind `/api/compute` work, times out, and the health checker marks backends DOWN. Result: 94-99% client-visible 503s regardless of `retries_enabled`, across u=50/100/500.

**Implication**: `/api/compute` at these user counts is not measuring LB-scaling at all — it's measuring backend capacity plus the health-check-timeout cascade. A cleaner Exp 3b would require any of:
- u << backend capacity (e.g., u=10–20)
- `/api/compute?iterations=1000` to reduce per-request cost to milliseconds
- Increased `health_check.timeout` beyond backend p99 under load
- Decoupled health-check serving path on the backend (separate pool)

We captured the SSM command stderr logs for three representative attempts (`results/final/exp3b/*_attempt/locust.log`) as evidence.

**For the report**: frame Exp 3b as a negative result that motivates future work, not a scaling measurement. Exp 3 `/api/data` remains the authoritative scaling signal.

---

## Cross-experiment summary for quick reference

| Experiment | Configuration | Result |
|-----------|---------------|--------|
| Exp 1 weighted-hetero | 70/30 strong/weak | 70/30 distribution holds to 4 sig figs; LB saturates first |
| Exp 2 retry on vs off | 20% chaos-500 | **Retries make failure rate 99% vs 29%** — cascading ejection under correlated failure |
| Exp 3 /api/data scaling | lb=1/2/4/8 | Near-linear 1→4, sublinear 4→8; single LB collapses at 2000 u |
| Exp 3b /api/compute scaling | — | Compute saturates backends; health-check cascade prevents clean LB-scaling measurement |

---

## Infrastructure summary

- **Terraform**: `terraform/` — one module per concern (network, ecr, ecs-lb, ecs-backend, nlb, elasticache, autoscaling, logging, locust)
- **Locust runner**: `terraform/modules/locust/` — single `c6i.xlarge` EC2 driven via SSM Run Command; no SSH; artifacts land in S3
- **CloudWatch dashboard**: `terraform/dashboard.tf` — one dashboard with all panels for LB, backend (strong/weak/homogeneous), Redis, NLB
- **Helper scripts**: `scripts/run_locust.sh` (per-run driver), `scripts/capture_lb_metrics.sh` (per-LB-task metrics snapshot)
- **Retry toggle**: `load_balancer.retries_enabled` in `config.yaml`, overridable via `RETRIES_ENABLED` env var (ECS task definition)

Infrastructure is torn down post-experiments. CloudWatch metrics persist for 15 days if additional screenshots are needed before teardown.
