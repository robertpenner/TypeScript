package fswatch

import (
	"sync/atomic"
	"testing"
	"time"
)

func TestReproFSWatchDebounceLostTriggerOnAdd(t *testing.T) {
	// TLC trace (FSWatchDebounce / NoLostTrigger, 8 states):
	// 1. k1 is registered; TriggerKey(k1) wakes debounce.loop() -> fireCallbacks().
	// 2. fireCallbacks() snapshots d.callbacks (only {k1}), unlocks d.mu, and is about to call d.latchReset().
	// 3. Before d.latchReset() acquires d.latchMu, a new dirWatch calls d.add(k2, cb2) and d.trigger().
	//    Because d.notified is STILL true, d.trigger() does NOT close a fresh waitCh.
	// 4. fireCallbacks() acquires d.latchMu, executes d.latchReset() (setting d.notified = false and
	//    allocating a new open waitCh), and runs only {cb1}.
	// Result: loop() sleeps forever on latchWait() and cb2 is NEVER invoked!
	d := newDebounce()
	time.Sleep(10 * time.Millisecond) // wait for loop() to park on latchWait()

	var cb1Count, cb2Count atomic.Int32
	d.add("k1", func() { cb1Count.Add(1) })

	// 1. Hold d.mu so loop() pauses inside notifyIfReady() after waking.
	// (lastTime is zero, so gap > maxWaitTime -> fireCallbacks() runs immediately.)
	d.mu.Lock()
	d.trigger()                       // sets d.notified = true, wakes loop()
	time.Sleep(10 * time.Millisecond) // loop() is parked on d.mu.Lock() in notifyIfReady()

	// 2. Acquire d.latchMu NOW, and queue k2's d.trigger() FIRST on d.latchMu.
	d.latchMu.Lock()
	trigStarted := make(chan struct{})
	trigDone := make(chan struct{})
	go func() {
		defer close(trigDone)
		close(trigStarted)
		d.trigger() // queued FIRST on d.latchMu!
	}()
	<-trigStarted
	time.Sleep(10 * time.Millisecond)

	// 3. Let fireCallbacks() snapshot {k1}, unlock d.mu, and queue SECOND on d.latchMu in latchReset()!
	d.mu.Unlock()
	time.Sleep(10 * time.Millisecond)

	// 4. Register k2 AFTER fireCallbacks snapshotted {k1}.
	d.add("k2", func() { cb2Count.Add(1) })

	// 5. Release d.latchMu: queued d.trigger() runs FIRST (sees d.notified == true, no-op on waitCh!),
	//    then d.latchReset() runs SECOND (resets d.notified = false, new waitCh!),
	//    then fireCallbacks runs only {cb1}!
	d.latchMu.Unlock()
	<-trigDone

	// Wait past minWaitTime; debounce loop is stuck sleeping forever on latchWait()!
	time.Sleep(150 * time.Millisecond)

	if cb2Count.Load() == 0 {
		t.Fatalf("BUG REPRODUCED (NoLostTrigger): cb1 ran %d time(s), but newly added k2's trigger was permanently lost (cb2 ran 0 times)", cb1Count.Load())
	}
}
