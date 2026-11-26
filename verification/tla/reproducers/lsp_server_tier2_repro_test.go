package lsp_test

import (
	"context"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/bundled"
	"github.com/microsoft/TypeScript/tsc/internal/diagnostics"
	"github.com/microsoft/TypeScript/tsc/internal/lsp"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/project"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/lsptestutil"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
)

func newTier2TestFS() vfs.FS {
	return vfstest.FromMap(map[string]string{
		"/home/projects/tsconfig.json": `{}`,
		"/home/projects/index.ts":      "export const x = 1;",
	}, tspath.CaseInsensitive)
}

func defaultTier2ServerRequestHandler(_ context.Context, req *lsproto.RequestMessage) *lsproto.ResponseMessage {
	switch req.Method {
	case lsproto.MethodClientRegisterCapability,
		lsproto.MethodClientUnregisterCapability,
		lsproto.MethodWindowWorkDoneProgressCreate:
		return &lsproto.ResponseMessage{
			ID:      req.ID,
			JSONRPC: req.JSONRPC,
			Result:  lsproto.Null{},
		}
	case lsproto.MethodWorkspaceConfiguration:
		return &lsproto.ResponseMessage{
			ID:      req.ID,
			JSONRPC: req.JSONRPC,
			Result:  []any{nil, nil, nil, nil},
		}
	default:
		return nil
	}
}

func startTier2LSPClient(
	t *testing.T,
	onServerRequest lsptestutil.ServerRequestHandler,
	onServerNotif lsptestutil.ServerNotificationHandler,
	capabilities *lsproto.ClientCapabilities,
	sendInitialized bool,
) (*lsptestutil.LSPClient, func() error) {
	t.Helper()
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}
	if onServerRequest == nil {
		onServerRequest = defaultTier2ServerRequestHandler
	}
	if capabilities == nil {
		capabilities = &lsproto.ClientCapabilities{
			Window: &lsproto.WindowClientCapabilities{
				WorkDoneProgress: new(true),
			},
			Workspace: &lsproto.WorkspaceClientCapabilities{
				Configuration: new(true),
				DidChangeWatchedFiles: &lsproto.DidChangeWatchedFilesClientCapabilities{
					DynamicRegistration: new(true),
				},
			},
		}
	}

	client, closeClient := lsptestutil.NewLSPClient(t, lsp.ServerOptions{
		Err:                io.Discard,
		Cwd:                "/home/projects",
		FS:                 bundled.WrapFS(newTier2TestFS()),
		DefaultLibraryPath: bundled.LibPath(),
		ProgressDelay:      0,
	}, onServerRequest)
	client.OnServerNotification = onServerNotif

	initMsg, _, ok := client.SendRequest(t, lsproto.InitializeInfo, &lsproto.InitializeParams{
		Capabilities: capabilities,
	})
	if !ok || initMsg.AsResponse().Error != nil {
		t.Fatalf("Initialize failed: ok=%v err=%v", ok, initMsg.AsResponse().Error)
	}
	if sendInitialized {
		client.SendNotification(t, lsproto.InitializedInfo, &lsproto.InitializedParams{})
		<-client.Server.InitComplete()
	}
	return client, closeClient
}

// Repro 3.1a (LspProgressLocale / InvNoLocaleDataRace):
// serverProgressReporter.localize (progress.go:43) reads r.server.locale
// without holding r.server.localeMu.RLock(), racing with Server.SetLocale
// (server.go:850-852) invoked on configuration changes.
// Under `go test -race`, this deterministically triggers WARNING: DATA RACE.
func TestReproLspProgressLocaleDataRace(t *testing.T) {
	client, closeClient := startTier2LSPClient(t, nil, nil, nil, true)
	defer func() { _ = closeClient() }()

	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-done:
				return
			default:
				client.Server.ProgressStart(diagnostics.Project_0, "tsconfig.json")
				client.Server.ProgressFinish(diagnostics.Project_0, "tsconfig.json")
			}
		}
	}()

	for i := range 200 {
		if i%2 == 0 {
			client.Server.SetLocale("de")
		} else {
			client.Server.SetLocale("en")
		}
		time.Sleep(100 * time.Microsecond)
	}
	close(done)
	wg.Wait()
}

// Repro 3.1b (LspProgressLocale / InvProgressEndsWhenIdle):
// projectLoadingProgress.run() keys its `loading` refcount map by the localized
// string produced at event-processing time (progress.go:132-167). When the user's
// locale changes between ProgressStart and ProgressFinish, the finish event
// localizes to a different string, misses the entry keyed under the old locale,
// leaves loading.Size() > 0, and NEVER emits WorkDoneProgressEnd.
func TestReproLspProgressLocaleChangeSticksSpinnerForever(t *testing.T) {
	beginCh := make(chan string, 4)
	endCh := make(chan struct{}, 4)

	onNotif := func(_ context.Context, req *lsproto.RequestMessage) {
		if req.Method != lsproto.MethodProgress {
			return
		}
		params, err := req.UnmarshalParams[*lsproto.ProgressParams]()
		if err != nil || params == nil {
			return
		}
		if params.Value.Begin != nil && params.Value.Begin.Message != nil {
			select {
			case beginCh <- *params.Value.Begin.Message:
			default:
			}
		}
		if params.Value.End != nil {
			select {
			case endCh <- struct{}{}:
			default:
			}
		}
	}

	client, closeClient := startTier2LSPClient(t, nil, onNotif, nil, true)
	defer func() { _ = closeClient() }()

	// 1. Start progress under English locale; wait until projectLoadingProgress
	//    has processed the start event (so no data race is even needed!).
	client.Server.ProgressStart(diagnostics.Project_0, "tsconfig.json")
	var beginMsg string
	select {
	case beginMsg = <-beginCh:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for WorkDoneProgressBegin")
	}

	// 2. User changes locale to German via configuration before the operation finishes.
	client.Server.SetLocale("de")

	// 3. Operation finishes with the exact same message and arguments.
	client.Server.ProgressFinish(diagnostics.Project_0, "tsconfig.json")

	// 4. WorkDoneProgressEnd should be emitted promptly once the operation finishes.
	select {
	case <-endCh:
		// Properly ended.
	case <-time.After(300 * time.Millisecond):
		t.Fatalf("BUG REPRODUCED (LspProgressLocale / InvProgressEndsWhenIdle): "+
			"WorkDoneProgressEnd was never emitted after matching ProgressFinish because "+
			"locale changed from en (%q) to de; loading map entry is permanently leaked", beginMsg)
	}
}

// Repro 3.2a (LspServerLifecycle / InvNoPreInitNilSessionPanic):
// registerLanguageServiceDocumentRequestHandler (server.go:1417-1439) omits the
// `if s.session == nil` guard present in registerRequestHandler/registerNotificationHandler.
// Sending textDocument/hover after `initialize` and before `initialized` dereferences
// nil s.session on dispatchLoop (outside the async defer s.recover), crashing the server.
func TestReproLspPreInitializedDocumentRequestNilSessionPanic(t *testing.T) {
	client, closeClient := startTier2LSPClient(t, nil, nil, nil, false /*sendInitialized*/)
	defer func() { _ = closeClient() }()

	// Client sends textDocument/hover after `initialize` succeeds, before `initialized`.
	// Per LSP, the server should return ServerNotInitialized, not crash with nil panic.
	_, _, _ = client.SendRequest(t, lsproto.TextDocumentHoverInfo, &lsproto.HoverParams{
		TextDocument: lsproto.TextDocumentIdentifier{Uri: "file:///home/projects/index.ts"},
		Position:     lsproto.Position{Line: 0, Character: 0},
	})
}

// Repro 3.2b (LspServerLifecycle / InvNoPostShutdownNilSnapshotPanic):
// handleShutdown (server.go:1881-1887) calls s.session.Close() (setting
// s.session.snapshot = nil) without marking the server shut down. Per LSP 3.17,
// requests after `shutdown` must return InvalidRequest; instead dispatchLoop
// enters s.session.GetLanguageService on the closed session and panics on nil snapshot.
func TestReproLspPostShutdownDocumentRequestNilSnapshotPanic(t *testing.T) {
	client, closeClient := startTier2LSPClient(t, nil, nil, nil, true)
	defer func() { _ = closeClient() }()

	uri := lsproto.DocumentUri("file:///home/projects/index.ts")
	client.SendNotification(t, lsproto.TextDocumentDidOpenInfo, &lsproto.DidOpenTextDocumentParams{
		TextDocument: &lsproto.TextDocumentItem{
			Uri:        uri,
			LanguageId: "typescript",
			Text:       "export const x = 1;",
		},
	})

	id := client.NextID()
	reqID := lsproto.NewID(lsproto.IntegerOrString{Integer: &id})
	shutResp, ok := client.SendRequestWorker(t, &lsproto.RequestMessage{
		ID:     reqID,
		Method: lsproto.MethodShutdown,
	}, reqID)
	if !ok || shutResp.Error != nil {
		t.Fatalf("Shutdown failed: ok=%v err=%v", ok, shutResp.Error)
	}

	// Send textDocument/hover after shutdown (before exit): panics on nil s.session.snapshot.
	_, _, _ = client.SendRequest(t, lsproto.TextDocumentHoverInfo, &lsproto.HoverParams{
		TextDocument: lsproto.TextDocumentIdentifier{Uri: uri},
		Position:     lsproto.Position{Line: 0, Character: 13},
	})
}

// Repro 3.2c (LspServerLifecycle / InvNoDuplicateInitializedPanic):
// handleInitialized (server.go:1876) unconditionally overwrites s.session and
// executes close(s.initComplete) with no idempotency guard, crashing the server
// with `panic: close of closed channel` if a second `initialized` notification arrives.
func TestReproLspDuplicateInitializedCloseClosedChannelPanic(t *testing.T) {
	client, closeClient := startTier2LSPClient(t, nil, nil, nil, true)
	defer func() { _ = closeClient() }()

	// Second `initialized` notification triggers `panic: close of closed channel`.
	client.SendNotification(t, lsproto.InitializedInfo, &lsproto.InitializedParams{})

	// Follow with a request so the test waits until dispatchLoop processes the notification.
	id := client.NextID()
	reqID := lsproto.NewID(lsproto.IntegerOrString{Integer: &id})
	_, _ = client.SendRequestWorker(t, &lsproto.RequestMessage{
		ID:     reqID,
		Method: lsproto.MethodShutdown,
	}, reqID)
}

// Repro 3.3a (LspWatchRegistry / InvTimedOutWatchCanBeUnwatched):
// Server.WatchFiles (server.go:305-327) only calls s.watchers.Add(id) after
// sendClientRequest succeeds. If ctx expires while the client still processes
// client/registerCapability(id), the client installs the watcher, yet
// Server.UnwatchFiles(id) refuses with "no file watcher exists with ID ...",
// permanently stranding the client registration.
func TestReproLspWatchFilesTimeoutStrandsClientRegistration(t *testing.T) {
	const watchID = project.WatcherID("watcher-timeout-repro")

	regArrived := make(chan struct{}, 1)
	releaseReg := make(chan struct{})
	clientInstalled := atomic.Bool{}

	onReq := func(ctx context.Context, req *lsproto.RequestMessage) *lsproto.ResponseMessage {
		if req.Method == lsproto.MethodClientRegisterCapability {
			params, err := req.UnmarshalParams[*lsproto.RegistrationParams]()
			if err == nil && len(params.Registrations) == 1 && params.Registrations[0].Id == string(watchID) {
				select {
				case regArrived <- struct{}{}:
				default:
				}
				<-releaseReg
				clientInstalled.Store(true)
				return &lsproto.ResponseMessage{
					ID:      req.ID,
					JSONRPC: req.JSONRPC,
					Result:  lsproto.Null{},
				}
			}
		}
		if req.Method == lsproto.MethodClientUnregisterCapability {
			clientInstalled.Store(false)
			return &lsproto.ResponseMessage{
				ID:      req.ID,
				JSONRPC: req.JSONRPC,
				Result:  lsproto.Null{},
			}
		}
		return defaultTier2ServerRequestHandler(ctx, req)
	}

	client, closeClient := startTier2LSPClient(t, onReq, nil, nil, true)
	defer func() { _ = closeClient() }()

	watchCtx, cancelWatch := context.WithCancel(t.Context())
	watchDone := make(chan error, 1)
	go func() {
		watchDone <- client.Server.WatchFiles(watchCtx, watchID, []*lsproto.FileSystemWatcher{
			{GlobPattern: lsproto.PatternOrRelativePattern{Pattern: new("**/*.ts")}},
		})
	}()

	// Wait until the server has already sent client/registerCapability over the wire.
	select {
	case <-regArrived:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for client/registerCapability")
	}

	// Cancel watchCtx (simulating watchRequestTimeout expiring before the client responds).
	cancelWatch()
	watchErr := <-watchDone
	if watchErr == nil {
		t.Fatal("expected WatchFiles to return cancellation error")
	}

	// Now the slow client finishes installing the registration and sends its null reply.
	close(releaseReg)
	deadline := time.Now().Add(3 * time.Second)
	for !clientInstalled.Load() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !clientInstalled.Load() {
		t.Fatal("expected client to finish installing watcher")
	}

	// Server attempts to clean up the watcher; Server.UnwatchFiles refuses because
	// s.watchers never recorded watchID!
	unwatchErr := client.Server.UnwatchFiles(t.Context(), watchID)
	if unwatchErr != nil || clientInstalled.Load() {
		t.Fatalf("BUG REPRODUCED (LspWatchRegistry / InvTimedOutWatchCanBeUnwatched): "+
			"UnwatchFiles failed with %v while client still holds installed watcher %q (clientInstalled=%v)",
			unwatchErr, watchID, clientInstalled.Load())
	}
}

// Repro 3.3b (LspWatchRegistry / InvNoDuplicateUnwatch):
// Server.UnwatchFiles (server.go:341-352) checks s.watchers.Has(id), performs an
// unlocked client/unregisterCapability RPC, and only calls s.watchers.Delete(id)
// after the RPC returns. Two concurrent UnwatchFiles(id) calls both pass Has(id)
// and send duplicate unregisterCapability RPCs for the same ID.
func TestReproLspWatchFilesConcurrentUnwatchDuplicateRPC(t *testing.T) {
	const watchID = project.WatcherID("watcher-dup-unwatch-repro")

	firstUnregArrived := make(chan struct{}, 1)
	releaseFirstUnreg := make(chan struct{})
	var unregCount atomic.Int32

	onReq := func(ctx context.Context, req *lsproto.RequestMessage) *lsproto.ResponseMessage {
		if req.Method == lsproto.MethodClientUnregisterCapability {
			n := unregCount.Add(1)
			if n == 1 {
				select {
				case firstUnregArrived <- struct{}{}:
				default:
				}
				<-releaseFirstUnreg
			}
			return &lsproto.ResponseMessage{
				ID:      req.ID,
				JSONRPC: req.JSONRPC,
				Result:  lsproto.Null{},
			}
		}
		return defaultTier2ServerRequestHandler(ctx, req)
	}

	client, closeClient := startTier2LSPClient(t, onReq, nil, nil, true)
	defer func() { _ = closeClient() }()

	if err := client.Server.WatchFiles(t.Context(), watchID, []*lsproto.FileSystemWatcher{
		{GlobPattern: lsproto.PatternOrRelativePattern{Pattern: new("**/*.ts")}},
	}); err != nil {
		t.Fatalf("WatchFiles failed: %v", err)
	}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_ = client.Server.UnwatchFiles(t.Context(), watchID)
	}()

	// Wait until the first UnwatchFiles is blocked awaiting its RPC reply (before Delete).
	select {
	case <-firstUnregArrived:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for first client/unregisterCapability")
	}

	// Start a second concurrent UnwatchFiles(watchID): it also sees s.watchers.Has(watchID) == true
	// and enqueues a second client/unregisterCapability RPC before the first returns!
	wg.Add(1)
	go func() {
		defer wg.Done()
		_ = client.Server.UnwatchFiles(t.Context(), watchID)
	}()

	// Allow the second goroutine to pass s.watchers.Has(watchID) and queue its RPC.
	time.Sleep(30 * time.Millisecond)
	close(releaseFirstUnreg)
	wg.Wait()

	if got := unregCount.Load(); got > 1 {
		t.Fatalf("BUG REPRODUCED (LspWatchRegistry / InvNoDuplicateUnwatch): "+
			"Server.UnwatchFiles sent %d duplicate client/unregisterCapability RPCs for watcher %q",
			got, watchID)
	}
}
