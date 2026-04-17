# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

High-Availability Layer 7 Load Balancer with distributed state coordination via Redis Pub/Sub. Custom Go reverse proxy with pluggable routing algorithms, active health checking, idempotent-method retry logic, and DNS-based service discovery. Deployed on AWS ECS Fargate via modular Terraform.

## Architecture

```
Client -> NLB (L4) -> LB ECS tasks (L7) -> Backend ECS tasks
                           |
                     ElastiCache Redis (Pub/Sub state sync)
                           |
                     Cloud Map DNS (service discovery)
```

The LB discovers backends dynamically via AWS Cloud Map DNS polling (every 5s), not static config. Each configured backend endpoint spawns its own DNS watcher with a `sourceTag`, so multiple DNS sources (e.g., `api-strong.internal` and `api-weak.internal`) coexist in one pool without overwriting each other. Backends inherit the `weight` from their config entry, enabling heterogeneous weighted routing. Redis Pub/Sub synchronizes health state across horizontally scaled LB instances. The proxy retries failed requests only for idempotent methods (GET, PUT, DELETE) on a different backend, subject to a retry budget cap.

**Degraded mode:** Redis is optional. If unavailable at startup, the LB logs a warning and runs with local-only health state (no cross-instance sync). The `health.StatusUpdater` and proxy both nil-check the updater before calling it.

## Key Interfaces and Data Flow

All subsystems communicate through four interfaces in `internal/`:

- **`repository.SharedState`** — Backend pool operations (get healthy, mark health, connection tracking, source-scoped sync). `InMemory` is the sole implementation; Redis syncs state across instances but does not replace it. `SyncServersBySource(sourceTag, urls, weight)` reconciles only backends belonging to a given DNS source, preserving other sources' backends.
- **`algorithms.Rule`** — `GetTarget(*SharedState, *http.Request) (url.URL, error)`. Three implementations: `RoundRobin` (atomic counter), `LeastConnections` (power of two random choices — picks 2 random backends and selects the one with fewer active connections, better for multi-LB deployments with local-only counters), `Weighted` (proportional distribution).
- **`health.StatusUpdater`** — Propagates health changes to Redis. May be nil in degraded mode. The health checker always updates local state via `pool.MarkHealthy()` first, then propagates to Redis if the updater is non-nil.
- **`metrics.Collector`** — Request-level recording (latency, success, timeout, retry flags) and time-series snapshots. Latency samples use reservoir sampling (bounded to 10,000 entries) to maintain a representative distribution without unbounded memory growth. Exact averages are tracked separately via `latencyCount` and `latencySum`.

Startup wiring in `cmd/lb/main.go`: config → algorithm → empty InMemory pool → one DNS watcher per configured backend endpoint (each with its own sourceTag and weight, populates pool via `SyncServersBySource`) → Redis connect (optional, warns on failure) → sync local state from Redis → periodic re-sync ticker → Redis Pub/Sub watcher → health checker → metrics time-series recorder (every 5s) → metrics HTTP server (port+1000) → graceful shutdown handler (SIGTERM cancels background goroutines, drains HTTP connections via `http.Server.Shutdown` with 10s timeout, flushes metrics to disk) → reverse proxy HTTP server (foreground, blocks until shutdown) → `<-done` channel blocks `main()` until shutdown handler completes metrics flush. `NewReverseProxy` takes a `timeout time.Duration` parameter (from config) instead of using a hardcoded value.

## Concurrency Model

- **`ServerState.Healthy`** is an `atomic.Bool`. Read via `IsHealthy()`, write via `SetHealthy()`. This allows lock-free reads from the health checker, proxy retry path, and metrics server.
- **`ServerState.ActiveConnections`** uses `atomic.Int64` via `GetActiveConnections()` / `AddConnections()`. Critical for LeastConnections under high QPS.
- **`ServerState.Draining`** is an `atomic.Bool`. Read via `IsDraining()`, write via `SetDraining()`. Used by `SyncServers` and `SyncServersBySource` to gracefully drain backends removed from DNS -- if a backend has active connections, it is marked as draining and unhealthy but kept in the pool instead of being dropped immediately.
- **`ServerState.SourceTag`** is a `string` identifying which DNS source discovered this backend (e.g., `"api-strong.internal"`). Used by `SyncServersBySource` to scope reconciliation to a single source, preserving other sources' backends.
- **`InMemory.mu`** (`sync.RWMutex`) protects the servers slice and `LastCheck` timestamps. Connection and health field mutations go through atomic ops, but the mutex is still acquired to locate the correct `ServerState` by URL.
- **`metrics.Collector.mu`** (`sync.RWMutex`) serializes writes and allows concurrent reads.
- **Proxy atomics**: `activeRequests` and `activeRetries` (`atomic.Int64`) track in-flight request and retry counts for the retry budget (max 20% of in-flight requests may be retries).

## Common Commands

```bash
# Build
go build ./cmd/lb
go build ./cmd/backend

# Run locally (requires DNS resolution for api.internal; Redis optional)
go run ./cmd/lb -config config.yaml
go run ./cmd/lb -config config.yaml -metrics-out results.json
go run ./cmd/backend -port 8080

# Test
go test ./...                    # all tests
go test ./internal/proxy/        # single package
go test ./... -race              # with race detector
go test ./... -cover             # with coverage
go test -run TestCheckBackend ./internal/health/  # single test

# Docker
docker build -f Dockerfile.lb -t ha-l7-lb .
docker build -f Dockerfile.backend -t ha-l7-backend .

# Terraform (ECS/Fargate deployment)
cd terraform && terraform init && terraform apply

# Load testing (Locust UI at http://localhost:8089)
cd locust && docker-compose up
```

## Metrics & Observability

The LB runs a separate metrics HTTP server on **port+1000** (e.g., 9080 if LB listens on 8080):

- `GET /metrics` — JSON summary (total requests, latency percentiles, per-backend stats)
- `GET /metrics/timeseries` — JSON array of periodic snapshots (every 5s)
- `GET /metrics/export` — CSV download of time-series data
- `GET /health/backends` — current health status of all registered backends

On **SIGINT/SIGTERM**, the shutdown handler: (1) cancels the background context (stops health checker, DNS watcher, Redis watcher, time-series recorder, periodic sync), (2) drains in-flight HTTP connections on both the main and metrics servers (10s timeout), (3) dumps metrics summary to `-metrics-out` (default `metrics.json`) and time-series to `<metrics-out>.csv`, (4) signals `done` channel so `main()` exits. ECS sends SIGTERM on task stop, so experiment data survives scale-down.

## Configuration

`config.yaml` controls routing policy (`round-robin | least-connections | weighted`), backend endpoints, health check intervals, and Redis address. Environment overrides: `REDIS_ADDR` and `REDIS_PASSWORD` override YAML values (used by ECS task definitions to inject ElastiCache endpoint).

## Proxy Retry Behavior

The proxy enforces a **10MB max body size** via `http.MaxBytesReader` to prevent OOM, and buffers the full request body upfront for replay. Backend timeout is **configurable** via `config.yaml` (passed as `time.Duration` to `NewReverseProxy`).

**Error classification:**
- **`BackendError`** — custom error type for 5xx responses from backends. 5xx responses are treated as backend failures, triggering retry logic just like connection errors.
- **Client disconnects** (`context.Canceled`, broken pipe, connection reset) are detected via `isClientDisconnect(err)` and are NOT treated as backend failures — no DOWN marking or retry occurs.

On failure for idempotent methods:
1. Checks **retry budget**: retries are only attempted if active retries are below 20% of active in-flight requests, preventing cascading failures under load.
2. Marks the failed backend DOWN locally via `pool.MarkHealthy()`.
3. Propagates DOWN to Redis asynchronously (fire-and-forget goroutine), but only if the backend is still considered healthy (**debounced** to avoid redundant writes).
4. Re-fetches healthy backends (fresh snapshot, not stale).
5. Picks the retry target with fewest active connections from the live pool (no ephemeral pool creation).
6. Restores both `Body` and `ContentLength` before replaying.

Non-idempotent methods (POST, PATCH) are never retried.

## Experiments (Locust)

The backend supports chaos injection headers and stress endpoints for controlled testing:
- `X-Chaos-Error: <status-code>` — forces the backend to return that HTTP error (`/api/data` only)
- `X-Chaos-Delay: <ms>` — adds artificial latency (`/api/data` only)
- `GET /api/compute?iterations=N` — CPU-bound SHA-256 hashing (default 50000 iterations, max 500000). ~100-300ms on 256-CPU Fargate.
- `GET /api/payload` — returns ~1MB JSON response body for bandwidth stress testing.
- `GET /api/stream` — chunked transfer encoding, 10 chunks over ~2 seconds, holds the proxy connection open.

Five Locust classes defined in `locust/locustfile.py`:
1. `AlgorithmCompareUser` — Stateless vs. stateful routing overhead (round-robin vs. least-connections)
2. `ChaosInjectionUser` — Failure isolation and retry efficacy under chaos injection
3. `ScalingBaselineUser` — Sustained high load for horizontal scaling tests
4. `ScalingSpikeUser` — Extreme burst load to stress Redis contention (1/2/4/8 LB instances)
5. `BackendStressUser` — Mixed workload: 40% compute, 30% data, 15% payload, 15% stream

## Terraform Infrastructure

`terraform/modules/`: `network`, `ecr`, `ecs-lb`, `ecs-backend`, `nlb`, `elasticache`, `autoscaling`, `logging`. The NLB fronts LB tasks; Cloud Map provides internal DNS for backend discovery.

**Backend topology**: Two backend tiers registered to the same Cloud Map service (`api.internal`):
- **Strong backends** — 512 CPU / 1024 MB (count configurable via `backend_strong_count`)
- **Weak backends** — 256 CPU / 512 MB (count configurable via `backend_weak_count`)

Both use the same `ecs-backend` module and Docker image but differ in resource allocation. The LB starts one DNS watcher per configured backend endpoint; each watcher resolves its hostname independently and calls `SyncServersBySource` with its own `sourceTag` and `weight`, so strong and weak backends can have different weights for the Weighted algorithm. The `autoscaling` module targets 70% CPU with configurable min/max capacity.

**Key variables**: `lb_count` (default 2, change to 1/2/4/8 for Experiment 3), `backend_min` (default 2), `backend_max` (default 8), `cpu_target_value` (default 70).

**Docker builds**: Terraform's `docker_image` + `docker_registry_image` resources build and push both images to ECR on `terraform apply`.

## Module

`github.com/karthikeyansura/ha-l7-lb` — Go 1.25. Dependencies: `go-redis/v9`, `gopkg.in/yaml.v3`.
