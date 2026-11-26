package lspwatcher

import (
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/fswatch"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/project/logging"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
)

type fakeSub struct {
	id     int
	closed atomic.Bool
}

func (s *fakeSub) Close() error {
	s.closed.Store(true)
	return nil
}

type fakeWatchBackend struct {
	mu      sync.Mutex
	nextID  int
	subs    []*fakeSub
	cbs     []watchCallback
	onWatch func(call int, dir tspath.RootedDirectoryPath)
}

func (b *fakeWatchBackend) WatchDirectory(dir tspath.RootedDirectoryPath, fn watchCallback, _ ...fswatch.WatchOption) (io.Closer, error) {
	b.mu.Lock()
	b.nextID++
	id := b.nextID
	sub := &fakeSub{id: id}
	b.subs = append(b.subs, sub)
	b.cbs = append(b.cbs, fn)
	hook := b.onWatch
	b.mu.Unlock()
	if hook != nil {
		hook(id, dir)
	}
	return sub, nil
}

func TestReproLspWatcherUnwatchDuringWatchResurrects(t *testing.T) {
	// TLC trace (LspWatcher / NoResurrectedWatch, 4 states):
	// 1. WatchFiles("id1", ...) inserts w.watches["id1"] = nil and unlocks w.mu.
	// 2. While reconcile() runs WatchDirectory outside w.mu, UnwatchFiles("id1") runs,
	//    deletes "id1" from w.watches, and returns nil (success!).
	// 3. WatchFiles finishes reconcile(), re-locks w.mu, does NOT check whether "id1" was deleted,
	//    and appends newWatch to w.watches["id1"], resurrecting the unwatched ID with an open subscription!
	synctest.Test(t, func(t *testing.T) {
		fs := vfstest.FromMap(map[string]any{"/proj/a.ts": "export {}"}, tspath.CaseSensitive)
		inWatch := make(chan struct{})
		releaseWatch := make(chan struct{})
		backend := &fakeWatchBackend{
			onWatch: func(call int, _ tspath.RootedDirectoryPath) {
				if call == 1 {
					close(inWatch)
					<-releaseWatch
				}
			},
		}
		w := newWithBackend(fs, backend, func([]*lsproto.FileEvent) {}, logging.NewTestLogger())
		defer w.Close()

		pattern := "/proj/**/*"
		kind := lsproto.WatchKindCreate | lsproto.WatchKindChange | lsproto.WatchKindDelete
		fsw := []*lsproto.FileSystemWatcher{{
			GlobPattern: lsproto.PatternOrRelativePattern{Pattern: &pattern},
			Kind:        &kind,
		}}

		wfDone := make(chan error, 1)
		go func() {
			wfDone <- w.WatchFiles("id1", fsw)
		}()

		<-inWatch // WatchFiles has inserted w.watches["id1"] = nil and is in backend.WatchDirectory

		if err := w.UnwatchFiles("id1"); err != nil {
			t.Fatalf("unexpected UnwatchFiles error: %v", err)
		}

		close(releaseWatch)
		_ = <-wfDone

		w.mu.Lock()
		resurrected, exists := w.watches["id1"]
		w.mu.Unlock()
		if exists && len(resurrected) > 0 && !backend.subs[0].closed.Load() {
			t.Fatalf("BUG REPRODUCED (NoResurrectedWatch): UnwatchFiles(\"id1\") succeeded, yet w.watches[\"id1\"] was resurrected with %d active watch(es) and open backend sub #1", len(resurrected))
		}
	})
}

func TestReproLspWatcherStaleTerminationKillsNewerSub(t *testing.T) {
	// TLC trace (LspWatcher / NoKilledNewerSub, 6 states):
	// 1. Target sub #1 is installed.
	// 2. Sub #1 receives ErrWatchTerminated, invoking targetCallback -> handleTerminated().
	// 3. Before handleTerminated() acquires w.mu, a concurrent reconcile()
	//    installs a brand-new live target sub #2.
	// 4. Stale handleTerminated() acquires w.mu WITHOUT checking if w.subscription == sub #1,
	//    and closes the live sub #2!
	fs := vfstest.FromMap(map[string]any{"/proj/a.ts": "export {}"}, tspath.CaseSensitive)
	backend := &fakeWatchBackend{}
	w := newWithBackend(fs, backend, func([]*lsproto.FileEvent) {}, logging.NewTestLogger())
	defer w.Close()

	pattern := "/proj/**/*"
	kind := lsproto.WatchKindCreate | lsproto.WatchKindChange | lsproto.WatchKindDelete
	if err := w.WatchFiles("id1", []*lsproto.FileSystemWatcher{{
		GlobPattern: lsproto.PatternOrRelativePattern{Pattern: &pattern},
		Kind:        &kind,
	}}); err != nil {
		t.Fatal(err)
	}

	w.mu.Lock()
	wt := w.watches["id1"][0]
	w.mu.Unlock()
	cb1 := backend.cbs[0]

	// Hold wt.mu while firing stale cb1(ErrWatchTerminated), replace wt.subscription with live sub #2, then unlock.
	wt.mu.Lock()
	cb1Started := make(chan struct{})
	cb1Done := make(chan struct{})
	go func() {
		defer close(cb1Done)
		close(cb1Started)
		cb1(nil, fswatch.ErrWatchTerminated)
	}()
	<-cb1Started
	time.Sleep(10 * time.Millisecond) // allow cb1 -> handleTerminated() to park on wt.mu.Lock()

	liveSub2 := &fakeSub{id: 2}
	wt.subscription = liveSub2
	wt.watchingTarget = true
	wt.mu.Unlock()

	<-cb1Done
	if liveSub2.closed.Load() {
		t.Fatalf("BUG REPRODUCED (NoKilledNewerSub): stale ErrWatchTerminated from sub #1 closed newer live sub #2!")
	}
}
