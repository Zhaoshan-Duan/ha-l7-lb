# Screenshot Checklist

Take each screenshot at the specified time (mid-run vs end-of-run) and
save to the matching `results/final/<exp>/<run>/screenshots/` folder.

Naming convention: `<panel>_<time>.png` where `<time>` is `mid` or `end`.
Examples: `dashboard_mid.png`, `ecs_tasks_end.png`.

## Recommended capture tool
- Firefox Screenshot (Ctrl+Shift+S → full page)
- GNOME Screenshot / gnome-screenshot
- Flameshot: `flameshot gui`

---

## Exp 1 — weighted_hetero_70_30 (5-min run)

| # | What | Where (AWS Console path) | Time | Filename |
|---|------|--------------------------|------|----------|
| 1 | CloudWatch full dashboard | CloudWatch → Dashboards → `ha-l7-lb-ops` | end | `dashboard_end.png` |
| 2 | LB ECS service overview | ECS → Clusters → `ha-l7-lb-lb-cluster` → Services → `ha-l7-lb-lb` | mid | `ecs_lb_mid.png` |
| 3 | Backend STRONG ECS service | ECS → Clusters → `api-backend-strong-cluster` | mid | `ecs_strong_mid.png` |
| 4 | Backend WEAK ECS service | ECS → Clusters → `api-backend-weak-cluster` | mid | `ecs_weak_mid.png` |
| 5 | NLB monitoring | EC2 → Load Balancers → `ha-l7-lb-nlb` → Monitoring tab | end | `nlb_end.png` |
| 6 | LB /health/backends | Run `./scripts/capture_lb_metrics.sh exp1/weighted_hetero_70_30` (saves to S3) | mid | captured to `lb_snapshots/` |
| 7 | LB /metrics (per-backend distribution) | same capture script | end | captured to `lb_snapshots/` |

Most important: #1 (dashboard), #6 + #7 (prove the 70/30 weighted split).

---

## Exp 2 — retry on/off × 50/100/200u (6 runs)

For each of the 6 runs, capture a **minimal** set (the signal is in the CSVs):

| # | What | Path | Filename |
|---|------|------|----------|
| 1 | CloudWatch dashboard (5-min run window) | Dashboards → `ha-l7-lb-ops` | `dashboard_end.png` |
| 2 | Locust HTML report (self-generated) | Pulled to S3 automatically as `report.html` | N/A |

For the two 200u runs (retry_on_200 and retry_off_200) additionally:

| # | What | Path | Filename |
|---|------|------|----------|
| 3 | LB /metrics snapshot | `./scripts/capture_lb_metrics.sh exp2/retry_on_200` | captured |
| 4 | LB /metrics snapshot | `./scripts/capture_lb_metrics.sh exp2/retry_off_200` | captured |

The most compelling screenshot for the report: **side-by-side Locust HTML reports** for retry_on_200 vs retry_off_200. The error rate delta is the main Exp 2 finding.

---

## Exp 3 — scaling (12 baseline + 4 spike runs across lb_count=1/2/4/8)

**Per lb_count** (once each, right after tf apply completes):

| # | What | Path | Filename |
|---|------|------|----------|
| 1 | ECS LB service page showing N running tasks | ECS → `ha-l7-lb-lb-cluster` → Services → `ha-l7-lb-lb` → Tasks tab | `ecs_tasks_lb${N}.png` |

**Per baseline u2000 run** (4 total):

| # | What | Path | Filename |
|---|------|------|----------|
| 2 | Dashboard focused on **Redis CPU** panel | Dashboards → `ha-l7-lb-ops` → zoom/screenshot Redis panel | `redis_cpu_lb${N}_u2000.png` |
| 3 | LB CPU panel across all N tasks | same dashboard, LB panel | `lb_cpu_lb${N}_u2000.png` |

These Redis CPU screenshots tell the scaling story: if Redis CPU climbs linearly with lb_count, Redis is becoming the bottleneck. That's the core Exp 3 finding.

---

## Set time range on every CloudWatch screenshot

1. Open dashboard
2. Click **"custom"** button top-right
3. Switch to **"Absolute"** tab
4. Enter start = run start UTC, end = run start + duration
5. Click **"Apply"**
6. Wait ~30s for metrics to refresh
7. Screenshot

Tip: note the run start time in each `results/final/<exp>/<run>/run.txt` file so you can reproduce the window later.
