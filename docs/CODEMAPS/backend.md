<!-- Generated: 2026-04-11 | Branch: feat/weighted-multi-source-discovery | Files scanned: 22 | Token estimate: ~850 -->

# Backend Codemap

## LB HTTP Routes (port 8080)

All requests proxied to backends via `proxy.ReverseProxy.ServeHTTP`.

```
ANY /* -> proxy.ServeHTTP -> algo.GetTarget -> proxyRequest -> backend
```

## Metrics HTTP Routes (port 9080)

Defined in `cmd/lb/main.go:startMetricsServer`.

```
GET /metrics           -> collector.GetSummary()          (JSON: totals, percentiles, per-backend)
GET /metrics/timeseries -> collector.GetTimeSeriesData()  (JSON: periodic snapshots every 5s)
GET /metrics/export    -> collector.ExportCSV()            (CSV download)
GET /health/backends   -> pool.GetAllServers()             (JSON: backend URL, healthy, last_check)
```

## Backend HTTP Routes (port 8080)

Defined in `cmd/backend/main.go`.

```
GET /health       -> 200 OK (unconditional, used by health checker)
ANY /api/data     -> chaos injection check -> 5-25ms delay -> JSON response with X-Backend-ID header
GET /api/compute  -> SHA-256 hash loop (?iterations=N, default 50000) -> JSON with hash result
GET /api/payload  -> ~1MB JSON response (1024 lines x ~1000 chars) for bandwidth stress
GET /api/stream   -> chunked transfer, 10 chunks over ~2s, holds connection open
```

Chaos headers (Experiment 2, `/api/data` only):
- `X-Chaos-Error: <code>` -- forces HTTP error response (>= 400)
- `X-Chaos-Delay: <ms>` -- artificial latency injection

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `cmd/lb/main.go` | 316 | LB entry point, wiring, metrics server, graceful shutdown |
| `cmd/backend/main.go` | 180 | Backend server with chaos injection + stress endpoints |
| `internal/proxy/proxy.go` | 356 | Reverse proxy, retry logic, body buffering |
| `internal/algorithms/RoundRobin.go` | 37 | Atomic counter round-robin |
| `internal/algorithms/LeastConnections.go` | 55 | Power of Two Choices selection |
| `internal/algorithms/Weighted.go` | 97 | Proportional weight distribution |
| `internal/health/checker.go` | 147 | Periodic health probes, concurrent per-backend |
| `internal/metrics/collector.go` | 300 | Request metrics, reservoir sampling, CSV export |
| `internal/repository/in_memory.go` | 236 | InMemory SharedState with RWMutex + SyncServersBySource |
| `internal/repository/models.go` | 61 | ServerState with atomic fields + SourceTag |
| `internal/repository/redismanager/redis.go` | 231 | Redis Pub/Sub coordination |
| `internal/discovery/dns.go` | 58 | Cloud Map DNS polling |
| `internal/config/config.go` | 101 | YAML config with env overrides |

## Interface -> Implementation Map

| Interface | Package | Implementations |
|-----------|---------|-----------------|
| `algorithms.Rule` | algorithms | `RoundRobin`, `LeastConnectionsPolicy`, `Weighted` |
| `repository.SharedState` | repository | `InMemory` (includes `SyncServers` + `SyncServersBySource`) |
| `health.StatusUpdater` | health | `redismanager.RedisManager` |
| `metrics.CollectMetrics` | metrics | `Collector` |
