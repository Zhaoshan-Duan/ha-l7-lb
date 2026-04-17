<!-- AUTO-GENERATED: Do not edit manually. Regenerate with /update-docs. -->

# Contributing

## Prerequisites

- Go 1.25+
- Docker (for container builds and Locust load testing)
- Terraform 1.x (for AWS deployment)
- Python 3.x with Locust (for load testing)

## Setup

```bash
git clone https://github.com/karthikeyansura/ha-l7-lb.git
cd ha-l7-lb
go mod download
```

## Available Commands

| Command | Description |
|---------|-------------|
| `go build ./cmd/lb` | Build the load balancer binary |
| `go build ./cmd/backend` | Build the backend server binary |
| `go run ./cmd/lb -config config.yaml` | Run LB locally (requires DNS for `api.internal`) |
| `go run ./cmd/lb -config config.yaml -metrics-out results.json` | Run LB with custom metrics output path |
| `go run ./cmd/backend -port 8080` | Run backend server on specified port |
| `go test ./...` | Run all tests |
| `go test ./... -race` | Run all tests with race detector |
| `go test ./... -cover` | Run all tests with coverage report |
| `go test -run TestName ./internal/pkg/` | Run a single test in a specific package |
| `docker build -f Dockerfile.lb -t ha-l7-lb .` | Build LB Docker image |
| `docker build -f Dockerfile.backend -t ha-l7-backend .` | Build backend Docker image |
| `cd terraform && terraform init && terraform apply` | Deploy to AWS ECS Fargate |
| `cd locust && docker-compose up` | Start Locust load testing (UI at localhost:8089) |

## Configuration

Edit `config.yaml` to change:
- `load_balancer.port` -- LB listening port (default: 8080)
- `load_balancer.timeout` -- Backend request timeout (default: 5s)
- `route.policy` -- Routing algorithm: `round-robin`, `least-connections`, or `weighted`
- `route.backends[].endpoint` -- Backend discovery endpoint
- `health_check.interval` -- Health probe frequency (default: 10s)
- `health_check.timeout` -- Per-probe timeout (default: 5s)
- `redis.addr` -- Redis address (overridden by `REDIS_ADDR` env var)

## Environment Variables

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `REDIS_ADDR` | No | Overrides `redis.addr` from config.yaml. Used by ECS task definitions to inject ElastiCache endpoint. | `redis-cluster.abc123.use1.cache.amazonaws.com:6379` |
| `REDIS_PASSWORD` | No | Overrides `redis.password` from config.yaml. For authenticated Redis clusters. | `secretpassword` |

## Testing

Run all tests before submitting a PR:

```bash
go test ./... -race -cover
```

Test packages: `algorithms`, `health`, `metrics`, `proxy`, `repository`.

Packages without tests (integration-only): `cmd/backend`, `cmd/lb`, `config`, `discovery`, `repository/redismanager`.

## Code Style

- Run `gofmt` and `goimports` on all Go files
- Run `go vet ./...` for static analysis
- Follow conventional commit format: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`

## PR Checklist

- [ ] All tests pass (`go test ./... -race`)
- [ ] No race conditions detected
- [ ] Code formatted with `gofmt`
- [ ] Commit messages follow conventional format
- [ ] CLAUDE.md updated if architecture changed
