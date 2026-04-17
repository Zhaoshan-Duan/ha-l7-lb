<!-- AUTO-GENERATED: Do not edit manually. Regenerate with /update-docs. -->

# Runbook

## Deployment

### Local Development

```bash
# Terminal 1: Start backend
go run ./cmd/backend -port 8080

# Terminal 2: Start LB (edit config.yaml to point to localhost:8080)
go run ./cmd/lb -config config.yaml
```

### AWS ECS Fargate

```bash
cd terraform
terraform init
terraform plan          # Review changes
terraform apply         # Provision VPC, NLB, ECS, ElastiCache, Cloud Map

# Terraform automatically builds and pushes Docker images to ECR.
# ECS tasks start automatically after image push.
```

Key Terraform variables for experiments:
- `lb_count` -- Number of LB instances (1, 2, 4, or 8 for Experiment 3)
- `backend_min` / `backend_max` -- Backend auto-scaling range (default: 2-8)
- `cpu_target_value` -- Auto-scaling CPU target (default: 70%)

### Teardown

```bash
cd terraform
terraform destroy       # Remove all AWS resources
```

## Health Check Endpoints

| Endpoint | Port | Description |
|----------|------|-------------|
| `GET /health` | 8080 (backend) | Backend health probe (200 OK = healthy) |
| `ANY /api/data` | 8080 (backend) | Primary workload with chaos injection support |
| `GET /api/compute` | 8080 (backend) | CPU-bound SHA-256 stress (?iterations=N, default 50000) |
| `GET /api/payload` | 8080 (backend) | ~1MB JSON response for bandwidth stress |
| `GET /api/stream` | 8080 (backend) | Chunked transfer, 10 chunks over ~2s |
| `GET /health/backends` | 9080 (LB metrics) | JSON array of all backends with health status |
| `GET /metrics` | 9080 (LB metrics) | JSON summary: totals, latency percentiles, per-backend stats |
| `GET /metrics/timeseries` | 9080 (LB metrics) | JSON time-series snapshots (every 5s) |
| `GET /metrics/export` | 9080 (LB metrics) | CSV download of time-series data |

## Monitoring

### LB Metrics Server

The metrics server runs on port+1000 (e.g., 9080 if LB listens on 8080).

```bash
# Check backend health
curl http://localhost:9080/health/backends

# Get metrics summary
curl http://localhost:9080/metrics

# Export time-series CSV
curl -o metrics.csv http://localhost:9080/metrics/export
```

### ECS/CloudWatch

- LB logs: CloudWatch log group configured by Terraform `logging` module
- Backend logs: Same log group, separate stream prefix
- CPU/Memory: ECS service metrics in CloudWatch

## Common Issues

### LB reports "No healthy backends" (503)

1. Check if backends are running: `curl http://localhost:9080/health/backends`
2. Verify DNS resolution: `dig api.internal` (must return backend task IPs)
3. Check health checker interval: backends must respond to `GET /health` within timeout
4. Check ECS task status in AWS Console -- tasks may be in PENDING or STOPPED state

### Redis connection failure (degraded mode)

The LB logs a warning and continues with local-only health state. Cross-instance sync is lost.

1. Verify ElastiCache security group allows port 6379 from LB tasks
2. Check `REDIS_ADDR` environment variable in ECS task definition
3. Test connectivity: `redis-cli -h <endpoint> -p 6379 PING`

### High retry rate

If retry rate exceeds 20% of in-flight requests, the retry budget kicks in and skips retries.

1. Check which backends are failing: `curl http://localhost:9080/metrics` (look at per-backend failure counts)
2. Verify backend health: slow responses (>timeout) trigger retries
3. Check if chaos injection headers are being sent unintentionally

### Graceful shutdown not flushing metrics

On SIGTERM/SIGINT, the LB:
1. Cancels background goroutines
2. Drains HTTP connections (10s timeout)
3. Writes `metrics.json` and `metrics.json.csv`

If metrics files are missing, check ECS task stop timeout (must be >= 10s).

## Rollback

### Terraform

```bash
# Revert to previous state
cd terraform
git checkout HEAD~1 -- .
terraform apply
```

### Docker images

```bash
# Re-tag a previous image
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
docker pull <repo>:previous-tag
docker tag <repo>:previous-tag <repo>:latest
docker push <repo>:latest

# Force new ECS deployment
aws ecs update-service --cluster <name> --service <name> --force-new-deployment
```
