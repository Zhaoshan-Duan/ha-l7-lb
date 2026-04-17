# Final Experiment Runs — Command Reference

Pre-written commands for every run in Exp 1, 2, 3. Copy-paste in order.
Assumes `terraform apply` succeeded and outputs are populated.

## Environment sanity check (before each experiment)

```bash
cd terraform
terraform output nlb_dns_name
terraform output locust_instance_id
terraform output locust_results_bucket
curl -sS "http://$(terraform output -raw nlb_dns_name)/health" | jq
curl -sS "http://$(terraform output -raw nlb_dns_name)/health/backends" 2>/dev/null || \
  echo "(NLB only exposes :80 → LB:8080; /health/backends lives on LB:9080 — use capture_lb_metrics.sh)"
```

---

## Exp 1 — Weighted on heterogeneous backends (1 run, ~5 min)

Branch: `exp/1-weighted-hetero`
Config: `policy=weighted`, strong=70 / weak=30, LB count=2, backends 1+1.

```bash
./scripts/run_locust.sh exp1/weighted_hetero_70_30 AlgorithmCompareUser 500 5

# Mid-run: capture per-backend distribution (proves 70/30 split)
./scripts/capture_lb_metrics.sh exp1/weighted_hetero_70_30

# After run: pull artifacts local
aws s3 sync s3://$(cd terraform && terraform output -raw locust_results_bucket)/exp1/ \
  results/final/exp1/
```

Screenshot during the run: CloudWatch dashboard, ECS Services page (both api-backend-strong & api-backend-weak), NLB Monitoring tab.

---

## Exp 2 — Chaos / retry efficacy (6 runs × ~5 min = ~35 min + toggles)

Branch: `exp/2-chaos-retry` (code lives on main; branch is data-only).
Switch to main single-tier backends first; apply.

### Variant A — retries ON (default)

```bash
./scripts/run_locust.sh exp2/retry_on_50  ChaosInjectionUser  50 5
./scripts/run_locust.sh exp2/retry_on_100 ChaosInjectionUser 100 5
./scripts/run_locust.sh exp2/retry_on_200 ChaosInjectionUser 200 5
./scripts/capture_lb_metrics.sh exp2/retry_on_200   # capture at highest load
```

### Toggle: retries OFF

```bash
cd terraform
terraform apply -auto-approve -var=retries_enabled=false
# Wait ~2 min for ECS rolling restart
aws ecs describe-services --cluster $(terraform output -raw lb_cluster_name) \
  --services ha-l7-lb-lb --query 'services[].deployments[].[status,rolloutState]' --output table
cd ..
```

### Variant B — retries OFF

```bash
./scripts/run_locust.sh exp2/retry_off_50  ChaosInjectionUser  50 5
./scripts/run_locust.sh exp2/retry_off_100 ChaosInjectionUser 100 5
./scripts/run_locust.sh exp2/retry_off_200 ChaosInjectionUser 200 5
./scripts/capture_lb_metrics.sh exp2/retry_off_200
```

Restore retries ON:

```bash
cd terraform && terraform apply -auto-approve -var=retries_enabled=true && cd ..
```

Pull artifacts:

```bash
aws s3 sync s3://$(cd terraform && terraform output -raw locust_results_bucket)/exp2/ \
  results/final/exp2/
```

Screenshots per variant: ideally CloudWatch dashboard for the 200u runs (where signal is strongest).

---

## Exp 3 — Horizontal scaling (12 runs + 4 spikes = ~80 min + tf toggles)

Branch: `exp/3-scaling` (data-only; lb_count is a tf var).

### lb_count = 1

```bash
cd terraform && terraform apply -auto-approve -var=lb_count=1 && cd ..
# Wait for scaling to settle (~2 min)
./scripts/run_locust.sh exp3/lb1_u500   ScalingBaselineUser  500 5
./scripts/run_locust.sh exp3/lb1_u2000  ScalingBaselineUser 2000 5
./scripts/run_locust.sh exp3/lb1_spike  ScalingSpikeUser    2000 3
```

### lb_count = 2

```bash
cd terraform && terraform apply -auto-approve -var=lb_count=2 && cd ..
./scripts/run_locust.sh exp3/lb2_u500   ScalingBaselineUser  500 5
./scripts/run_locust.sh exp3/lb2_u2000  ScalingBaselineUser 2000 5
./scripts/run_locust.sh exp3/lb2_spike  ScalingSpikeUser    2000 3
```

### lb_count = 4

```bash
cd terraform && terraform apply -auto-approve -var=lb_count=4 && cd ..
./scripts/run_locust.sh exp3/lb4_u500   ScalingBaselineUser  500 5
./scripts/run_locust.sh exp3/lb4_u2000  ScalingBaselineUser 2000 5
./scripts/run_locust.sh exp3/lb4_spike  ScalingSpikeUser    2000 3
```

### lb_count = 8

```bash
cd terraform && terraform apply -auto-approve -var=lb_count=8 && cd ..
./scripts/run_locust.sh exp3/lb8_u500   ScalingBaselineUser  500 5
./scripts/run_locust.sh exp3/lb8_u2000  ScalingBaselineUser 2000 5
./scripts/run_locust.sh exp3/lb8_spike  ScalingSpikeUser    2000 3
```

Pull all Exp 3 artifacts:

```bash
aws s3 sync s3://$(cd terraform && terraform output -raw locust_results_bucket)/exp3/ \
  results/final/exp3/
```

Critical screenshots:
- Redis CloudWatch panel at each lb_count (watch for CPU climb as count grows)
- ECS LB service page showing N tasks at each step (visually confirms scaling)
- Dashboard for u2000 run at each lb_count

---

## Final teardown

```bash
cd terraform && terraform destroy -auto-approve
aws ec2 describe-instances --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' --output text
aws ecs list-clusters --output text
aws elasticache describe-cache-clusters --query 'CacheClusters[].CacheClusterId' --output text
aws s3 ls | grep ha-l7-lb
```

All four should return empty.
