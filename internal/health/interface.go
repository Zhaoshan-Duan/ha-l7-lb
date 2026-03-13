package health

import "net/url"

// StatusUpdater abstracts the mechanism for persisting and propagating
// backend health state changes. The RedisManager implements this by
// writing to Redis and publishing on Pub/Sub, enabling cross-instance
// state synchronization.
//
// The proxy also calls this interface when a request fails, allowing
// immediate failure propagation without waiting for the next health
// check cycle.
type StatusUpdater interface {
	UpdateBackendStatus(url url.URL, status string) error
}
