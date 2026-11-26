package dirty

import (
	"testing"

	"gotest.tools/v3/assert"
)

// Reproduces TLC counterexamples from DirtySyncMap.tla against tsc/internal/project/dirty/syncmap.go.

func TestReproDirtySyncMapLostDelete(t *testing.T) {
	// TLC trace (NoLostDelete, 10 states):
	// Two goroutines hold clean handles e1, e2 from base.
	// e1.Change puts e1 into m.dirty.
	// e2.Delete loses LoadOrStore, locks e1.mu, and erroneously sets e2.delete = true
	// instead of e1.delete = true (syncmap.go:151). The delete is silently lost!
	m := NewSyncMap(map[string]*testValue{
		"k": {data: "base"},
	})
	e1, ok1 := m.Load("k")
	e2, ok2 := m.Load("k")
	assert.Assert(t, ok1 && ok2)

	e1.Change(func(v *testValue) { v.data = "modified" })
	e2.Delete()

	if _, stillExists := m.Load("k"); stillExists {
		t.Fatalf("BUG REPRODUCED (NoLostDelete): key 'k' still exists in SyncMap after e2.Delete()")
	}
	finalMap, _ := m.Finalize()
	if _, stillExists := finalMap["k"]; stillExists {
		t.Fatalf("BUG REPRODUCED (NoLostDelete): key 'k' survived Finalize() after e2.Delete()")
	}
}

func TestReproDirtySyncMapDeleteThenChangeNilPanic(t *testing.T) {
	// TLC trace (NoNilClonePanic, 6 states):
	// w1 loads clean handle e1 from base.
	// w2 calls m.Delete("k"), inserting &SyncMapEntry{original: base["k"], delete: true}
	// with value == nil and dirty == false (syncmap.go:254-259).
	// w1 calls e1.Change(...), loses LoadOrStore, sees !entry.dirty, calls entry.value.Clone() on nil -> PANIC!
	m := NewSyncMap(map[string]*testValue{
		"k": {data: "base"},
	})
	e1, ok := m.Load("k")
	assert.Assert(t, ok)

	m.Delete("k")

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("BUG REPRODUCED (NoNilClonePanic): e1.Change panicked after m.Delete: %v", r)
		}
	}()
	e1.Change(func(v *testValue) { v.data = "mutated" })
}

func TestReproDirtySyncMapChangeIfTOCTOU(t *testing.T) {
	// TLC trace (NoChangeIfTOCTOU, 12 states):
	// e1 and e2 both load clean base ("initial").
	// e1.Change updates dirty value to "updated".
	// e2.ChangeIf checks cond(e2.value) on stale base ("initial" == true),
	// then proxies to e1 in changeLocked and runs apply(e1.value) WITHOUT re-checking cond!
	m := NewSyncMap(map[string]*testValue{
		"k": {data: "initial"},
	})
	e1, _ := m.Load("k")
	e2, _ := m.Load("k")

	e1.Change(func(v *testValue) { v.data = "updated" })

	var sawInApply string
	changed := e2.ChangeIf(
		func(v *testValue) bool { return v.data == "initial" },
		func(v *testValue) {
			sawInApply = v.data
			v.data = "corrupted"
		},
	)
	if changed {
		t.Fatalf("BUG REPRODUCED (NoChangeIfTOCTOU): ChangeIf ran apply when actual value was %q (cond required %q)", sawInApply, "initial")
	}
}

func TestReproDirtySyncMapMutatesDeletedEntry(t *testing.T) {
	// TLC trace (NoMutateDeleted, 9 states):
	// e1 and e2 both load clean handles.
	// e1.Delete() stores e1 in m.dirty with delete: true, dirty: false, value: base.
	// e2.Change(apply) proxies to e1, clones and runs apply on the already-deleted entry!
	m := NewSyncMap(map[string]*testValue{
		"k": {data: "base"},
	})
	e1, _ := m.Load("k")
	e2, _ := m.Load("k")

	e1.Delete()

	applied := false
	e2.Change(func(v *testValue) {
		applied = true
		v.data = "zombie"
	})
	if applied {
		t.Fatalf("BUG REPRODUCED (NoMutateDeleted): Change ran apply on an already-deleted entry")
	}
}

func TestReproDirtySyncMapLockedProxyLostDelete(t *testing.T) {
	// TLC trace (NoLostDelete via Locked):
	// e1 is in m.dirty; clean e2 calls Locked(func(v) { v.Change(...); v.Delete() }).
	// First v.Change sets e2.proxyFor = e1, e2.dirty = true, and unlocks e1.mu.
	// Second v.Delete hits e2.deleteLocked() -> if e.dirty { e.delete = true; return }
	// WITHOUT locking or updating e1.delete!
	m := NewSyncMap(map[string]*testValue{
		"k": {data: "base"},
	})
	e1, _ := m.Load("k")
	e2, _ := m.Load("k")

	e1.Change(func(v *testValue) { v.data = "v1" })

	e2.Locked(func(v Value[*testValue]) {
		v.Change(func(val *testValue) { val.data = "v2" })
		v.Delete()
	})

	if _, stillExists := m.Load("k"); stillExists {
		t.Fatalf("BUG REPRODUCED (LockedProxyLostDelete): key 'k' still exists after e2.Locked({Change; Delete})")
	}
}

func TestReproDirtySyncMapLockedProxyDataRace(t *testing.T) {
	// TLC trace (NoDataRace, 15 states):
	// Run with `go test -race`!
	// e1 is in m.dirty. Clean e2 calls Locked(func(v) { v.Change(f1); v.Change(f2) }).
	// First v.Change(f1) sets e2.proxyFor = e1, e2.value = e1.value, e2.dirty = true, and releases e1.mu.
	// Second v.Change(f2) hits fast path `if e.dirty { apply(e.value); return }` WITHOUT locking e1.mu!
	// Concurrently, goroutine 2 calls e1.Change(f3) holding e1.mu -> TRUE GO DATA RACE on *testValue!
	m := NewSyncMap(map[string]*testValue{
		"k": {data: "base"},
	})
	e1, _ := m.Load("k")
	e2, _ := m.Load("k")

	e1.Change(func(v *testValue) { v.data = "dirty" })

	// Start both mutations from a common start gate (no happens-before between the two writes).
	startRace := make(chan struct{})
	inSecond := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		e2.Locked(func(v Value[*testValue]) {
			v.Change(func(val *testValue) { val.data = "first" })
			// Now e2.dirty == true, e2.proxyFor == e1, and e1.mu is UNLOCKED!
			v.Change(func(val *testValue) {
				close(inSecond)
				<-startRace
				val.data = "second_unlocked_race"
			})
		})
	}()

	<-inSecond
	done2 := make(chan struct{})
	go func() {
		defer close(done2)
		<-startRace
		e1.Change(func(val *testValue) {
			val.data = "concurrent_under_e1_mu"
		})
	}()

	close(startRace)
	<-done
	<-done2
}
