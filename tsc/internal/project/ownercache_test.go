package project

import (
	"testing"
	"time"

	"gotest.tools/v3/assert"
)

func TestOwnerCacheReleaseDoesNotEvictReplacedEntry(t *testing.T) {
	t.Parallel()

	const key = "/workspace/tsconfig.base.json"
	cache := NewOwnerCache[string, int, struct{}](
		func(k string, _ struct{}) int { return 1 },
		nil,
	)

	// Snapshot 1 acquires E1; cloning to snapshot 2 adds owner 2 to E1.
	cache.LoadAndAcquire(key, 1, struct{}{})
	cache.AddOwner(key, 2)

	// First Release for snapshot 1 removes owner 1 (as when two configs in one
	// snapshot share the same extended base config).
	cache.Release(key, 1)

	// Hold E1.mu so a duplicate Release(key, 1) loads E1 and blocks on E1.mu.Lock().
	e1, ok := cache.entries.Load(key)
	assert.Assert(t, ok)
	e1.mu.Lock()

	release2Started := make(chan struct{})
	release2Done := make(chan struct{})
	go func() {
		defer close(release2Done)
		close(release2Started)
		cache.Release(key, 1)
	}()
	<-release2Started
	time.Sleep(20 * time.Millisecond)

	// While the duplicate Release is blocked on E1.mu, snapshot 2 finishes
	// releasing E1 and snapshot 3 inserts a fresh live entry E2.
	delete(e1.owners, 2)
	cache.entries.Delete(key)
	cache.LoadAndAcquire(key, 3, struct{}{})
	assert.Assert(t, cache.Has(key))

	// Unblock the stale Release on dead E1; it must not delete live E2.
	e1.mu.Unlock()
	<-release2Done

	assert.Assert(t, cache.Has(key))
	cache.AddOwner(key, 4)

	// Releasing both live owners cleans up E2.
	cache.Release(key, 3)
	assert.Assert(t, cache.Has(key))
	cache.Release(key, 4)
	assert.Assert(t, !cache.Has(key))
}
