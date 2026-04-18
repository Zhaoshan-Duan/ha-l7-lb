# Handoff — Final Experiment Data Bundle

**Author**: Joshua Duan
**Partner for the report**: S Karthikeyan Sura ("Sai")
**AWS region**: us-west-2
**Spec reference**: `~/Downloads/Experiments.md` (from Sai)

---

## Layer map — what's spec-required vs complementary

### Layer 1 (Sai's spec, required)

| Sai-prescribed work | Our folder | Status |
|---------------------|-----------|--------|
| Exp 1 — 6 core runs (RR/LC/W × homo/hetero) with `AlgorithmCompareUser` | `exp1/` + milestone 1 (`docs/milestone_1/report.md`) | **Complete** |
| Exp 1 — robustness extension with `BackendStressUser` (subset OK) | `exp1_robustness/` | **Complete (homo RR subset)** |
| Exp 2 Part A — chaos retry on/off | `exp2/` (original high-chaos) + `exp2a_low_chaos/` (repeat per Sai's 503 conditional) | **Complete** |
| Exp 2 Part B — replica-removal retry on/off | `exp2b/` | **Complete** |
| Exp 3 — lb_count 1/2/4/8 sweep with `ScalingBaselineUser` + `ScalingSpikeUser` | `exp3/` | **Complete** |

### Layer 2 (complementary, goes beyond spec)

| Extra work | Folder | Value |
|-----------|--------|-------|
| Exp 2 CPU-heavy variant (chaos on `/api/compute` with `ChaosInjectionComputeUser`) | `exp2a_compute_chaos/` | Shows the cascade mechanism is endpoint-agnostic |
| Exp 3 CPU-heavy scaling with `BackendStressUser` | `exp3_compute/` | Shows backend-bound scaling behavior vs /api/data's LB-bound |
| Exp 3b inconclusive attempts (default 50k iter compute, documented) | `exp3b/` | Negative result: default compute saturates backends + health cascade |
| Multiple dashboards per Exp 3 run + wide overview | `exp3/*.png`, `exp3/dashboard_overview_u2000.png` | Extra visualization |
| Sai conversation screenshots | `exp2/sai's comment on exp 2.png`, `sai comment on cpu end point .png` | Design-intent context |

---

## Exp 1 — Weighted on heterogeneous backends

**Hypothesis**: the weighted algorithm distributes traffic proportionally to configured weights.

**Setup**: 1 strong (Fargate 0.5 vCPU / 1 GiB) + 1 weak (0.25 vCPU / 0.5 GiB), weights 70/30, 2 LB instances, u=500, 5 min, `AlgorithmCompareUser`.

**Files**: `exp1/weighted_hetero_70_30/`

**Headline numbers**:

| Metric | Value |
|--------|-------|
| Total requests | 720,766 |
| Failures | 0 |
| RPS | 2,405.7 |
| p50 / p95 / p99 / max | 76ms / 170ms / 190ms / 401ms |

**Per-backend distribution** (aggregated across both LB tasks from `lb_snapshots_end/*_metrics.json`):

| Backend | Private IP | Requests | % |
|---------|-----------|----------|---|
| Strong (0.5 vCPU) | 172.31.26.56 | 519,167 | **70.0%** |
| Weak (0.25 vCPU) | 172.31.51.33 | 222,525 | **30.0%** |

70/30 split holds with 4 significant figures. CPU utilization: LB 100%, strong backend 45%, weak backend 55% — LB is the bottleneck at 500 users, not either backend.

Screenshots: `exp1-dashboard_end0.png`, `exp1-dashboard_end1.png`, `ecs_strong_config.png`, `ecs_strong_tasks.png`, `ecs_weak_config.png`, `ecs_weak_tasks.png`.

---

## Exp 1 robustness extension — `BackendStressUser` on homo RR

**Hypothesis**: verify the LB holds up under heavier, mixed CPU/payload/streaming workload.

**Setup**: 2 LB tasks, 2 homogeneous backends, `BackendStressUser` at u=20 × 5 min, policy round-robin.

**Files**: `exp1_robustness/homo_rr_stress_u20/`

**Headline**: 15,758 requests, **0 failures**, RPS 52.6, p50 17ms, p95 2000ms, p99 2100ms.

The p95/p99 are dominated by `/api/stream`'s inherent 2-second hold. Per-endpoint RPS mix matches `BackendStressUser`'s 40/30/15/15 task weight distribution. Zero failures confirms the LB handles the stress endpoints without issues at this load.

**Caveat**: Sai's spec allows "full matrix or a subset." We ran a subset (1 policy × 1 topology). A full matrix would add LC + weighted variants on homo and hetero; skipped for time.

---

## Exp 2 Part A — Chaos injection + retry efficacy

### Original runs (30% chaos) — `exp2/`

| Users | retries_enabled | Total reqs | Failure % |
|-------|-----------------|-----------|-----------|
| 50/100/200 | true | ~48k/96k/194k | **99%** |
| 50/100/200 | false | ~18k/36k/73k | 29% |

**Finding**: with aggressive chaos, LB 5xx → DOWN-marking cascades → 99% client failure (p50 collapses to 1ms LB-side 503). Disabling retries avoids the cascade but gives the pure chaos rate.

### Low-chaos repeat (Sai's conditional) — `exp2a_low_chaos/`

Sai's spec: "If outcomes are dominated by 503 … reduce chaos intensity … then repeat." `ChaosInjectionUser` task weights dialed from 6/2/1/1 (~30% chaos) to 18/1/1/1 (~14% chaos).

| Users | retries_enabled | Total reqs | Failure % |
|-------|-----------------|-----------|-----------|
| 50 | true | 45,529 | 91% |
| 100 | true | 95,590 | 97% |
| 200 | true | 192,943 | 98% |
| 50 | false | 26,456 | 9% |
| 100 | false | 53,714 | 9% |
| 200 | false | 106,590 | 9% |

**Cleaner gap but same mechanism**: retry_off closely matches the pure chaos rate (~9%, consistent with 14% chaos rate minus successful normal traffic). retry_on still cascades but at 91-98% (slightly lower than the 99% at 30% chaos). The retry+eject policy is still dominant even at reduced chaos intensity — the cascade is structural.

**Interpretation for the report**: retry helps when failures are transient and uncorrelated. When failures are correlated and persistent (chaos), the LB's eager DOWN-marking amplifies the failure. Production LBs (Envoy, NGINX, HAProxy) add safeguards we don't (min-healthy threshold, ejection rate limit, N-consecutive-failure).

### CPU-heavy variant — `exp2a_compute_chaos/`

Same matrix but against `/api/compute?iterations=2000` (backend patched to honor chaos headers on /api/compute via `handleChaos` helper). Used `ChaosInjectionComputeUser` class.

| Users | retries_enabled | Total reqs | Failure % |
|-------|-----------------|-----------|-----------|
| 50 | true | 45,996 | 92% |
| 100 | true | 96,345 | 97% |
| 200 | true | 193,779 | 98% |
| 50 | false | 27,665 | 9% |
| 100 | false | 55,108 | 9% |
| 200 | false | 109,604 | 9% |

**Result is essentially identical to /api/data low-chaos.** Cascade is endpoint-agnostic — the retry+eject policy responds to any 5xx, not to workload characteristics. Strong evidence that the finding generalizes.

---

## Exp 2 Part B — Replica removal (no chaos) — `exp2b/`

**Hypothesis**: retry hides a graceful replica drop from the client.

**Setup**: Backends scaled to 4, `ScalingBaselineUser` at u=200 × 10 min, replica dropped to 3 at T+150s. Compared retries_enabled on vs off on /api/data only.

| Variant | Requests | Failures | Fail % | RPS | p99 |
|---------|----------|----------|--------|-----|-----|
| retry_on_replicadrop | 850,924 | **18** | **0.002%** | 1420 | 190ms |
| retry_off_replicadrop | 692,695 | **784** | **0.11%** | 1157 | 280ms |

**Key finding**: retry makes the replica drop nearly invisible to the client — 44× failure reduction. The 784 failures in retry_off (504 gateway timeouts for in-flight requests against the draining backend) are exactly what Sai's spec describes as the cost of no-retry.

Unlike the chaos scenario, the replica drop is transient and isolated — retry's intended use case. No cascade.

---

## Exp 3 — LB horizontal scaling — `exp3/`

**Hypothesis**: adding LB instances scales throughput until Redis coordination overhead limits it.

**Setup**: homogeneous backends, `ScalingBaselineUser` at u=500 and u=2000, `ScalingSpikeUser` at u=2000, lb_count swept 1/2/4/8.

**Headline table**:

| LB | 500u RPS | 500u p99 | 2000u RPS | 2000u p99 | Spike RPS | Spike p99 |
|----|----------|----------|-----------|-----------|-----------|-----------|
| 1  | 2,427    | 370ms    | **1,188 (collapse)** | **11s**  | 1,170     | 10s       |
| 2  | 2,794    | 280ms    | 2,699     | 10s       | 2,690     | 10s       |
| 4  | 4,308    | 170ms    | 4,757     | 7.2s      | 4,746     | 6.6s      |
| 8  | 5,777    | 160ms    | 5,093     | **250ms** | 5,088     | 350ms     |

**Findings**:
1. Single LB collapses at 2000u (throughput drops 2,427 → 1,188 RPS, p99 balloons to 11s).
2. Near-linear scaling 1→2→4 at 2000u.
3. Sublinear at 4→8 (+7% RPS) but p99 drops 29× (7.2s → 250ms) — suggests bottleneck shifted off the LB.

Screenshots: `exp3/lb1_u2000/dashboard.png`, `lb2_u2000/`, `lb4_u2000/`, `lb8_u2000/`, and a wide `dashboard_overview_u2000.png` covering the whole 4-run arc at 00:01→00:57 UTC.

### Exp 3 CPU-heavy variant — `exp3_compute/`

Same lb_count sweep but with `BackendStressUser` at u=20 × 5 min (dropped user count to avoid backend saturation cascade from the default 50k-iteration compute work).

| LB | Requests | Failures | RPS | p50 | p99 |
|----|----------|----------|-----|-----|-----|
| 1  | 14,952   | 0        | 49.9 | 54ms | 2300ms |
| 2  | 16,761   | 0        | 55.97 | 16ms | 2000ms |
| 4  | 17,250   | 0        | 57.59 | 18ms | 2100ms |
| 8  | 16,606   | 0        | 55.44 | 18ms | 2100ms |

**Finding**: scaling plateaus at lb=2. CPU-bound backend work makes backends the bottleneck earlier than LB. p99 is dominated by `/api/stream`'s inherent 2-second hold, not by LB latency. **Different scaling story** from /api/data: under real CPU work, extra LB capacity past 2 tasks provides no throughput gain.

### Exp 3b inconclusive (documented negative result) — `exp3b/`

Early attempts ran `BackendStressUser` / `ScalingBaselineComputeUser` at u=50-500 with default 50k-iteration compute. All cascaded to 94-99% failure because backends saturate so hard that `/health` probes queue behind compute work and time out, triggering the health checker's DOWN-mark. Documented in `exp3b/README.md` with `locust.log` files.

---

## Cross-experiment summary table

| Experiment | Setup | Result |
|-----------|-------|--------|
| Exp 1 weighted hetero /api/data | u=500, 2 LB, strong+weak | 70/30 split holds; LB is bottleneck |
| Exp 1 robustness homo RR mix | u=20, 2 LB | 0 failures, p99 2.1s (stream-bound) |
| Exp 2 Part A high chaos (/api/data) | 30% chaos × retry on/off × 50/100/200u | 99% fail retry_on; 29% retry_off |
| Exp 2 Part A low chaos (/api/data) | 14% chaos × retry on/off × 50/100/200u | 91-98% fail retry_on; 9% retry_off |
| Exp 2 Part A low chaos /api/compute | same but /api/compute | identical pattern → cascade is endpoint-agnostic |
| Exp 2 Part B replica drop /api/data | u=200 × 10min × retry on/off × drop one replica | retry_on 0.002% fail; retry_off 0.11% fail (44× gap) |
| Exp 3 scaling /api/data | 1/2/4/8 LB × 500u/2000u/spike | lb=1 collapses at 2000u; near-linear 1→4; sublinear 4→8 |
| Exp 3 scaling CPU-heavy | 1/2/4/8 LB × u=20 BackendStressUser | plateaus at lb=2; backends bottleneck |
| Exp 3b inconclusive | default compute at u=50-500 | cascade; documented negative result |

---

## Infrastructure summary

- **Terraform**: `terraform/` with modules for network, ecr, ecs-lb, ecs-backend, nlb, elasticache, autoscaling, logging, locust. Plus a CloudWatch dashboard resource at `terraform/dashboard.tf`.
- **Locust runner**: `terraform/modules/locust/` — single `c6i.xlarge` EC2 driven via AWS SSM Run Command, no SSH keys. Results land in S3.
- **Helper scripts**: `scripts/run_locust.sh` (per-run driver), `scripts/run_locust_with_replica_drop.sh` (Part B coordinator), `scripts/capture_lb_metrics.sh` (per-task /metrics snapshot).
- **Code changes landed on main**:
  - `config.yaml`: `retries_enabled` flag
  - `internal/config/`: env-var override for `RETRIES_ENABLED`
  - `internal/proxy/`: retries-disabled gate
  - `cmd/backend/main.go`: `handleChaos` helper, applied on both /api/data and /api/compute
  - `locust/locustfile.py`: added `ChaosInjectionComputeUser`, `ScalingBaselineComputeUser`, `ScalingSpikeComputeUser`; `ChaosInjectionUser` task weights dialed down per Sai's guidance

---

## Open items for the teammate

1. **CloudWatch screenshots**: captured for Exp 1 (6 shots), Exp 2 200u dashboards + Locust PDFs, Exp 3 u=2000 per-lb dashboards + wide overview. Still missing: dashboards for Phase 2-5 new runs (Part B replica drop, low-chaos repeat, CPU-heavy compute chaos, Exp 3 CPU-heavy scaling, Exp 1 robustness). CloudWatch metrics persist 15 days — capture from the dashboard URL using the UTC run windows noted in each run's `run.txt` / the HANDOFF table timestamps.
2. **Exp 1 robustness matrix**: spec allows subset (done). If teammate wants the full 6-cell matrix, re-provisioning dual-tier + 3 policies × 2 topologies = ~80 min extra.
3. **Report writing**: teammate's job. HANDOFF.md above has pre-digested numbers + mechanism explanations for each experiment.

---

## AWS teardown

All infra destroyed after final runs. Verification commands returned empty (no running resources):

- `aws ec2 describe-instances --filters Name=instance-state-name,Values=running`
- `aws ecs list-clusters`
- `aws elasticache describe-cache-clusters`
- `aws s3 ls` (no ha-l7-lb prefixes)

Session AWS cost: ~$5-6 (personal account).
