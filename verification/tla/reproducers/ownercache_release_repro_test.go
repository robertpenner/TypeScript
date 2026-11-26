package project

import (
	"fmt"
	"testing"
	"time"
)

// TestReproOwnerCacheReleaseBlindDeleteCausesAddOwnerPanic reproduces the
// OwnerCache.Release ABA / blind-delete bug (ownercache.go:79-91,
// snapshot.go:728-735, 797-804):
//
// In a workspace where >=2 tsconfigs extend the same base tsconfig K,
// Snapshot.dispose() calls extendedConfigCache.Release(K, s1.id) twice.
// If S1's 2nd Release loads E1 and pauses before E1.mu.Lock(), S2.dispose()
// empties E1 and deletes K from c.entries, and S3 inserts a fresh live entry
// E2 via LoadAndAcquire(K, S3), then S1's 2nd Release locks dead E1, sees
// len(E1.owners) == 0, and blindly calls c.entries.Delete(K), evicting live E2.
// Cloning S3 -> S4 then hits OwnerCache.AddOwner(K, S4) and panics with:
//   panic("OwnerCache.AddOwner: entry not found")
func TestReproOwnerCacheReleaseBlindDeleteCausesAddOwnerPanic(t *testing.T) {
	const key = "/workspace/tsconfig.base.json"
	cache := NewOwnerCache[string, int, struct{}](
		func(k string, _ struct{}) int { return 1 },
		nil,
	)

	// Snapshot S1 acquires E1; cloning S1 -> S2 adds owner 2 to E1.
	cache.LoadAndAcquire(key, 1, struct{}{})
	cache.AddOwner(key, 2)

	// Snapshot S1 has 2 configs extending key: 1st Release removes owner 1.
	cache.Release(key, 1)

	// Hold E1.mu briefly so S1's 2nd Release deterministically loads E1 and
	// parks on E1.mu.Lock() (exact window at ownercache.go:80-84).
	e1, ok := cache.entries.Load(key)
	if !ok {
		t.Fatalf("expected E1 in cache")
	}
	e1.mu.Lock()

	s1Rel2Started := make(chan struct{})
	s1Rel2Done := make(chan struct{})
	go func() {
		defer close(s1Rel2Done)
		close(s1Rel2Started)
		cache.Release(key, 1)
	}()
	<-s1Rel2Started
	// Allow goroutine to execute c.entries.Load(key) and block on e1.mu.Lock().
	time.Sleep(20 * time.Millisecond)

	// While S1's 2nd Release is parked on E1.mu.Lock(), S2.dispose()
	// empties E1 and removes key from c.entries, and S3 inserts live E2.
	delete(e1.owners, 2)
	cache.entries.Delete(key)
	cache.LoadAndAcquire(key, 3, struct{}{})
	if !cache.Has(key) {
		t.Fatalf("expected live E2 for S3 in cache")
	}

	// Resume S1's 2nd Release: it locks dead E1, sees len(E1.owners) == 0,
	// and blindly calls c.entries.Delete(key), evicting S3's live E2.
	e1.mu.Unlock()
	<-s1Rel2Done

	// S3.Clone() -> S4 calls AddOwner(key, 4) while S3 is still live.
	var recovered any
	func() {
		defer func() { recovered = recover() }()
		cache.AddOwner(key, 4)
	}()
	if recovered != nil {
		t.Fatalf("BUG REPRODUCED: OwnerCache.Release blind delete evicted live S3 entry; AddOwner panicked with: %v", fmt.Sprint(recovered))
	}
}
