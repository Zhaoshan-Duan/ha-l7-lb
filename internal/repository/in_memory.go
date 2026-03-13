package repository

import (
	"net/url"
	"sync"
	"time"
)

// InMemory is the local, single-process implementation of SharedState.
// Each LB instance maintains its own InMemory; cross-instance consistency
// is achieved via Redis Pub/Sub (see redismanager package).
//
// Concurrency model: a sync.RWMutex protects the servers slice.
// Read operations (GetAllServers, GetHealthy) acquire RLock, allowing
// concurrent readers. Write operations (MarkHealthy, Add/RemoveConnections)
// acquire a full Lock. ActiveConnections is additionally protected by
// atomic operations at the field level for lock-free reads from algorithms.
type InMemory struct {
	mu      sync.RWMutex
	servers []*ServerState
}

// NewInMemory constructs the backend pool from a list of URLs and weights.
// All servers start as Healthy. The servers and weights slices must be
// equal in length; index i of weights corresponds to index i of servers.
func NewInMemory(servers []url.URL, weights []int) *InMemory {
	serverStates := make([]*ServerState, 0, len(servers))
	for i, server := range servers {
		serverStates = append(serverStates, &ServerState{
			ServerURL: server,
			Weight:    weights[i],
			Healthy:   true,
			LastCheck: time.Now(),
		})
	}
	return &InMemory{
		servers: serverStates,
	}
}

// GetAllServers returns a shallow copy of the server slice.
// The copy prevents callers from mutating the internal slice,
// but the pointed-to ServerState structs are shared (intentional:
// the health checker reads the Healthy field from these pointers).
func (i *InMemory) GetAllServers() ([]*ServerState, error) {
	i.mu.RLock()
	defer i.mu.RUnlock()

	result := make([]*ServerState, len(i.servers))
	copy(result, i.servers)

	return result, nil
}

// GetHealthy filters to servers with Healthy == true.
// Returns an empty (non-nil) slice when all backends are down,
// which the proxy interprets as 503 Service Unavailable.
func (i *InMemory) GetHealthy() ([]*ServerState, error) {
	i.mu.RLock()
	defer i.mu.RUnlock()

	healthy := make([]*ServerState, 0)
	for _, s := range i.servers {
		if s.Healthy {
			healthy = append(healthy, s)
		}
	}
	return healthy, nil
}

// MarkHealthy updates the Healthy flag and LastCheck timestamp.
// No-op if the URL does not match any registered server.
// This is called from two sources:
//   - The health checker, on periodic /health probe results.
//   - The Redis Pub/Sub watcher, when another LB instance detects a failure.
func (i *InMemory) MarkHealthy(serverURL url.URL, healthy bool) {
	i.mu.Lock()
	defer i.mu.Unlock()

	for _, s := range i.servers {
		if s.ServerURL == serverURL {
			s.Healthy = healthy
			s.LastCheck = time.Now()
			return
		}
	}
}

// AddConnections increments the active connection counter for a backend.
// The mutex is acquired to locate the correct ServerState by URL;
// the actual counter mutation uses atomic.AddInt64 inside AddConnections.
func (i *InMemory) AddConnections(serverURL url.URL, connections int64) {
	i.mu.Lock()
	defer i.mu.Unlock()

	for _, s := range i.servers {
		if s.ServerURL == serverURL {
			s.AddConnections(connections)
			return
		}
	}
}

// RemoveConnections decrements by passing a negated value to AddConnections.
func (i *InMemory) RemoveConnections(serverURL url.URL, connections int64) {
	i.mu.Lock()
	defer i.mu.Unlock()

	for _, s := range i.servers {
		if s.ServerURL == serverURL {
			s.AddConnections(-connections)
			return
		}
	}
}
