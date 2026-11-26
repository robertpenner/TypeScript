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
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
)

func defaultConcurrencyServerRequestHandler(_ context.Context, req *lsproto.RequestMessage) *lsproto.ResponseMessage {
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

func startConcurrencyLSPClient(
	t *testing.T,
	onServerRequest lsptestutil.ServerRequestHandler,
	onServerNotif lsptestutil.ServerNotificationHandler,
) (*lsptestutil.LSPClient, func() error) {
	t.Helper()
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}
	if onServerRequest == nil {
		onServerRequest = defaultConcurrencyServerRequestHandler
	}
	fs := vfstest.FromMap(map[string]string{
		"/home/projects/tsconfig.json": `{}`,
		"/home/projects/index.ts":      "export const x = 1;",
	}, tspath.CaseInsensitive)
	client, closeClient := lsptestutil.NewLSPClient(t, lsp.ServerOptions{
		Err:                io.Discard,
		Cwd:                "/home/projects",
		FS:                 bundled.WrapFS(fs),
		DefaultLibraryPath: bundled.LibPath(),
		ProgressDelay:      0,
	}, onServerRequest)
	client.OnServerNotification = onServerNotif

	initMsg, _, ok := client.SendRequest(t, lsproto.InitializeInfo, &lsproto.InitializeParams{
		Capabilities: &lsproto.ClientCapabilities{
			Window: &lsproto.WindowClientCapabilities{
				WorkDoneProgress: new(true),
			},
			Workspace: &lsproto.WorkspaceClientCapabilities{
				Configuration: new(true),
				DidChangeWatchedFiles: &lsproto.DidChangeWatchedFilesClientCapabilities{
					DynamicRegistration: new(true),
				},
			},
		},
	})
	if !ok || initMsg.AsResponse().Error != nil {
		t.Fatalf("Initialize failed: ok=%v err=%v", ok, initMsg.AsResponse().Error)
	}
	client.SendNotification(t, lsproto.InitializedInfo, &lsproto.InitializedParams{})
	<-client.Server.InitComplete()
	return client, closeClient
}

func TestLspProgressLocaleDataRace(t *testing.T) {
	client, closeClient := startConcurrencyLSPClient(t, nil, nil)
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

func TestLspProgressLocaleChangeEndsSpinner(t *testing.T) {
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

	client, closeClient := startConcurrencyLSPClient(t, nil, onNotif)
	defer func() { _ = closeClient() }()

	client.Server.ProgressStart(diagnostics.Project_0, "tsconfig.json")
	var beginMsg string
	select {
	case beginMsg = <-beginCh:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for WorkDoneProgressBegin")
	}

	client.Server.SetLocale("de")
	client.Server.ProgressFinish(diagnostics.Project_0, "tsconfig.json")

	select {
	case <-endCh:
	case <-time.After(300 * time.Millisecond):
		t.Fatalf("WorkDoneProgressEnd was never emitted after locale change from en (%q) to de", beginMsg)
	}
}

func TestLspWatchFilesTimeoutCanStillBeUnwatched(t *testing.T) {
	const watchID = project.WatcherID("watcher-timeout-repro")

	regArrived := make(chan struct{}, 1)
	releaseReg := make(chan struct{})
	var clientInstalled atomic.Bool

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
		return defaultConcurrencyServerRequestHandler(ctx, req)
	}

	client, closeClient := startConcurrencyLSPClient(t, onReq, nil)
	defer func() { _ = closeClient() }()

	watchCtx, cancelWatch := context.WithCancel(t.Context())
	watchDone := make(chan error, 1)
	go func() {
		watchDone <- client.Server.WatchFiles(watchCtx, watchID, []*lsproto.FileSystemWatcher{
			{GlobPattern: lsproto.PatternOrRelativePattern{Pattern: new("**/*.ts")}},
		})
	}()

	select {
	case <-regArrived:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for client/registerCapability")
	}

	cancelWatch()
	if watchErr := <-watchDone; watchErr == nil {
		t.Fatal("expected WatchFiles to return cancellation error")
	}

	close(releaseReg)
	deadline := time.Now().Add(3 * time.Second)
	for !clientInstalled.Load() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !clientInstalled.Load() {
		t.Fatal("expected client to finish installing watcher")
	}

	if unwatchErr := client.Server.UnwatchFiles(t.Context(), watchID); unwatchErr != nil || clientInstalled.Load() {
		t.Fatalf("UnwatchFiles failed with %v while clientInstalled=%v", unwatchErr, clientInstalled.Load())
	}
}

func TestLspWatchFilesConcurrentUnwatchSendsSingleRPC(t *testing.T) {
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
		return defaultConcurrencyServerRequestHandler(ctx, req)
	}

	client, closeClient := startConcurrencyLSPClient(t, onReq, nil)
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

	select {
	case <-firstUnregArrived:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for first client/unregisterCapability")
	}

	wg.Add(1)
	go func() {
		defer wg.Done()
		_ = client.Server.UnwatchFiles(t.Context(), watchID)
	}()

	time.Sleep(30 * time.Millisecond)
	close(releaseFirstUnreg)
	wg.Wait()

	if got := unregCount.Load(); got != 1 {
		t.Fatalf("expected exactly 1 client/unregisterCapability RPC, got %d", got)
	}
}
