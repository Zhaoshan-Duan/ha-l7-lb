package repository

import (
	"net/url"
	"sync/atomic"
	"time"
)

// ServerState represents the runtime state of a single backend server.
// Instances are created during startup and dynamic discovery, then mutated in place.
//
// The Healthy and LastCheck fields are protected by the InMemory mutex.
// ActiveConnections is managed via atomic operations because it is read
// by the LeastConnections algorithm on the hot path without holding the
// mutex, avoiding lock contention under high request concurrency.
type ServerState struct {
	ServerURL         url.URL
	Weight            int       // Base weight assigned to the backend.
	Healthy           bool      // Guarded by InMemory.mu. Updated by health checker and proxy.
	LastCheck         time.Time // Guarded by InMemory.mu. Timestamp of last health state change.
	ActiveConnections int64     `redis:"active_connections"` // Atomic. Tracks in-flight proxied requests.
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
