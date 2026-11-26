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

// TestSessionWatchAddRemoveOrderedNoLeak verifies that a later snapshot's
// watch removal cannot overtake an earlier snapshot's in-flight WatchFiles RPC
// and permanently leak an active client watch.
func TestSessionWatchAddRemoveOrderedNoLeak(t *testing.T) {
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/p1/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/home/projects/TS/p1/src/index.ts":  `export const x = 1;`,
	}
	init, utils := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})
	init.Options.DebounceDelay = 10 * time.Millisecond

	var mu sync.Mutex
	activeClientWatches := make(map[project.WatcherID]string)
	var blockedID project.WatcherID
	var blockedWatchCompleted atomic.Bool
	var unwatchBeforeWatchCompleted atomic.Bool
	firstWatchStarted := make(chan struct{})
	releaseFirstWatch := make(chan struct{})
	var blockedOnce atomic.Bool

	utils.Client().WatchFilesFunc = func(ctx context.Context, id project.WatcherID, watchers []*lsproto.FileSystemWatcher) error {
		isBlocked := blockedOnce.CompareAndSwap(false, true)
		if isBlocked {
			mu.Lock()
			blockedID = id
			mu.Unlock()
			close(firstWatchStarted)
			<-releaseFirstWatch
		}
		mu.Lock()
		activeClientWatches[id] = watchGlobString(watchers[0])
		mu.Unlock()
		if isBlocked {
			blockedWatchCompleted.Store(true)
		}
		return nil
	}
	utils.Client().UnwatchFilesFunc = func(ctx context.Context, id project.WatcherID) error {
		mu.Lock()
		isBlocked := id == blockedID
		delete(activeClientWatches, id)
		mu.Unlock()
		if isBlocked && !blockedWatchCompleted.Load() {
			unwatchBeforeWatchCompleted.Store(true)
		}
		return nil
	}

	session := project.NewSession(init)
	defer session.Close()

	uri := lsproto.DocumentUri("file:///home/projects/TS/p1/src/index.ts")
	session.DidOpenFile(context.Background(), uri, 1, files["/home/projects/TS/p1/src/index.ts"].(string), lsproto.LanguageKindTypeScript)

	// Wait for S0->S1 to enter WatchFiles(blockedID).
	select {
	case <-firstWatchStarted:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for first WatchFiles call")
	}

	// Close p1 and open an unrelated file so S1->S2 removes p1 while S0->S1 is still blocked in WatchFiles.
	otherURI := lsproto.DocumentUri("file:///home/projects/TS/other.ts")
	session.DidCloseFile(context.Background(), uri)
	session.DidOpenFile(context.Background(), otherURI, 1, "export const y = 2;", lsproto.LanguageKindTypeScript)

	// Give an unserialized S1->S2 goroutine time to overtake S0->S1 before releasing S0->S1.
	time.Sleep(50 * time.Millisecond)

	close(releaseFirstWatch)
	session.WaitForBackgroundTasks()

	// Close other.ts as well so no open project still shares blockedID's glob.
	session.DidCloseFile(context.Background(), otherURI)
	session.WaitForBackgroundTasks()

	if unwatchBeforeWatchCompleted.Load() {
		t.Fatalf("UnwatchFiles(%s) ran before WatchFiles(%s) completed", blockedID, blockedID)
	}
	mu.Lock()
	defer mu.Unlock()
	if glob, leaked := activeClientWatches[blockedID]; leaked {
		t.Fatalf("leaked client watch %s (%s) remained registered after all projects were closed", blockedID, glob)
	}
}

// TestSessionWatchConcurrentAcquireFailDoesNotStrandLiveProject verifies that
// when one snapshot's WatchFiles call fails and rolls back, a subsequent
// snapshot that shares the same glob still registers an active client watch.
func TestSessionWatchConcurrentAcquireFailDoesNotStrandLiveProject(t *testing.T) {
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

	// Step 1: Open p1 -> S0->S1 blocks in WatchFiles for the shared glob and will fail.
	session.DidOpenFile(context.Background(), "file:///home/projects/TS/p1/index.ts", 1, files["/home/projects/TS/p1/index.ts"].(string), lsproto.LanguageKindTypeScript)
	select {
	case <-sharedWatchBlocked:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for p1 shared glob WatchFiles call")
	}

	// Step 2: Open p2 while S0->S1 is still blocked in WatchFiles.
	session.DidOpenFile(context.Background(), "file:///home/projects/TS/p2/index.ts", 1, files["/home/projects/TS/p2/index.ts"].(string), lsproto.LanguageKindTypeScript)
	time.Sleep(50 * time.Millisecond)

	// Step 3: Fail S0->S1's WatchFiles; S1->S2 must still ensure p2 has an active client watch.
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
		t.Fatalf("live project p2 is unwatched for shared glob %q after p1 WatchFiles failure", targetGlob)
	}
}

// TestSessionWatchFailedThenRemovedDoesNotStealLiveWatch verifies that
// removing a project whose initial WatchFiles registration failed and rolled
// back does not double-release a shared glob or UnwatchFiles a live project's watch.
func TestSessionWatchFailedThenRemovedDoesNotStealLiveWatch(t *testing.T) {
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
	var targetGlob string
	var unwatchedIDs []project.WatcherID

	utils.Client().WatchFilesFunc = func(ctx context.Context, id project.WatcherID, watchers []*lsproto.FileSystemWatcher) error {
		g := watchGlobString(watchers[0])
		if strings.Contains(string(id), "/p1/") {
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

	// Step 1: Open p1; WatchFiles fails -> p1 rolls back Acquire(G) and marks pending.
	p1URI := lsproto.DocumentUri("file:///home/projects/TS/p1/index.ts")
	p2URI := lsproto.DocumentUri("file:///home/projects/TS/p2/index.ts")
	session.DidOpenFile(context.Background(), p1URI, 1, files["/home/projects/TS/p1/index.ts"].(string), lsproto.LanguageKindTypeScript)
	session.WaitForBackgroundTasks()

	// Step 2: Close p1 and open p2. Removing failed/pending p1 must NOT release p2's watch.
	session.DidCloseFile(context.Background(), p1URI)
	session.DidOpenFile(context.Background(), p2URI, 1, files["/home/projects/TS/p2/index.ts"].(string), lsproto.LanguageKindTypeScript)
	session.WaitForBackgroundTasks()

	mu.Lock()
	defer mu.Unlock()
	hasShared := false
	for _, g := range activeClientWatches {
		if g == targetGlob {
			hasShared = true
			break
		}
	}
	if !hasShared {
		t.Fatalf("removing failed/pending p1 double-released shared glob %q and tore down live project p2's watch (unwatched: %v)", targetGlob, unwatchedIDs)
	}
}
