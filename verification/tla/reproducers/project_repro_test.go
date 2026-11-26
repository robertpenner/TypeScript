package project

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/bundled"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/project/logging"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
	"gotest.tools/v3/assert"
)

// --- Reproducers for RefCountCache (RefCountCache.tla) ---

func TestReproRefCountCacheDisableDeletionAcquireOrErrorZeroVal(t *testing.T) {
	// TLC trace (DisableDel / NoZeroValReturned, 7 states):
	// With DisableDeletion: true, AcquireOrError fails (refCount=0, Delete(k)),
	// while concurrent AcquireExisting loaded the speculative entry and blocked on entry.mu.
	// Because `entry.refCount <= 0 && !c.Options.DisableDeletion` is FALSE, AcquireExisting
	// treats the failed entry as live and returns (nil, true)!
	cache := NewRefCountCache(RefCountCacheOptions{DisableDeletion: true}, func(_ string, _ struct{}) *int {
		v := 99
		return &v
	})

	inProduce := make(chan struct{})
	finishProduce := make(chan struct{})

	var wg sync.WaitGroup
	wg.Go(func() {
		_, _ = cache.AcquireOrError("k", func() (*int, error) {
			close(inProduce)
			<-finishProduce
			return nil, errors.New("produce failed")
		})
	})

	<-inProduce

	var gotVal *int
	var gotOK bool
	aeStarted := make(chan struct{})
	wg.Go(func() {
		close(aeStarted)
		gotVal, gotOK = cache.AcquireExisting("k")
	})

	<-aeStarted
	time.Sleep(10 * time.Millisecond) // allow AcquireExisting to load entry and park on entry.mu.Lock()
	close(finishProduce)
	wg.Wait()

	if gotOK && gotVal == nil {
		t.Fatalf("BUG REPRODUCED (NoZeroValReturned): AcquireExisting returned (nil, true) from failed AcquireOrError with DisableDeletion=true")
	}
}

func TestReproRefCountCacheRefResurrectionOverwritesLiveValue(t *testing.T) {
	// TLC trace (ConcRef / NoLiveValueOverwrite, 16 states):
	// G1 acquires e1 (val=&1). Both Deref and Ref load e1 before e1.mu is released.
	// Deref runs first (deletes "k", e1.refCount=0); G3 calls Acquire("k") creating live e2 (val=&2).
	// Ref acquires e1.mu, sees e1.refCount <= 0, calls loadOrStoreNewLockedEntry("k") -> gets e2 (loaded=true),
	// ignores loaded, and overwrites e2.value = e1.value (&1)!
	var seq atomic.Int32
	cache := NewRefCountCache(RefCountCacheOptions{}, func(_ string, _ struct{}) *int {
		n := int(seq.Add(1))
		return &n
	})

	for range 64 {
		seq.Store(0)
		v1 := cache.Acquire("k", struct{}{})
		assert.Equal(t, *v1, 1)

		e1, ok := cache.entries.Load("k")
		assert.Assert(t, ok)
		e1.mu.Lock()

		derefStarted := make(chan struct{})
		derefDone := make(chan struct{})
		go func() {
			defer close(derefDone)
			close(derefStarted)
			cache.Deref("k")
		}()
		<-derefStarted
		time.Sleep(2 * time.Millisecond)

		refStarted := make(chan struct{})
		refDone := make(chan struct{})
		go func() {
			defer close(refDone)
			close(refStarted)
			cache.Ref("k")
		}()
		<-refStarted
		time.Sleep(2 * time.Millisecond)

		// Pause e2 creation in Acquire by racing right after Deref deletes "k":
		// Even simpler: unlock e1.mu and immediately spin Acquire("k") concurrently with Ref's resurrection!
		acqDone := make(chan *int, 1)
		go func() {
			<-derefDone
			acqDone <- cache.Acquire("k", struct{}{})
		}()

		e1.mu.Unlock()
		v2 := <-acqDone
		<-refDone

		eCur, ok := cache.entries.Load("k")
		assert.Assert(t, ok)
		if *v2 == 2 && eCur.value == v1 {
			t.Fatalf("BUG REPRODUCED (NoLiveValueOverwrite): Acquire returned v2=%p (*v2=%d), but Ref resurrection overwrote live cache entry with stale v1=%p (*v1=%d)", v2, *v2, eCur.value, *eCur.value)
		}
		for cache.Has("k") {
			cache.Deref("k")
		}
	}
	t.Skip("did not hit exact interleaving in 64 attempts")
}

func TestReproRefCountCacheRefResurrectsFailedAcquireOrErrorZeroVal(t *testing.T) {
	// TLC trace (ConcRef / QuiescentConsistency, 15 states):
	// G1 calls AcquireOrError("k", produceFail). While produceFail holds e1.mu (e1.value == nil),
	// G2 calls Ref("k") -> loads e1, blocks on e1.mu.Lock().
	// G1's produceFail returns error -> e1.refCount = 0, Delete("k"), unlocks e1.mu.
	// G2 wakes in Ref("k"), sees e1.refCount <= 0, resurrects e1 into a live entry with value=nil!
	cache := NewRefCountCache(RefCountCacheOptions{}, func(_ string, _ struct{}) *int {
		v := 42
		return &v
	})

	inProduce := make(chan struct{})
	finishProduce := make(chan struct{})

	var wg sync.WaitGroup
	wg.Go(func() {
		_, _ = cache.AcquireOrError("k", func() (*int, error) {
			close(inProduce)
			<-finishProduce
			return nil, errors.New("boom")
		})
	})

	<-inProduce

	refStarted := make(chan struct{})
	wg.Go(func() {
		close(refStarted)
		cache.Ref("k")
	})
	<-refStarted
	time.Sleep(10 * time.Millisecond) // allow Ref to load e1 and park on e1.mu.Lock()

	close(finishProduce)
	wg.Wait()

	val := cache.Acquire("k", struct{}{})
	if val == nil {
		t.Fatalf("BUG REPRODUCED (RefResurrectsZeroVal): Ref resurrected failed AcquireOrError entry into live cache with value=nil!")
	}
}

// --- Reproducer for Session.EnqueuePublishGlobalDiagnostics (SessionGlobalDiag.tla) ---

type blockingDiagClient struct {
	noopClient
	armed        atomic.Bool
	publishCalls atomic.Int32
	inFirstSend  chan struct{}
	releaseSend  chan struct{}
	lastDiags    []*lsproto.Diagnostic
	mu           sync.Mutex
}

func (c *blockingDiagClient) PublishDiagnostics(_ context.Context, params *lsproto.PublishDiagnosticsParams) error {
	if !c.armed.Load() {
		return nil
	}
	call := c.publishCalls.Add(1)
	c.mu.Lock()
	c.lastDiags = params.Diagnostics
	c.mu.Unlock()
	if call == 1 {
		close(c.inFirstSend)
		<-c.releaseSend
	}
	return nil
}

func TestReproSessionLostGlobalDiagnosticsNotification(t *testing.T) {
	// TLC trace (SessionGlobalDiag / NoLostGlobalDiagnostics, 7 states):
	// 1. Project checkerPool accumulates global diag #1 (globalDiagChanged = true).
	// 2. Session.EnqueuePublishGlobalDiagnostics() sets globalDiagPublishPending = true and starts publishGlobalDiagnostics.
	// 3. publishGlobalDiagnostics calls TakeNewGlobalDiagnostics() (clears flag), reads diagnostics, and calls PublishDiagnostics RPC.
	// 4. While PublishDiagnostics RPC is in flight (before `defer s.globalDiagPublishPending.Store(false)` runs!),
	//    checkerPool records global diag #2 (globalDiagChanged = true) and Session.EnqueuePublishGlobalDiagnostics() is called.
	// 5. CompareAndSwap(false, true) returns FALSE — enqueue is dropped!
	// 6. First PublishDiagnostics returns; defer sets globalDiagPublishPending = false.
	// Result: globalDiagChanged is still TRUE, globalDiagPublishPending is FALSE, and diag #2 is NEVER published!
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/src/tsconfig.json": `{ "compilerOptions": { "noLib": true } }`,
		"/src/index.ts":      "export const x: number = 1;",
	}
	fs := bundled.WrapFS(vfstest.FromMap(files, tspath.CaseInsensitive))

	client := &blockingDiagClient{
		inFirstSend: make(chan struct{}),
		releaseSend: make(chan struct{}),
	}
	session := NewSession(&SessionInit{
		BackgroundCtx: context.Background(),
		Options: &SessionOptions{
			CurrentDirectory:       "/",
			DefaultLibraryPath:     bundled.LibPath(),
			PositionEncoding:       lsproto.PositionEncodingKindUTF8,
			WatchEnabled:           false,
			PushDiagnosticsEnabled: true,
			CheckerPoolOptions:     CheckerPoolOptions{MaxCheckers: 2, IdleTimeout: time.Minute},
		},
		FS:     fs,
		Client: client,
		Logger: logging.NewTestLogger(),
	})
	defer session.Close()

	session.DidOpenFile(context.Background(), "file:///src/index.ts", 1, "export const x: number = 1;", lsproto.LanguageKindTypeScript)
	session.WaitForBackgroundTasks()
	snap := session.Snapshot()
	proj := snap.ProjectCollection.ConfiguredProject("/src/tsconfig.json")
	assert.Assert(t, proj != nil && proj.checkerPool != nil)

	client.armed.Store(true)

	// Trigger global diagnostic #1 (using real checkerPool flag set by mergeGlobalDiagnosticsFromCheckerLocked).
	proj.checkerPool.mu.Lock()
	proj.checkerPool.globalDiagChanged = true
	proj.checkerPool.mu.Unlock()

	session.EnqueuePublishGlobalDiagnostics()
	<-client.inFirstSend // publishGlobalDiagnostics is now inside PublishDiagnostics RPC!

	// While RPC #1 is in flight, global diagnostic #2 arrives!
	proj.checkerPool.mu.Lock()
	proj.checkerPool.globalDiagChanged = true
	proj.checkerPool.mu.Unlock()
	session.EnqueuePublishGlobalDiagnostics() // DROPPED because globalDiagPublishPending is still true!

	// Complete RPC #1 and wait for all background tasks to settle.
	close(client.releaseSend)
	session.WaitForBackgroundTasks()

	// At quiescence: globalDiagPublishPending == false, yet globalDiagChanged is STILL true
	// and PublishDiagnostics was only called ONCE!
	proj.checkerPool.mu.Lock()
	stillUnpublished := proj.checkerPool.globalDiagChanged
	proj.checkerPool.mu.Unlock()
	pending := session.globalDiagPublishPending.Load()
	calls := client.publishCalls.Load()

	if stillUnpublished && !pending && calls == 1 {
		t.Fatalf("BUG REPRODUCED (NoLostGlobalDiagnostics): globalDiagChanged=%v, publishPending=%v, publishCalls=%d (notification #2 permanently lost!)", stillUnpublished, pending, calls)
	}
}
