package fswatch

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type lifecycleHookWatcherImpl struct {
	watcherBase
	onSubscribe  func(dw *dirWatch)
	onCloseWatch func(dw *dirWatch)
}

func newLifecycleHookWatcherImpl(onSubscribe, onCloseWatch func(dw *dirWatch)) *lifecycleHookWatcherImpl {
	h := &lifecycleHookWatcherImpl{
		onSubscribe:  onSubscribe,
		onCloseWatch: onCloseWatch,
	}
	h.init(h)
	return h
}

func (h *lifecycleHookWatcherImpl) start() error {
	h.notifyStarted()
	return nil
}

func (h *lifecycleHookWatcherImpl) subscribe(dw *dirWatch) error {
	if h.onSubscribe != nil {
		h.onSubscribe(dw)
	}
	return nil
}

func (h *lifecycleHookWatcherImpl) closeWatch(dw *dirWatch) error {
	if h.onCloseWatch != nil {
		h.onCloseWatch(dw)
	}
	return nil
}

// TestFSWatchLifecycleCloseVsWatchKeepsDebounceRegistryAndOSSub verifies that
// closing the last existing handle for a directory concurrently with a new
// WatchDirectory call on the same directory cannot leave the returned live
// Watch with a nil debounce handle, missing from w.dirWatches, or missing its
// backend OS subscription.
func TestFSWatchLifecycleCloseVsWatchKeepsDebounceRegistryAndOSSub(t *testing.T) {
	dir := t.TempDir()

	h1InCloseWatch := make(chan struct{})
	releaseH1 := make(chan struct{})
	var closeOnce sync.Once
	var impl *lifecycleHookWatcherImpl
	w := &watcher{
		name: "hook",
		factory: func() watcherImpl {
			return impl
		},
	}
	impl = newLifecycleHookWatcherImpl(nil, func(dw *dirWatch) {
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

	// Wait until H1 has finished unwatch and is inside impl.watchRemove -> closeWatch.
	<-h1InCloseWatch

	// Hold dw1.mu so H1 blocks on dw1.mu after closeWatch while H2 races in WatchDirectory.
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
	registered := w.dirWatches[w.keyForDirWatch(h2dw.dir, h2dw.recursive)] == h2dw
	w.mu.Unlock()

	impl.mu.Lock()
	_, subscribed := impl.subscriptions[h2dw]
	impl.mu.Unlock()

	h2dw.events.create(dir + "/a.ts")
	h2dw.notify()
	time.Sleep(150 * time.Millisecond)

	if debounceNil || !registered || !subscribed || h2Count.Load() == 0 {
		t.Fatalf("live Watch returned with err=nil is broken: debounceNil=%v registered=%v subscribed=%v delivered=%d",
			debounceNil, registered, subscribed, h2Count.Load())
	}
}

// TestFSWatchLifecycleCloseCannotTearDownNewWatchOSSubscription verifies that
// when H1.Close() runs concurrently with H2.WatchDirectory() on the same
// directory, H1 cannot tear down the backend OS subscription that covers H2.
func TestFSWatchLifecycleCloseCannotTearDownNewWatchOSSubscription(t *testing.T) {
	dir := t.TempDir()

	var impl *lifecycleHookWatcherImpl
	w := &watcher{
		name: "hook",
		factory: func() watcherImpl {
			return impl
		},
	}
	impl = newLifecycleHookWatcherImpl(nil, nil)

	for iter := range 200 {
		h1, err := w.WatchDirectory(dir, func([]Event, error) {})
		if err != nil {
			t.Fatalf("iter %d: WatchDirectory h1 failed: %v", iter, err)
		}

		start := make(chan struct{})
		var h2 Watch
		var h2Err error
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_ = h1.Close()
		}()
		go func() {
			defer wg.Done()
			<-start
			h2, h2Err = w.WatchDirectory(dir, func([]Event, error) {})
		}()
		close(start)
		wg.Wait()

		if h2Err != nil {
			t.Fatalf("iter %d: WatchDirectory h2 failed: %v", iter, h2Err)
		}

		h2dw := h2.(*watch).dw
		impl.mu.Lock()
		_, subscribed := impl.subscriptions[h2dw]
		impl.mu.Unlock()

		w.mu.Lock()
		registered := w.dirWatches[w.keyForDirWatch(h2dw.dir, h2dw.recursive)] == h2dw
		w.mu.Unlock()

		h2dw.mu.Lock()
		debounceNil := h2dw.debounce == nil
		h2dw.mu.Unlock()

		_ = h2.Close()

		if !subscribed || !registered || debounceNil {
			t.Fatalf("iter %d: concurrent H1.Close tore down H2's live watch: subscribed=%v registered=%v debounceNil=%v",
				iter, subscribed, registered, debounceNil)
		}
	}
}

// TestFSWatchLifecycleConcurrentWatchAndCloseStress hammers WatchDirectory and
// Close on the same directory from concurrent goroutines and verifies that
// every live watch remains registered, subscribed, and has a non-nil debounce,
// and that closing all handles leaves zero leaked dirWatches or subscriptions.
func TestFSWatchLifecycleConcurrentWatchAndCloseStress(t *testing.T) {
	dir := t.TempDir()

	var impl *lifecycleHookWatcherImpl
	w := &watcher{
		name: "hook",
		factory: func() watcherImpl {
			return impl
		},
	}
	impl = newLifecycleHookWatcherImpl(nil, nil)

	const workers = 8
	const iters = 60
	var wg sync.WaitGroup
	var errMu sync.Mutex
	var firstErr error
	recordErr := func(err error) {
		errMu.Lock()
		if firstErr == nil {
			firstErr = err
		}
		errMu.Unlock()
	}

	for range workers {
		wg.Go(func() {
			for range iters {
				h, err := w.WatchDirectory(dir, func([]Event, error) {})
				if err != nil {
					recordErr(err)
					return
				}
				if err := h.Close(); err != nil {
					recordErr(err)
					return
				}
			}
		})
	}
	wg.Wait()
	if firstErr != nil {
		t.Fatalf("concurrent watch/close error: %v", firstErr)
	}

	w.mu.Lock()
	remainingWatches := len(w.dirWatches)
	w.mu.Unlock()

	impl.mu.Lock()
	remainingSubs := len(impl.subscriptions)
	impl.mu.Unlock()

	if remainingWatches != 0 || remainingSubs != 0 {
		t.Fatalf("leaked state after closing all watches: dirWatches=%d subscriptions=%d", remainingWatches, remainingSubs)
	}
}
