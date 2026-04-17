<!-- Generated: 2026-04-11 | Branch: feat/weighted-multi-source-discovery | Files scanned: 22 | Token estimate: ~950 -->

# Architecture

## System Diagram

```
Client
  |
  v
NLB (L4, TCP)            -- AWS Network Load Balancer
  |
  v
LB ECS tasks (L7)        -- Custom Go reverse proxy (1-8 instances)
  |         |
  |         +---> ElastiCache Redis (Pub/Sub state sync, optional)
  |
  v
Backend ECS tasks         -- Go HTTP server (auto-scaled 2-8 instances)
  ^
  |
Cloud Map DNS (api.internal)  -- Service discovery, A records per task
```

## Data Flow

1. Client sends HTTP request to NLB public DNS.
2. NLB routes TCP to one of N LB ECS tasks (round-robin at L4).
3. LB task selects a backend via configured algorithm (round-robin | least-connections | weighted).
4. LB proxies request to backend, buffering body for potential retry.
5. On backend failure (5xx, timeout, connection error) for idempotent methods: marks backend DOWN, retries on different backend (subject to 20% retry budget).
6. Health checker probes all backends every 10s via GET /health.
7. State changes propagate to Redis Pub/Sub; other LB instances apply immediately.
8. One DNS watcher per configured backend endpoint polls Cloud Map every 5s.
   Each watcher is scoped by sourceTag so multiple DNS sources (e.g.,
   api-strong.internal / api-weak.internal) coexist without overwriting
   each other's backends. Backends inherit the weight from their config entry.

## Service Boundaries

| Service | Entry Point | Port | Role |
|---------|-------------|------|------|
| Load Balancer | `cmd/lb/main.go` | 8080 (traffic), 9080 (metrics) | L7 proxy, routing, retry, health check |
| Backend | `cmd/backend/main.go` | 8080 | Workload server, chaos injection |
| Redis | ElastiCache | 6379 | Cross-instance health state sync |
| Cloud Map | DNS namespace `internal` | -- | Backend discovery (A records) |

## Package Dependency Graph

```
cmd/lb/main.go
  +-> config        (YAML + env overrides)
  +-> algorithms     (Rule interface: RoundRobin, LeastConnections, Weighted)
  +-> repository     (SharedState interface, InMemory impl, ServerState model)
  |     +-> redismanager  (Redis Pub/Sub coordination)
  +-> discovery      (per-endpoint DNS polling -> pool.SyncServersBySource)
  +-> health         (Checker, StatusUpdater interface)
  +-> metrics        (Collector, time-series, CSV export)
  +-> proxy          (ReverseProxy with retry logic)

cmd/backend/main.go
  (no internal dependencies -- standalone HTTP server)
```
