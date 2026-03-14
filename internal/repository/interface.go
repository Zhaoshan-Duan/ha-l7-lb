// Package repository defines the shared state abstraction for backend server
// coordination across load balancer instances.
//
// The SharedState interface decouples routing algorithms and health checkers
// from the underlying storage mechanism. The InMemory implementation provides
// a single-process store, while Redis Pub/Sub synchronizes state mutations
// across multiple LB instances for horizontal scaling (Experiment 3).
package repository

import "net/url"

// SharedState is the contract for all backend pool operations.
// Every method must be safe for concurrent use by the proxy goroutines,
// the health checker goroutine, and the Redis watcher goroutine.
type SharedState interface {
	// GetAllServers returns a snapshot of every registered backend
	// regardless of health status. Used by the health checker to
	// probe all backends on each tick.
	GetAllServers() ([]*ServerState, error)

	// GetHealthy returns only backends where Healthy == true.
	// Routing algorithms call this to exclude failed backends.
	GetHealthy() ([]*ServerState, error)

	// MarkHealthy sets the health flag for a specific backend.
	// Called by the health checker (periodic) and by the proxy
	// (on request failure, marking DOWN immediately rather than
	// waiting for the next health check cycle).
	MarkHealthy(backendURL url.URL, healthy bool)

	// AddConnections atomically increments the active connection
	// counter. Called before forwarding a request. The LeastConnections
	// algorithm reads this counter to select the least-loaded backend.
	AddConnections(serverURL url.URL, connections int64)

	// RemoveConnections atomically decrements the active connection
	// counter. Called after the proxied response completes or fails.
	RemoveConnections(serverURL url.URL, connections int64)

	// SyncServers dynamically updates the backend pool. It adds new IPs discovered
	// via DNS and removes IPs that no longer exist, while preserving the active
	// connections and health status of existing servers.
	SyncServers(activeURLs []url.URL, defaultWeight int)
}
