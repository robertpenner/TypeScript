package project_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/bundled"
	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/project"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/projecttestutil"
)

func watchGlobString(w *lsproto.FileSystemWatcher) string {
	if w.GlobPattern.Pattern != nil {
		return *w.GlobPattern.Pattern
	}
	if w.GlobPattern.RelativePattern != nil {
		base := ""
		if w.GlobPattern.RelativePattern.BaseUri.URI != nil {
			base = string(*w.GlobPattern.RelativePattern.BaseUri.URI)
		}
		return base + "::" + w.GlobPattern.RelativePattern.Pattern
	}
	return ""
}

// TestReproSessionWatchLeakedClientWatchOnAddRemove reproduces the unserialized
// backgroundQueue watch race (session.go:1428-1455, 1510-1595):
//   - S0->S1 opens p1 and calls WatchFiles(id) in background task T1.
//   - While T1 is in flight on WatchFiles(id), S1->S2 closes p1 and calls
//     Release + UnwatchFiles(id) in concurrent background task T2.
//   - T1 finishes WatchFiles(id) after T2's UnwatchFiles(id), permanently
//     leaking active client watches whose registry entries are already gone.
func TestReproSessionWatchLeakedClientWatchOnAddRemove(t *testing.T) {
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/p1/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/home/projects/TS/p1/src/index.ts":  `export const x = 1;`,
	}
	init, utils := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})

	var mu sync.Mutex
	activeClientWatches := make(map[project.WatcherID]string)
	var blockedID project.WatcherID
	firstWatchStarted := make(chan struct{})
	blockedIDUnwatched := make(chan struct{})
	releaseFirstWatch := make(chan struct{})
	var blockedOnce atomic.Bool
	var unwatchedOnce atomic.Bool

	utils.Client().WatchFilesFunc = func(ctx context.Context, id project.WatcherID, watchers []*lsproto.FileSystemWatcher) error {
		if blockedOnce.CompareAndSwap(false, true) {
			mu.Lock()
			blockedID = id
			mu.Unlock()
			close(firstWatchStarted)
			<-releaseFirstWatch
		}
		mu.Lock()
		activeClientWatches[id] = watchGlobString(watchers[0])
		mu.Unlock()
		return nil
	}
	utils.Client().UnwatchFilesFunc = func(ctx context.Context, id project.WatcherID) error {
		mu.Lock()
		delete(activeClientWatches, id)
		isBlocked := id == blockedID
		mu.Unlock()
		if isBlocked && unwatchedOnce.CompareAndSwap(false, true) {
			close(blockedIDUnwatched)
		}
		return nil
	}

	session := project.NewSession(init)
	defer session.Close()

	uri := lsproto.DocumentUri("file:///home/projects/TS/p1/src/index.ts")
	session.DidOpenFile(context.Background(), uri, 1, files["/home/projects/TS/p1/src/index.ts"].(string), lsproto.LanguageKindTypeScript)

	// Wait for T1 (S0->S1) to Acquire and enter WatchFiles(blockedID).
	select {
	case <-firstWatchStarted:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for first WatchFiles call")
	}

	// Close p1 and open an unrelated file so S1->S2 removes p1 and runs T2:
	// Release + UnwatchFiles(blockedID) while T1 is still inside WatchFiles.
	session.DidCloseFile(context.Background(), uri)
	session.DidOpenFile(context.Background(), "file:///home/projects/TS/other.ts", 1, "export const y = 2;", lsproto.LanguageKindTypeScript)

	select {
	case <-blockedIDUnwatched:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for T2 UnwatchFiles(%s)", blockedID)
	}

	// Release T1 so WatchFiles(blockedID) completes AFTER T2's UnwatchFiles(blockedID).
	close(releaseFirstWatch)
	session.WaitForBackgroundTasks()

	mu.Lock()
	defer mu.Unlock()
	if glob, leaked := activeClientWatches[blockedID]; leaked {
		t.Fatalf("BUG REPRODUCED: leaked client watch %s (%s) remained registered after UnwatchFiles(%s) already ran", blockedID, glob, blockedID)
	}
}

// TestReproSessionWatchConcurrentAcquireFailStrandsLiveProject reproduces
// watchRegistry concurrent Acquire + partial-failure rollback (session.go:1517-1555):
//   - p1 and p2 share the root-files watch glob ("/**/*").
//   - T1 (p1) acquires glob G (count 0->1, isNew=true) and blocks in WatchFiles.
//   - T2 (p2) acquires glob G (count 1->2, isNew=false), skips WatchFiles, and
//     succeeds (ClearPending).
//   - T1's WatchFiles fails and rolls back Release(G) (count 2->1, not removed),
//     marking only p1 pending.
//   - Result: p2 is live and non-pending, watchRegistry[G].count == 1 (blocking
//     future registrations), and the client has ZERO active watches for G.
func TestReproSessionWatchConcurrentAcquireFailStrandsLiveProject(t *testing.T) {
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/p1/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/home/projects/TS/p1/index.ts":      `export const a = 1;`,
		"/home/projects/TS/p2/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/home/projects/TS/p2/index.ts":      `export const b = 2;`,
	}
	init, utils := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})

	var mu sync.Mutex
	activeClientWatches := make(map[project.WatcherID]string)
	sharedWatchBlocked := make(chan struct{})
	releaseSharedWatch := make(chan struct{})
	var blockedSharedOnce atomic.Bool
	var targetGlob string

	utils.Client().WatchFilesFunc = func(ctx context.Context, id project.WatcherID, watchers []*lsproto.FileSystemWatcher) error {
		g := watchGlobString(watchers[0])
		if blockedSharedOnce.CompareAndSwap(false, true) {
			mu.Lock()
			targetGlob = g
			mu.Unlock()
			close(sharedWatchBlocked)
			<-releaseSharedWatch
			return errors.New("simulated transient WatchFiles failure")
		}
		mu.Lock()
		activeClientWatches[id] = g
		mu.Unlock()
		return nil
	}
	utils.Client().UnwatchFilesFunc = func(ctx context.Context, id project.WatcherID) error {
		mu.Lock()
		delete(activeClientWatches, id)
		mu.Unlock()
		return nil
	}

	session := project.NewSession(init)
	defer session.Close()

	// Step 1: Open p1 -> T1 acquires shared glob (0->1) and blocks in WatchFiles.
	session.DidOpenFile(context.Background(), "file:///home/projects/TS/p1/index.ts", 1, files["/home/projects/TS/p1/index.ts"].(string), lsproto.LanguageKindTypeScript)
	select {
	case <-sharedWatchBlocked:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for p1 shared glob WatchFiles call")
	}

	// Step 2: While T1 is blocked in WatchFiles, open p2 -> T2 acquires shared
	// glob (1->2, isNew=false) and succeeds without calling WatchFiles for it.
	session.DidOpenFile(context.Background(), "file:///home/projects/TS/p2/index.ts", 1, files["/home/projects/TS/p2/index.ts"].(string), lsproto.LanguageKindTypeScript)
	time.Sleep(50 * time.Millisecond)

	// Step 3: Fail T1's WatchFiles -> rolls back Release(shared) from 2->1.
	close(releaseSharedWatch)
	session.WaitForBackgroundTasks()

	mu.Lock()
	defer mu.Unlock()
	watched := false
	for _, g := range activeClientWatches {
		if g == targetGlob {
			watched = true
			break
		}
	}
	if !watched {
		t.Fatalf("BUG REPRODUCED: live project p2 is permanently unwatched for shared glob %q (watchRegistry refcount stayed at 1 after T1 rollback while client has 0 watches for it)", targetGlob)
	}
}

// TestReproSessionWatchFailedThenRemovedStealsLiveWatch reproduces the
// double-release bug when a watcher whose registration failed (and rolled back)
// is later removed or retried (session.go:1543-1575):
//   - p1 fails WatchFiles for shared glob G ("/**/*") and rolls back its
//     Acquire (count 1->0, marked pending).
//   - p2 opens and succeeds WatchFiles for G (count 0->1, client holds p2's watch),
//     while p1 is removed (or retried and closed): updateWatch(ctx, p1Watch, nil)
//     does NOT check IsPending and blindly calls Release(G) + UnwatchFiles(p2's ID),
//     tearing down p2's live watch while p2 is still open.
func TestReproSessionWatchFailedThenRemovedStealsLiveWatch(t *testing.T) {
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/p1/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/home/projects/TS/p1/index.ts":      `export const a = 1;`,
		"/home/projects/TS/p2/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/home/projects/TS/p2/index.ts":      `export const b = 2;`,
	}
	init, utils := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})

	var mu sync.Mutex
	activeClientWatches := make(map[project.WatcherID]string)
	var failP1 atomic.Bool
	failP1.Store(true)
	var targetGlob string
	var unwatchedIDs []project.WatcherID

	utils.Client().WatchFilesFunc = func(ctx context.Context, id project.WatcherID, watchers []*lsproto.FileSystemWatcher) error {
		g := watchGlobString(watchers[0])
		if failP1.Load() && strings.Contains(string(id), "/p1/") {
			mu.Lock()
			targetGlob = g
			mu.Unlock()
			return errors.New("simulated p1 WatchFiles failure")
		}
		mu.Lock()
		if targetGlob == "" {
			targetGlob = g
		}
		activeClientWatches[id] = g
		mu.Unlock()
		return nil
	}
	utils.Client().UnwatchFilesFunc = func(ctx context.Context, id project.WatcherID) error {
		mu.Lock()
		unwatchedIDs = append(unwatchedIDs, id)
		delete(activeClientWatches, id)
		mu.Unlock()
		return nil
	}

	session := project.NewSession(init)
	defer session.Close()

	// Step 1: Open p1; WatchFiles fails -> p1 rolls back Acquire(G) (1->0) and
	// marks its watcher pending.
	p1URI := lsproto.DocumentUri("file:///home/projects/TS/p1/index.ts")
	p2URI := lsproto.DocumentUri("file:///home/projects/TS/p2/index.ts")
	session.DidOpenFile(context.Background(), p1URI, 1, files["/home/projects/TS/p1/index.ts"].(string), lsproto.LanguageKindTypeScript)
	session.WaitForBackgroundTasks()

	// Step 2: Close p1 and open p2. In the S1->S2 snapshot diff, p2 is added
	// (Acquire(G): 0->1, WatchFiles succeeds!) and failed/rolled-back p1 is
	// removed (updateWatch(p1, nil) blindly calls Release(G): 1->0 + UnwatchFiles(p2's ID)!).
	session.DidCloseFile(context.Background(), p1URI)
	session.DidOpenFile(context.Background(), p2URI, 1, files["/home/projects/TS/p2/index.ts"].(string), lsproto.LanguageKindTypeScript)
	session.WaitForBackgroundTasks()

	mu.Lock()
	defer mu.Unlock()
	hasShared := false
	for _, g := range activeClientWatches {
		if g == targetGlob {
			hasShared = true
		}
	}
	if !hasShared {
		t.Fatalf("BUG REPRODUCED: removing failed/rolled-back p1 double-released shared glob %q and tore down live project p2's watch (unwatched: %v)", targetGlob, unwatchedIDs)
	}
}

// TestReproSessionProgramDiagOutOfOrderStaleOverwrite reproduces unserialized
// publishProgramDiagnostics (session.go:1428-1455, 1902-1965):
//   - S0->S1 opens a configured project whose tsconfig.json has an error -> T1
//     starts PublishDiagnostics(tsconfig.json, [err]) and pauses in flight.
//   - S1->S2 closes the project -> T2 publishes PublishDiagnostics(tsconfig.json, [])
//     and finishes.
//   - T1 finishes after T2, permanently overwriting the cleared diagnostics
//     with stale errors on the client.
func TestReproSessionProgramDiagOutOfOrderStaleOverwrite(t *testing.T) {
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/p1/tsconfig.json": `{"compilerOptions": {"noLib": true, "unknownOptionBogus": true}}`,
		"/home/projects/TS/p1/index.ts":      `export const x = 1;`,
	}
	init, utils := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})
	init.Options.PushDiagnosticsEnabled = true

	var mu sync.Mutex
	var lastPublished []*lsproto.Diagnostic
	var publishSeq []int
	firstNonEmptyBlocked := make(chan struct{})
	releaseFirstNonEmpty := make(chan struct{})
	clearedPublished := make(chan struct{})
	var blockedOnce atomic.Bool
	var clearedOnce atomic.Bool

	utils.Client().PublishDiagnosticsFunc = func(ctx context.Context, params *lsproto.PublishDiagnosticsParams) error {
		if !strings.HasSuffix(string(params.Uri), "tsconfig.json") {
			return nil
		}
		if len(params.Diagnostics) > 0 && blockedOnce.CompareAndSwap(false, true) {
			close(firstNonEmptyBlocked)
			<-releaseFirstNonEmpty
		}
		mu.Lock()
		lastPublished = params.Diagnostics
		publishSeq = append(publishSeq, len(params.Diagnostics))
		mu.Unlock()
		if len(params.Diagnostics) == 0 && clearedOnce.CompareAndSwap(false, true) {
			close(clearedPublished)
		}
		return nil
	}

	session := project.NewSession(init)
	defer session.Close()

	p1URI := lsproto.DocumentUri("file:///home/projects/TS/p1/index.ts")
	session.DidOpenFile(context.Background(), p1URI, 1, files["/home/projects/TS/p1/index.ts"].(string), lsproto.LanguageKindTypeScript)

	// Wait for T1 (S0->S1) to enter PublishDiagnostics with stale tsconfig error.
	select {
	case <-firstNonEmptyBlocked:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for non-empty tsconfig diagnostic publish")
	}

	// Close p1 and flush snapshot (S1->S2) so T2 publishes empty diagnostics [].
	session.DidCloseFile(context.Background(), p1URI)
	session.DidOpenFile(context.Background(), "file:///home/projects/TS/other.ts", 1, "export const y = 2;", lsproto.LanguageKindTypeScript)

	select {
	case <-clearedPublished:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for cleared diagnostic publish")
	}

	// Release T1 so stale error arrives after T2 cleared diagnostics.
	close(releaseFirstNonEmpty)
	session.WaitForBackgroundTasks()

	mu.Lock()
	defer mu.Unlock()
	if len(lastPublished) != 0 {
		t.Fatalf("BUG REPRODUCED: out-of-order publishProgramDiagnostics restored %d stale error(s) after project closed (publish len sequence: %v)", len(lastPublished), publishSeq)
	}
}

// TestReproSessionDidChangeInferredOptionsDataRace reproduces the unlocked
// write to s.compilerOptionsForInferredProjects and unlocked UpdateSnapshot in
// Session.DidChangeCompilerOptionsForInferredProjects (session.go:500-506).
func TestReproSessionDidChangeInferredOptionsDataRace(t *testing.T) {
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/a.ts": `export const x = 1;`,
	}
	init, _ := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})
	session := project.NewSession(init)
	defer session.Close()

	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := range 2 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			opts := &core.CompilerOptions{NoLib: core.TSTrue, Strict: core.TSTrue}
			if i == 1 {
				opts.Strict = core.TSFalse
			}
			session.DidChangeCompilerOptionsForInferredProjects(context.Background(), opts)
		}(i)
	}
	close(start)
	wg.Wait()
	session.WaitForBackgroundTasks()
}

// TestReproSessionDidChangeInferredOptionsNilSnapshotPanic reproduces the
// unlocked Close() vs DidChangeCompilerOptionsForInferredProjects race
// (session.go:500-506, 1725-1734): Close() sets s.snapshot = nil under
// s.snapshotUpdateMu, while DidChangeCompilerOptionsForInferredProjects skips
// s.snapshotUpdateMu and calls updateSnapshot -> oldSnapshot.Clone(...),
// panicking with a nil pointer dereference.
func TestReproSessionDidChangeInferredOptionsNilSnapshotPanic(t *testing.T) {
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/a.ts": `export const x = 1;`,
	}
	init, _ := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})
	session := project.NewSession(init)
	session.Close()

	var recovered any
	func() {
		defer func() { recovered = recover() }()
		session.DidChangeCompilerOptionsForInferredProjects(
			context.Background(),
			&core.CompilerOptions{NoLib: core.TSTrue},
		)
	}()
	if recovered != nil {
		t.Fatalf("BUG REPRODUCED: DidChangeCompilerOptionsForInferredProjects panicked on nil snapshot after Close(): %v", recovered)
	}
}
