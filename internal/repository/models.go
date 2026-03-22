package repository

import (
	"net/url"
	"sync/atomic"
	"time"
)

// ServerState represents the runtime state of a single backend server.
// Instances are created during startup and dynamic discovery, then mutated in place.
//
// Healthy is an atomic.Bool so it can be read lock-free from health checkers,
// metrics handlers, and proxy retry paths without acquiring InMemory.mu.
// ActiveConnections is similarly managed via atomic operations.
type ServerState struct {
	ServerURL         url.URL
	Weight            int        // Base weight assigned to the backend.
	Healthy           atomic.Bool // Atomic. Read lock-free by health checker and proxy.
	LastCheck         time.Time  // Guarded by InMemory.mu. Timestamp of last health state change.
	ActiveConnections int64      `redis:"active_connections"` // Atomic. Tracks in-flight proxied requests.
}

// IsHealthy returns the current health status using an atomic load.
func (s *ServerState) IsHealthy() bool {
	return s.Healthy.Load()
}

// SetHealthy updates the health status using an atomic store.
func (s *ServerState) SetHealthy(healthy bool) {
	s.Healthy.Store(healthy)
}

// GetActiveConnections returns the current in-flight request count
// using an atomic load. This avoids requiring a mutex lock on the
// read path, which is critical for LeastConnections under high QPS.
func (s *ServerState) GetActiveConnections() int64 {
	return atomic.LoadInt64(&s.ActiveConnections)
}

// AddConnections atomically adjusts the connection counter.
// Pass a positive value to increment (request start) or a negative
// value to decrement (request end). Atomicity ensures correctness
// when multiple proxy goroutines modify the same backend concurrently.
func (s *ServerState) AddConnections(connections int64) {
	atomic.AddInt64(&s.ActiveConnections, connections)
}
