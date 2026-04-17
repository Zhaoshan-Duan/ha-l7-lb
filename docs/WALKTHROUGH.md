# HA L7 Load Balancer — Complete Walkthrough

A line-by-line guide to every Go source file in `ha-l7-lb`, plus example
request flows showing how the pieces fit together.

---

## Table of Contents

1. [High-Level Picture](#1-high-level-picture)
2. [Package Map](#2-package-map)
3. [`cmd/lb/main.go` — LB Entry Point](#3-cmdlbmaingo)
4. [`cmd/backend/main.go` — Backend Server](#4-cmdbackendmaingo)
5. [`internal/config`](#5-internalconfig)
6. [`internal/repository`](#6-internalrepository)
7. [`internal/algorithms`](#7-internalalgorithms)
8. [`internal/discovery`](#8-internaldiscovery)
9. [`internal/health`](#9-internalhealth)
10. [`internal/repository/redismanager`](#10-internalredismanager)
11. [`internal/proxy`](#11-internalproxy)
12. [`internal/metrics`](#12-internalmetrics)
13. [Config, Dockerfiles, Locust](#13-config-dockerfiles-locust)
14. [End-to-End Example Walkthroughs](#14-end-to-end-example-walkthroughs)

---

## 1. High-Level Picture

```
Client --> NLB (L4) --> LB ECS tasks (L7) --> Backend ECS tasks
                             |
                        ElastiCache Redis (Pub/Sub health sync)
                             |
                        Cloud Map DNS (backend discovery)
```

The load balancer is a custom Go reverse proxy that:
- Discovers backends dynamically from **Cloud Map DNS** (no static
  config), one DNS watcher per endpoint, each tagged by source.
- Routes requests via a **pluggable algorithm** (round-robin,
  least-connections, weighted).
- **Actively health-checks** every backend; failures propagate across
  LB instances through **Redis Pub/Sub**.
- **Retries idempotent requests** (GET/PUT/DELETE) on another backend
  when the first fails, subject to a 20%-of-in-flight retry budget.
- Exposes **metrics** (JSON, CSV, time-series) on port+1000.
- **Gracefully drains** on SIGTERM and flushes metrics to disk so
  experiment data survives ECS scale-down.

Redis is **optional**: if unreachable at startup, the LB degrades to
local-only health and logs a warning.

---

## 2. Package Map

| Path | Purpose |
|---|---|
| `cmd/lb` | Main LB binary. Wires subsystems and starts servers. |
| `cmd/backend` | Backend test server with chaos injection + stress endpoints. |
| `internal/config` | YAML + env-override configuration loader. |
| `internal/repository` | `SharedState` interface + `InMemory` pool + `ServerState` model. |
| `internal/repository/redismanager` | Cross-instance health sync via Redis Pub/Sub. |
| `internal/algorithms` | `Rule` interface + RoundRobin / LeastConnections / Weighted. |
| `internal/discovery` | DNS watcher goroutine for Cloud Map service discovery. |
| `internal/health` | Active HTTP health checker + `StatusUpdater` interface. |
| `internal/proxy` | L7 reverse proxy with buffered-body retry logic. |
| `internal/metrics` | Thread-safe request and time-series metrics collector. |

The **four core interfaces** decouple everything:

- `repository.SharedState` — backend pool operations.
- `algorithms.Rule` — backend selection strategy.
- `health.StatusUpdater` — health change propagation (Redis or nil).
- `metrics.CollectMetrics` — request recording + snapshots.

---

## 3. `cmd/lb/main.go`

**314 lines.** Startup orchestrator. Wires every subsystem in a fixed
order, then hands control to the HTTP server.

### Imports (lines 29–52)

Standard library plus the seven `internal/*` subsystems. Notable:
- `log/slog` for structured logs.
- `os/signal` + `syscall.SIGTERM` for graceful shutdown on ECS stop.

### Flags (lines 54–57)

```go
configPath = flag.String("config", "config.yaml", ...)
metricsOut = flag.String("metrics-out", "metrics.json", ...)
```

`-config` picks the YAML file; `-metrics-out` is the JSON dump path on
shutdown (a sibling `.csv` also gets written).

### `main()` startup sequence (lines 59–192)

1. **`flag.Parse()` + `config.Load(*configPath)`** — populates the
   `config.AppConfig` singleton (see §5).
2. **Algorithm selection (67–80)** — switches on `route.Policy` and
   instantiates one of `RoundRobin{}`, `LeastConnectionsPolicy{}`, or
   `Weighted{Weights: map[url.URL][]int{}}`. Unknown policy → log error
   and return (no panic — clean exit).
3. **Backend validation (82–85)** — zero backends is fatal.
4. **Empty pool (88)** — `repository.NewInMemory([]url.URL{}, []int{})`
   creates the shared state. Empty is fine because DNS watchers will
   populate it within seconds.
5. **Cancellable context (91–92)** — `ctx, cancelAll := context.WithCancel(...)`.
   Every background goroutine listens on `ctx.Done()`. `cancelAll` is
   triggered by the shutdown handler.
6. **DNS watchers (97–105)** — loops over `route.Backends` and calls
   `discovery.StartDNSWatcher` once per endpoint. The hostname doubles
   as the `sourceTag`, so strong and weak backends stay distinct in the
   pool. Each inherits its `Weight` from config.
7. **Redis wiring (109–139)** — optional:
   - If `config.AppConfig.RedisConfig != nil`, tries to `NewRedisManager`
     (which does a PING inside). Failure → warn and continue; the
     `updater` stays `nil` (degraded mode).
   - Success → `defer redisMgr.Close()`, run `SyncOnStartUp()` (pulls
     current health from Redis), start `StartPeriodicSync(ctx, 30s)`
     as a background re-sync safety net, and `StartRedisWatcher(ctx)`
     for real-time Pub/Sub updates. Assigns `updater = redisMgr`.
8. **Metrics collector (141)** — one per process, tagged with
   `route.Policy` so experiment runs are self-labeling.
9. **Reverse proxy (145)** — `proxy.NewReverseProxy(state, algo,
   collector, updater, timeout)`. `updater` may be `nil`; the proxy
   nil-checks before using it.
10. **Health checker (149–155)** — `health.NewChecker(...)` then
    `checker.Start(ctx)`. Immediate first probe + ticker loop in a
    goroutine.
11. **Metrics HTTP server (158)** — `startMetricsServer(collector,
    state, port+1000)` launches a separate `http.Server` with 4
    handlers (see below).
12. **Time-series recorder (161–174)** — anonymous goroutine, ticks
    every 5s, records `(RPS, avgLatency, activeBackends)` snapshot.
    Exits on `ctx.Done()`.
13. **Main server construction (177–179)** — `&http.Server{Addr, Handler: lb}`.
14. **Done channel + shutdown (181–182)** — `done := make(chan bool, 1)`.
    `setupGracefulShutdown` registers a SIGINT/SIGTERM handler in a
    goroutine that will eventually push `true` into `done`.
15. **`ListenAndServe` (187)** — blocks. Returns `http.ErrServerClosed`
    after `server.Shutdown` is called; any other error is fatal.
16. **`<-done` (191)** — blocks `main` until the shutdown handler has
    finished flushing metrics. This ordering guarantees the process
    doesn't exit until disk writes complete.

### `startMetricsServer` (199–263)

Creates a dedicated `http.ServeMux` with four JSON/CSV endpoints:

- **`GET /metrics`** → `collector.GetSummary()` as JSON. Point-in-time
  view (percentiles computed on the fly).
- **`GET /metrics/timeseries`** → `collector.GetTimeSeriesData()` as
  JSON array. Good for plotting RPS/latency over time.
- **`GET /metrics/export`** → writes CSV to `/tmp/metrics_export.csv`
  and serves it via `http.ServeFile`. Browser-downloadable.
- **`GET /health/backends`** → every registered backend's URL,
  `Healthy`, and `LastCheck`. Uses an inline struct for the response.

The mini-server runs inside a goroutine (`go func() { srv.ListenAndServe() }()`)
and the outer function returns the `*http.Server` so the shutdown
handler can call `Shutdown` on it.

### `setupGracefulShutdown` (268–314)

The piece that makes the LB "nice on SIGTERM":

1. `signal.Notify(c, os.Interrupt, syscall.SIGTERM)` — ECS sends
   SIGTERM on task stop, kernel sends SIGINT on Ctrl+C.
2. Background goroutine blocks on `<-c`, then:
   a. `cancelAll()` — stops health checker, DNS watchers, Redis
      watcher, periodic sync, time-series recorder.
   b. `context.WithTimeout(..., 10s)` — bounded drain.
   c. `server.Shutdown(ctx)` + `metricsServer.Shutdown(ctx)` —
      drains in-flight HTTP connections on both ports.
   d. Marshals `collector.GetSummary()` with 2-space indent and
      writes to `-metrics-out` (default `metrics.json`).
   e. Exports `<metrics-out>.csv` via `collector.ExportCSV`.
   f. `done <- true` — unblocks `main()`.

---

## 4. `cmd/backend/main.go`

**179 lines.** A throwaway HTTP backend with five endpoints used for
experiments. The key point: it knows nothing about the LB — just an
HTTP server.

### Endpoints

- **`/health` (53–56)** — unconditional 200 OK. The LB health checker
  polls this.
- **`/api/data` (59–92)** — primary workload.
  - Reads `X-Chaos-Error` header (63–71). If a parseable int ≥400,
    returns that status immediately. Used for Experiment 2.
  - Reads `X-Chaos-Delay` header (75–81). If a parseable positive int,
    sleeps that many ms. A 6000-10000ms sleep exceeds the 5s proxy
    timeout and triggers a retry.
  - Adds 5-25ms baseline random latency (83–85) simulating workload
    variance — matters for how LeastConnections spreads load.
  - Sets `X-Backend-ID` response header so Locust / curl can see
    which backend served the request.
- **`/api/compute` (98–115)** — CPU-bound SHA-256 loop. Default 50000
  iterations, clamped to ≤500000. Returns first 8 hash bytes in hex
  along with server ID.
- **`/api/payload` (120–135)** — builds ~1MB JSON (1024 × 990-char
  lines) on the fly using `fmt.Fprintf` into `w`. No buffering — tests
  the proxy's streaming `io.Copy` path.
- **`/api/stream` (140–157)** — `http.Flusher`-based chunked transfer.
  Writes 10 chunks with 200ms sleeps, total ~2s. Holds the proxy's
  upstream connection open, useful for verifying LeastConnections
  accuracy.

### `getLocalIP()` (166–179)

Walks `net.InterfaceAddrs()` and returns the first non-loopback,
non-link-local IPv4 address. Used to build `Backend-<ip>-<port>` as
the server ID — traceable in logs and response bodies.

---

## 5. `internal/config`

**100 lines, single file.** Loads YAML once via `sync.Once`, then
applies `REDIS_ADDR` / `REDIS_PASSWORD` env overrides.

### `Config` struct (31–58)

Nested anonymous structs mirror the YAML shape exactly. Key details:
- `Timeout` / `Interval` are `time.Duration` — `gopkg.in/yaml.v3`
  understands `"5s"` / `"10s"` directly.
- `RedisConfig` is a **pointer** so it can be nil when the YAML omits
  the `redis:` block. That nil is the signal for degraded mode.

### `Load(configPath string)` (68–100)

Wrapped in `once.Do` — safe to call multiple times, parses once. Steps:
1. `os.ReadFile` → fatal on error.
2. `yaml.Unmarshal` → fatal on error.
3. `REDIS_ADDR` env: if set, create the `RedisConfig` struct if nil
   (so env-only deployments work with a minimal YAML), then overwrite
   `Addr`.
4. `REDIS_PASSWORD` env: overrides `Password` only if `RedisConfig`
   exists.
5. Log the final config.

Why env overrides matter: the ECS task definition injects the
ElastiCache endpoint via `REDIS_ADDR`, so the baked-in YAML value
doesn't have to match production infrastructure.

---

## 6. `internal/repository`

### `interface.go` — `SharedState` contract

Six methods, all must be concurrency-safe:

- `GetAllServers()` — snapshot including unhealthy (for health checker).
- `GetHealthy()` — filtered for routing algorithms.
- `MarkHealthy(url, bool)` — called by health checker and proxy.
- `AddConnections` / `RemoveConnections` — for LeastConnections counters.
- `SyncServers(urls, weight)` — full-pool reconcile (unused now).
- `SyncServersBySource(tag, urls, weight)` — per-source reconcile; the
  method used by DNS watchers, preserving other sources' entries.

### `models.go` — `ServerState`

```go
type ServerState struct {
    ServerURL         url.URL
    Weight            int
    Healthy           atomic.Bool  // lock-free reads
    LastCheck         time.Time    // mu-protected timestamp
    ActiveConnections int64        // atomic int64
    Draining          atomic.Bool  // atomic
    SourceTag         string       // DNS source identifier
}
```

Why atomics? The routing hot path (`LeastConnections.GetTarget`) and
the proxy retry path read `Healthy` and `ActiveConnections` thousands
of times per second. Acquiring `InMemory.mu` for each read would
serialize goroutines. Atomic load/store lets reads go lock-free.

Helper methods wrap the atomic ops:
- `IsHealthy()` / `SetHealthy(bool)`
- `GetActiveConnections()` / `AddConnections(n)` — `n` can be negative.
- `IsDraining()` / `SetDraining(bool)`

### `in_memory.go` — `InMemory` implementation

`sync.RWMutex` + `[]*ServerState`. The mutex protects the slice
structure (insertions, removals, lookups by URL) and the `LastCheck`
field. Per-server atomics handle health and connection counts.

**Constructor `NewInMemory(urls, weights)` (27–41)** — zips the two
slices into `ServerState` pointers, all starting `Healthy=true`.

**`GetAllServers()` (47–55)** — read-lock, returns a shallow copy of
the slice. Callers can't mutate the slice, but the pointed-to
`ServerState`s are intentionally shared (so the health checker's
mutations become visible to the proxy).

**`GetHealthy()` (60–71)** — read-lock, filters via `IsHealthy()`.

**`MarkHealthy(url, bool)` (78–89)** — write-lock, linear scan for URL
match, `SetHealthy` + update `LastCheck`.

**`AddConnections` / `RemoveConnections` (94–117)** — write-lock to
locate the server by URL, then atomic add on the counter.

**`SyncServers(activeURLs, defaultWeight)` (120–170)** — full-pool
reconcile. Builds a set of the active URLs, preserves existing
`ServerState` pointers for matches (so counters aren't reset), creates
new ones for previously-unseen URLs, and **drains** removed backends:
- If a removed backend still has `ActiveConnections > 0`, mark it
  `Draining` + unhealthy and keep it in the pool. Requests already in
  flight finish; no new requests get routed (algorithms use
  `GetHealthy`).
- If a draining backend has drained to 0, drop it entirely.

**`SyncServersBySource(sourceTag, activeURLs, weight)` (177–235)** —
the same algorithm scoped to one `SourceTag`. Servers from other
sources are copied verbatim into the new slice. This is the method
DNS watchers actually call, enabling heterogeneous backend tiers.

---

## 7. `internal/algorithms`

### `interface.go` — `Rule`

```go
type Rule interface {
    GetTarget(*repository.SharedState, *http.Request) (url.URL, error)
}
```

Takes the request so future request-aware rules (e.g., IP affinity)
can read headers or `RemoteAddr`. Current implementations ignore it
(`_ *http.Request`). Contract: returns an error only when zero
healthy backends exist.

### `RoundRobin` (RoundRobin.go, 36 lines)

A single `uint64 next` counter, modified via `atomic.AddUint64`.

```go
nextVal := atomic.AddUint64(&r.next, 1)   // always > 0
index := (nextVal - 1) % uint64(len(servers))
return servers[index].ServerURL, nil
```

Why `-1`? `AddUint64` returns the **new** value. To start at index 0,
subtract 1 before modulo. Lock-free and cache-friendly; this is the
stateless baseline.

### `LeastConnectionsPolicy` (LeastConnections.go, 54 lines)

Uses **Power of Two Choices**: pick two distinct random backends,
route to whichever has fewer active connections.

```go
i := rand.Intn(len(servers))
j := rand.Intn(len(servers) - 1)
if j >= i { j++ }  // ensures j != i
```

The `j++` trick draws `j` from `[0, len-1)` and then skips over `i`,
producing two distinct indices without rejection sampling.

The comparison:
```go
a, b := servers[i], servers[j]
if a.GetActiveConnections() <= b.GetActiveConnections() {
    return a.ServerURL, nil
}
return b.ServerURL, nil
```

Both reads are lock-free `atomic.LoadInt64`. Single-backend fast path
at line 36 avoids the RNG call entirely.

Why Power of Two? With multiple LB instances each seeing only their
own local connection counts, scanning for the absolute minimum gives
synchronized herd behavior (all LBs pick the same backend, then all
pile on the next one). Randomized two-choice is provably near-optimal
even with local-only counters.

### `Weighted` (Weighted.go, 96 lines)

Decrementing counter pool with random epoch selection. Each backend
gets `[original, remaining]`; decrement on pick, reset when all
exhausted.

Uses `sync.Mutex` (actually `sync.RWMutex` but only `Lock` is called —
read paths would need to know *something*, but here every call writes,
so it's a plain mutex in practice).

Walkthrough of `GetTarget`:
1. Lock the whole thing (45).
2. Fetch healthy servers (50–56).
3. Build a `candidates []url.URL` and lazily initialize weight entries
   for new backends (59–68). `weight <= 0` falls back to 1.
4. Inner loop: pick a random candidate; if remaining > 0, break; else
   swap-delete and retry (73–82).
5. If every candidate exhausted in this epoch (`reset == true`), reset
   all counters (85–91).
6. Decrement the selected `[1]` counter, return it (94–95).

With backends A(70), B(20), C(10), 100 calls produce ~70/20/10
distribution, but in random (not sequential) order within each epoch.

---

## 8. `internal/discovery`

**`dns.go`, 60 lines.** Poll-based Cloud Map backend discovery.

### `StartDNSWatcher(ctx, sourceTag, hostname, port, scheme, weight, pool)`

1. Creates a 5-second ticker.
2. Spawns a goroutine that:
   - Runs `syncDNS` immediately on startup (pool must be populated
     before first request).
   - Loops on `<-ticker.C`, calling `syncDNS` each tick.
   - Exits on `<-ctx.Done()`.

### `syncDNS(sourceTag, hostname, port, scheme, weight, pool)`

1. `net.LookupIP(hostname)` — resolves the DNS name. AWS Cloud Map
   returns A records for each healthy ECS task.
2. DNS failure → warn and return (`empty pool stays empty; existing
   pool untouched`). This is deliberate: scaling to zero tasks
   produces NXDOMAIN, and you don't want that to wipe state.
3. IPv4-only filter (`ip.To4() != nil`).
4. Converts each IP to `scheme://ip:port` → `url.URL`.
5. `pool.SyncServersBySource(sourceTag, activeURLs, weight)` —
   reconciles just this source's servers.

---

## 9. `internal/health`

### `interface.go` — `StatusUpdater`

One method: `UpdateBackendStatus(url, status) error`.
RedisManager implements it. Proxy and Checker both hold this interface
and nil-check before calling, so degraded mode (no Redis) works without
conditional wiring.

### `checker.go` — `Checker`

```go
type Checker struct {
    pool     *repository.InMemory  // concrete type, not interface
    updater  StatusUpdater         // may be nil
    interval time.Duration
    timeout  time.Duration
    client   *http.Client
    checking atomic.Bool
}
```

Why concrete `*InMemory` instead of `SharedState` interface? The
checker uses `GetAllServers` (which is on the interface too), but
historically it needed extra pool methods; the tight coupling
reflects that the health checker is always paired with the local
store.

**`NewChecker(pool, updater, interval, timeout)` (35–50)** — builds
the `http.Client` with tuned `Transport` (100 max idle conns, 10 per
host, 90s idle timeout) and the config-supplied per-request timeout.

**`Start(ctx)` (55–72)** — immediate first `checkAll()` (so initial
backend state is validated before traffic arrives), then a ticker
goroutine. Does not block.

**`checkAll()` (77–97)**:
1. `checking.CompareAndSwap(false, true)` — if a previous wave is
   still running, skip this tick. Prevents overlapping probe storms
   when a backend hangs.
2. `sem := make(chan struct{}, 10)` — bounded concurrency: at most
   10 concurrent `/health` GETs.
3. For each backend: `wg.Add(1); sem <- {}; go checkBackend(b); defer wg.Done(); defer <-sem`.
4. `wg.Wait()`.
5. `checking.Store(false)` via `defer`.

**`checkBackend(backend)` (109–146)**:
1. Skip if `IsDraining()` — drainers are already unhealthy.
2. `hc.client.Get(url + "/health")`.
3. Healthy iff `err == nil && StatusCode == 200`. Any other outcome
   (connection refused, timeout, 500) is DOWN.
4. **State-transition only**: if `IsHealthy() != newState`, log the
   change, call `pool.MarkHealthy(...)` to update local, then
   `updater.UpdateBackendStatus(...)` to propagate via Redis
   (nil-checked). Skipping no-op writes is what keeps Redis traffic
   low on steady state.

---

## 10. `internal/repository/redismanager`

**`redis.go`, 231 lines.** The distributed health coordination layer.

### Constants (28–36)

- `PubSubChannel = "lb-backend-events"` — shared channel name across
  all LB instances.
- `KeyPrefix = "backend:"` — namespace for per-backend keys. Full key
  is e.g. `backend:http://10.0.1.5:8080`.

### `RedisManager` (46–49)

Holds a `redis.UniversalClient` + a `repository.SharedState`. Universal
means the same struct transparently handles single-node or cluster
Redis — the constructor picks.

### `NewRedisManager(addr, password, db, pool)` (58–88)

1. `strings.Split(addr, ",")` — multiple addresses → cluster mode.
2. `len(addrs) > 1` → `redis.NewClusterClient{Addrs, Password}`.
3. Else → `redis.NewClient{Addr, Password, DB}` (DB is ignored by
   clusters).
4. 5-second PING with `context.WithTimeout`. On failure, close the
   client and return a wrapped error — caller (main) decides to
   degrade.

### `UpdateBackendStatus(url, status)` (100–116)

Two-phase write inside a 2s context deadline:
1. **`SET backend:<url> <status>`** — durable, so new LB instances can
   `GET` it on startup.
2. **`PUBLISH lb-backend-events "<url>|<status>"`** — broadcast to
   existing subscribers for real-time propagation.

A slow Redis can't deadlock the proxy goroutine because the timeout
bounds the call. On error, local state is still correct; only
cross-instance propagation is lost.

### `SyncOnStartUp()` (128–158)

For every backend in the local pool:
- `GET backend:<url>` →
  - Found → `MarkHealthy(url, val == "UP")` locally.
  - `redis.Nil` (key missing) → treat as first deployment and
    `UpdateBackendStatus(url, "UP")` to initialize.
  - Other error → log and skip that backend (don't corrupt state).

Runs once on startup plus every 30s from `StartPeriodicSync`. The
periodic re-sync is a safety net for missed Pub/Sub messages (Pub/Sub
is fire-and-forget; if a subscriber is briefly disconnected, it loses
those events).

### `StartRedisWatcher(ctx)` (188–225)

Background goroutine that:
1. `sub := client.Subscribe(ctx, PubSubChannel)`.
2. Loops reading from `sub.Channel()`.
3. Splits payload on `|`. Expects exactly 2 parts; otherwise skip.
4. `url.Parse(parts[0])`, skip on error.
5. `rm.pool.MarkHealthy(*serverURL, parts[1] == "UP")`.
6. Exits on `<-ctx.Done()`, closing the subscription.

### `Close()` (228–230)

Thin wrapper — closes the underlying Redis client.

---

## 11. `internal/proxy`

**`proxy.go`, 355 lines.** The L7 reverse proxy.

### Constants

- `maxBodySize = 10 << 20` (10 MB) — cap on buffered request bodies.
  Prevents OOM when a client uploads a huge payload that would be
  double-stored (buffer + retry replay).
- `retryBudgetPct = 0.20` — max fraction of active requests allowed
  to be retries. Prevents retry storms during mass backend outages.

### `ReverseProxy` fields (49–58)

- `pool` — SharedState interface.
- `algo` — Rule interface.
- `collector` — concrete `*Collector`.
- `updater` — StatusUpdater (may be nil).
- `transport` — an `http.Transport` with 100 max idle conns total,
  20 per host, 90s idle timeout.
- `timeout` — per-backend request deadline (from YAML).
- `activeRequests`, `activeRetries` — `int64` atomics for the retry
  budget calculation.

### `ServeHTTP(w, r)` walkthrough (82–226)

1. **Active request tracking (83–84)** — `atomic.AddInt64(&activeRequests, 1)`
   then `defer` the decrement.
2. **Body buffering (87–106)**:
   - Wrap in `http.MaxBytesReader(w, r.Body, 10MB)` to enforce the cap.
   - `io.ReadAll` into `bodyBytes`.
   - Handle `http.MaxBytesError` with 413 response.
   - Close the original body.
   Buffering is necessary because `io.ReadCloser` is single-use; a
   retry needs to replay the body from memory.
3. **`resetBody` closure (110–118)** — restores `r.Body` and
   `r.ContentLength` to their pristine pre-request values for each
   proxy attempt.
4. **Early 503 (123–127)** — `pool.GetHealthy()` → empty → 503.
5. **Backend selection (130–134)** — `algo.GetTarget(&pool, r)`.
   Returns 503 on error (no healthy backends).
6. **Connection count increment (137)** — `pool.AddConnections(url, 1)`.
   Critical for LeastConnections accuracy during in-flight.
7. **First attempt (140–142)**:
   - `resetBody(r)` (inserting the first buffered replay — technically
     redundant since the first call could read from the original
     stream, but keeping it uniform avoids bugs).
   - `lb.proxyRequest(w, r, &backendURL)`.
   - `RemoveConnections` after.
8. **Success (144–147)** — record success metric, return.
9. **Client disconnect check (152–155)** — `isClientDisconnect(err)` →
   record failed metric and return. Do **not** mark backend DOWN.
10. **Retry (159–219)** — only for idempotent methods:
    - **Budget check (161–166)** — if
      `activeRetries / activeRequests > 0.20`, skip retry.
    - **Debounced DOWN marking (170–192)** — check if backend is
      already unhealthy; if not, `MarkHealthy(url, false)` and fire
      an async `updater.UpdateBackendStatus(url, "DOWN")` goroutine.
      Debouncing avoids redundant Redis writes when many goroutines
      fail the same backend simultaneously.
    - **Fresh healthy list (195)** — re-fetch after marking DOWN.
    - **`selectDifferent` (196)** — picks retry target from fresh
      list, excluding the failed URL, using local connection counts.
    - **Retry attempt (198–216)**:
      - `activeRetries` increment with deferred decrement.
      - `pool.AddConnections(newURL, 1)` + defer remove.
      - `resetBody(r)`.
      - Record metric with `retried=true` on success.
11. **Final failure (222–225)** — `errors.As(err, &timeoutErr)` to
    detect timeouts, record failed metric, return 504.

### `proxyRequest(w, r, destURL)` (232–280)

1. Wrap request context with `lb.timeout` (5s default).
2. `outReq := r.WithContext(ctx)`.
3. Rewrite `URL.Scheme`, `URL.Host`, `Host`, and clear `RequestURI`
   (required by `http.Transport` for client-side requests).
4. `transport.RoundTrip(outReq)`.
5. On error: if `ctx.Err() == context.DeadlineExceeded`, return
   `TimeoutError{URL}`. Otherwise return the raw error.
6. **5xx → `BackendError`** (262–265) — drains the response body to
   `io.Discard` and returns a typed error. This is what enables
   retry on backend-reported 5xx; without it, a 500 response would
   be streamed directly to the client with no retry.
7. Normal path: `copyHeaders`, `WriteHeader(resp.StatusCode)`,
   `io.Copy(w, resp.Body)`. A mid-stream `io.Copy` error is assumed
   to be client disconnect — return `nil` so the caller doesn't
   double-write an HTTP error onto an already-committed response.

### `selectDifferent(backends, exclude, _)` (286–310)

Filters the input slice to exclude the failed URL and unhealthy
backends, then picks the one with the **fewest active connections**
via a linear scan. This works regardless of algorithm (LC, RR,
weighted) — picking the least-loaded retry target is a reasonable
universal heuristic.

### Helpers

- `isIdempotent(method)` — `GET | PUT | DELETE`.
- `isClientDisconnect(err)` — matches `context.Canceled`, `"broken pipe"`,
  `"connection reset by peer"`.
- `TimeoutError{URL}`, `BackendError{URL, StatusCode}` — typed errors
  with `Error()` implementations.
- `copyHeaders(dst, src)` — nested loop over `http.Header` maps.

---

## 12. `internal/metrics`

**`collector.go`, 299 lines.** Request-level + time-series metrics.

### `Collector` fields (28–51)

- `mu sync.RWMutex` — writers (`RecordRequest`, `RecordTimeSeriesPoint`)
  lock; readers (`GetSummary`, `GetTimeSeriesData`, `ExportCSV`) RLock.
- Counts: `totalRequests`, `successfulRequests`, `failedRequests`,
  `retriedRequests`.
- `latencies []float64` — preallocated `cap=10000`. Stores per-request
  latency in ms. Bounded via **reservoir sampling** so memory stays
  flat under long runs.
- `backendMetrics map[string]*BackendMetrics` — per-backend breakdown.
- `policyName` — algorithm label for experiment tagging.
- `timeSeriesData []*TimeSeriesPoint` — 5s snapshots.
- `startTime` — for cumulative RPS.
- `latencyCount int64`, `latencySum float64` — exact average
  independent of the sampled slice.

### Supporting types

- `BackendMetrics` — counts and cumulative latency.
- `TimeSeriesPoint` — `(Timestamp, RPS, AvgLatency, ActiveBackends)`.
- `Summary` — read-only view including computed success rate and
  percentiles.
- `BackendStats` — per-backend subset of `Summary`.

### `NewCollector(policyName)` — pre-allocates slices and sets
`startTime = time.Now()`.

### `RecordRequest(backend, latency, success, timeout, retried)` (111–157)

1. Acquire write lock.
2. Increment counts.
3. `latencyMs := float64(latency.Milliseconds())` (note: integer ms —
   sub-ms latencies round to 0).
4. Update `latencyCount` / `latencySum` for the exact average.
5. **Reservoir sampling** for `latencies`:
   - If `len < 10000`, append.
   - Else pick `j := rand.Int63n(latencyCount)`; if `j < 10000`,
     overwrite `latencies[j]`. This preserves a uniform random sample
     of all latencies over the entire run.
6. Per-backend bucket: lazy-initialize, then increment counters and
   add to `TotalLatency`.

### `RecordTimeSeriesPoint(activeBackends)` (162–180)

Write-lock, compute cumulative RPS (`totalRequests / elapsed`) and
running avg latency (`latencySum / latencyCount`), append a new
`TimeSeriesPoint`. Called every 5s from the main goroutine.

### `GetSummary()` (186–237)

1. RLock.
2. Build `Summary` with basic counts.
3. Compute percentages for `SuccessRate` and `RetryRate`.
4. For percentiles: copy `latencies` into `sorted`, `sort.Float64s`,
   then `percentile(sorted, p)`. O(n log n) on demand but not on the
   hot path (invoked only on /metrics HTTP hits or at shutdown).
5. Populate `BackendStats` from `backendMetrics`.

### `GetTimeSeriesData()` — shallow copy under RLock.

### `ExportCSV(filepath)` (252–284)

Standard `encoding/csv` usage: create file, write header row, iterate
time series, write one row per point. RLock for the duration.

### `percentile(sorted, p)` (288–299)

Nearest-rank method: `index = int(n * p / 100)`, clamped to `len-1`.
Simpler than interpolation and fine for 10k+ samples.

---

## 13. Config, Dockerfiles, Locust

### `config.yaml` (23 lines)

```yaml
load_balancer:
  port: 8080
  timeout: 5s
route:
  policy: "round-robin"
  backends:
    - endpoint: "http://api.internal:8080"
      weight: 100
health_check:
  interval: 10s
  timeout: 5s
redis:
  addr: "redis:6379"
  password: ""
  db: 0
```

- `load_balancer.port` = main port; metrics runs on `port+1000` (9080).
- `timeout` = proxy's per-request deadline.
- `route.policy` gets switched between experiments.
- `backends` is a list — add a second entry (e.g., `api-strong.internal`
  + `api-weak.internal`) for weighted heterogeneous tests.
- `health_check.interval` / `timeout` → `Checker`.
- `redis.addr` overridden by `REDIS_ADDR` env in ECS.

### `Dockerfile.lb` / `Dockerfile.backend`

Both are classic 2-stage builds:
1. `golang:1.25-alpine` builder, `CGO_ENABLED=0 GOOS=linux GOARCH=amd64`,
   `-ldflags="-s -w"` to strip debug info for smaller binaries.
2. `alpine:latest` runtime with `ca-certificates` only.

The LB image also copies `config.yaml` and exposes 8080 + 9080. The
backend image just exposes 8080.

### `locust/locustfile.py`

Five `FastHttpUser` classes, each mapping to an experiment:

- **`AlgorithmCompareUser`** (Exp 1) — 8:1:1 weighted tasks (GET data,
  health, POST data). Run once with `round-robin`, once with
  `least-connections`, compare.
- **`ChaosInjectionUser`** (Exp 2) — 6:2:1:1 (normal, 500-chaos,
  6-10s delay, health). Measures retry efficacy.
- **`ScalingBaselineUser`** / **`ScalingSpikeUser`** (Exp 3) —
  sustained vs. burst load. Re-run as `lb_count` scales 1→2→4→8.
- **`BackendStressUser`** — 4:3:2:1 (compute, data, payload, stream).
  Mixed workload realism check.

Each task uses `catch_response=True` so non-200 responses are
explicitly marked as failures in Locust stats.

---

## 14. End-to-End Example Walkthroughs

### Example A: Successful GET with round-robin

Config: `policy: round-robin`, 3 healthy backends.

1. Client → NLB → LB task A.
2. `main.go` already has the HTTP server running with `lb` as handler.
3. `ReverseProxy.ServeHTTP`:
   - `activeRequests` → 1.
   - Body is empty → `bodyBytes = nil`, `resetBody` will set
     `http.NoBody`.
   - `pool.GetHealthy()` → 3 servers.
   - `algo.GetTarget(&pool, r)` → `RoundRobin.GetTarget`:
     - `atomic.AddUint64(&r.next, 1)` returns, say, 7.
     - `index = 6 % 3 = 0` → `servers[0].ServerURL`.
   - `pool.AddConnections(url, 1)` → backend[0] counter becomes e.g. 12.
   - `proxyRequest(w, r, &url)`:
     - 5s context.
     - Rewrite URL (scheme/host) on `outReq`.
     - `RoundTrip` → backend returns 200 OK in 18ms.
     - `copyHeaders(w.Header(), resp.Header)`.
     - `w.WriteHeader(200)`.
     - `io.Copy(w, resp.Body)` streams the JSON body.
     - Return `nil`.
   - `pool.RemoveConnections(url, 1)` → counter 11.
   - `collector.RecordRequest(url, 18ms, true, false, false)`.
   - `defer activeRequests -= 1`.
4. Client sees 200 OK.

### Example B: Backend returns 500 → retry on a different backend

Config: `policy: least-connections`, 3 healthy backends.
Locust sends `GET /api/data` with `X-Chaos-Error: 500`.

1. `ServeHTTP`:
   - Body buffered (empty).
   - `GetHealthy` → 3.
   - `LeastConnectionsPolicy.GetTarget`:
     - `i, j` → two distinct random indices, say 0 and 2.
     - Counters: A=8, C=5. Returns C.
   - `AddConnections(C, 1)`.
   - `proxyRequest` to C. Backend honors chaos header → returns 500.
     - `proxyRequest` detects `resp.StatusCode >= 500`, drains body,
       returns `BackendError{URL: C, StatusCode: 500}`.
   - `RemoveConnections(C, 1)`.
   - Not a client disconnect.
   - `r.Method == "GET"` → idempotent.
   - Retry budget: `activeRetries / activeRequests = 0.05 < 0.20` → proceed.
   - Debounced MarkHealthy(C, false) + fire-and-forget goroutine
     `updater.UpdateBackendStatus(C, "DOWN")` → Redis Set + Publish.
   - Other LB instances' `StartRedisWatcher` receives the message and
     marks C DOWN in their local InMemory within milliseconds.
   - `freshHealthy = GetHealthy()` → [A, B] (C just removed).
   - `selectDifferent([A, B], C, r)` → picks whichever has fewer active
     conns, say B.
   - `activeRetries += 1`.
   - `AddConnections(B, 1)`.
   - `resetBody(r)` → replays buffered body (empty here).
   - `proxyRequest(w, r, &B)` → B is healthy → 200 OK.
   - `RecordRequest(B, retryDuration, success=true, timeout=false, retried=true)`.
   - Return — client sees 200 OK. The 500 was fully masked.

On the next health check cycle, the checker notices C is back up (if
the chaos was Locust-injected and the backend itself is fine): it
flips local state and publishes `UP`, restoring C for future traffic.

### Example C: Timeout → retry

Locust sends `GET /api/data` with `X-Chaos-Delay: 8000`.

1. `ServeHTTP` picks backend A.
2. `proxyRequest`:
   - 5s `context.WithTimeout`.
   - Backend sleeps 8000ms.
   - At 5s, context deadline fires; `RoundTrip` errors.
   - `ctx.Err() == context.DeadlineExceeded` → return
     `TimeoutError{URL: A}`.
3. Back in `ServeHTTP`: not a client disconnect, idempotent →
   MarkHealthy(A, false), publish DOWN, pick B from fresh list.
4. Retry on B → 200 OK in ~15ms (B has no chaos).
5. `RecordRequest(B, retryDuration, true, false, true)`.
6. Client sees 200 OK. Net latency ≈ 5000ms + 15ms. The retry rate
   metric captures this and the p95 latency reflects it.

### Example D: POST failure — no retry

Same setup as B but POST.

1. Backend A returns 500.
2. `isIdempotent("POST")` → false.
3. Skip retry block entirely.
4. `errors.As(err, &timeoutErr)` → false.
5. `RecordRequest(A, duration, false, false, false)`.
6. `http.Error(w, "Gateway Timeout", 504)`.
7. Client sees 504. The POST was not re-executed — we avoid
   double-charging a credit card.

### Example E: DNS scale-up adds a new backend

1. ECS starts a new backend task. Cloud Map adds its IP to `api.internal`.
2. Within 5s, the DNS watcher's ticker fires `syncDNS`:
   - `net.LookupIP("api.internal")` returns 4 IPs instead of 3.
   - `SyncServersBySource("api.internal", 4urls, weight)`:
     - Three existing matches → preserved (connection counters intact).
     - One new URL → fresh `ServerState` with `Healthy=true`.
3. Algorithms immediately see 4 healthy backends. The first probe from
   the health checker (within 10s) confirms the new backend is actually
   up, or marks it down if the task is still starting.

### Example F: Graceful shutdown during experiment

1. ECS sends SIGTERM (task stopping).
2. Signal handler in `setupGracefulShutdown` fires:
   - `cancelAll()` → DNS watcher, health checker, Redis watcher,
     periodic sync, time-series recorder all exit via `ctx.Done()`.
   - `server.Shutdown(10s ctx)` — stops accepting new connections,
     drains existing ones for up to 10 seconds.
   - Same for `metricsServer`.
   - `collector.GetSummary()` → marshal → `metrics.json`.
   - `collector.ExportCSV("metrics.json.csv")`.
   - `done <- true`.
3. `main()` unblocks from `<-done` and exits cleanly.

Experiment data survives because the dump happens **before** the
process exits, and ECS honors the 30s grace period by default (so 10s
shutdown fits comfortably).

---

## Appendix: Where to Look First for Specific Concerns

| Concern | File(s) |
|---|---|
| "Why does my request hang?" | `proxy.go` ctx timeout, `config.yaml` `timeout` |
| "Why isn't traffic spreading evenly?" | `LeastConnections.go` (P2C) vs. `RoundRobin.go` |
| "Why aren't new ECS tasks receiving traffic?" | `discovery/dns.go`, `in_memory.go` SyncServersBySource |
| "Why is Redis churning on writes?" | `checker.go` state-transition-only + `proxy.go` debounced mark |
| "Why did my experiment data get lost?" | `main.go` setupGracefulShutdown + `collector.go` ExportCSV |
| "Why are retries sometimes skipped?" | `proxy.go` retry budget (20% cap) |
| "Why does an empty DNS result not wipe backends?" | `dns.go` `if len(activeURLs) > 0` guard |
| "Why don't POSTs retry?" | `proxy.go` `isIdempotent` |
