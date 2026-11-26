package fswatch

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type hookWatcherImpl struct {
	watcherBase
	onSubscribe  func(dw *dirWatch)
	onCloseWatch func(dw *dirWatch)
}

func newHookWatcherImpl(onSubscribe, onCloseWatch func(dw *dirWatch)) *hookWatcherImpl {
	h := &hookWatcherImpl{
		onSubscribe:  onSubscribe,
		onCloseWatch: onCloseWatch,
	}
	h.init(h)
	return h
}

func (h *hookWatcherImpl) start() error {
	h.notifyStarted()
	return nil
}

func (h *hookWatcherImpl) subscribe(dw *dirWatch) error {
	if h.onSubscribe != nil {
		h.onSubscribe(dw)
	}
	return nil
}

func (h *hookWatcherImpl) closeWatch(dw *dirWatch) error {
	if h.onCloseWatch != nil {
		h.onCloseWatch(dw)
	}
	return nil
}

func TestReproFSWatchLifecycleDeadDebounceAndOrphanedWatch(t *testing.T) {
	// TLC traces (FSWatchLifecycle / LiveWatchHasDebounce & LiveWatchInRegistry, 8 states):
	//   H1Unwatch -> H1WatchRemove -> H1UnrefCheck -> H2GetOrCreate ->
	//   H1RemoveDirWatch (deletes dw from w.dirWatches and calls destroyDebounce,
	//   setting dw.debounce = nil) -> H2AddCallback -> H2WatchAdd.
	//
	// H2 returns a live Watch with err == nil, yet its dirWatch is orphaned from
	// w.dirWatches and has dw.debounce == nil so every future event is silently dropped.
	dir := t.TempDir()

	h1InCloseWatch := make(chan struct{})
	releaseH1 := make(chan struct{})
	var closeOnce sync.Once
	var impl *hookWatcherImpl
	w := &watcher{
		name: "hook",
		factory: func() watcherImpl {
			return impl
		},
	}
	impl = newHookWatcherImpl(nil, func(dw *dirWatch) {
		closeOnce.Do(func() {
			close(h1InCloseWatch)
			<-releaseH1
		})
	})

	h1, err := w.WatchDirectory(dir, func([]Event, error) {})
	if err != nil {
		t.Fatalf("WatchDirectory h1 failed: %v", err)
	}
	dw1 := h1.(*watch).dw

	h1Done := make(chan struct{})
	go func() {
		defer close(h1Done)
		_ = h1.Close()
	}()

	// Wait until H1 has finished unwatch (dw1.callbacks is empty) and is inside impl.watchRemove -> closeWatch.
	<-h1InCloseWatch

	// Hold dw1.mu so H1 queues first in dw1.unref and H2 queues second in dw1.addCallback
	// after obtaining dw1 from w.getOrCreateDirWatch (w.mu is not held by H1 yet).
	dw1.mu.Lock()
	close(releaseH1)
	time.Sleep(15 * time.Millisecond)

	var h2Count atomic.Int32
	var h2 Watch
	var h2Err error
	h2Done := make(chan struct{})
	go func() {
		defer close(h2Done)
		h2, h2Err = w.WatchDirectory(dir, func(events []Event, err error) {
			h2Count.Add(int32(len(events)))
		})
	}()
	time.Sleep(15 * time.Millisecond)

	// Release dw1.mu: H1 runs dw1.unref (sees empty -> w.removeDirWatch(dw1) -> destroyDebounce),
	// then H2 adds its callback and subscribes the already-destroyed dw1.
	dw1.mu.Unlock()
	<-h1Done
	<-h2Done

	if h2Err != nil {
		t.Fatalf("WatchDirectory h2 failed: %v", h2Err)
	}
	defer h2.Close()

	h2dw := h2.(*watch).dw
	h2dw.mu.Lock()
	debounceNil := h2dw.debounce == nil
	h2dw.mu.Unlock()

	w.mu.Lock()
	registered := w.dirWatches[h2dw.dir] == h2dw
	w.mu.Unlock()

	h2dw.events.create(dir + "/a.ts")
	h2dw.notify()
	time.Sleep(150 * time.Millisecond)

	if debounceNil || !registered || h2Count.Load() == 0 {
		t.Fatalf("BUG REPRODUCED (LiveWatchHasDebounce + LiveWatchInRegistry): WatchDirectory returned live Watch with err=nil, but dw.debounce==nil (%v), registeredInDirWatches=%v, delivered=%d events (permanently deaf orphaned watch)",
			debounceNil, registered, h2Count.Load())
	}
}
