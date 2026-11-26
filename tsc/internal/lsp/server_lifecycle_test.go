package lsp_test

import (
	"context"
	"io"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/bundled"
	"github.com/microsoft/TypeScript/tsc/internal/lsp"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/lsptestutil"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
	"gotest.tools/v3/assert"
)

func startLifecycleTestClient(t *testing.T, sendInitialized bool) (*lsptestutil.LSPClient, func() error) {
	t.Helper()
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	fs := vfstest.FromMap(map[string]string{
		"/home/projects/tsconfig.json": `{}`,
		"/home/projects/index.ts":      "export const x = 1;",
	}, tspath.CaseInsensitive)

	onServerRequest := func(_ context.Context, req *lsproto.RequestMessage) *lsproto.ResponseMessage {
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

	client, closeClient := lsptestutil.NewLSPClient(t, lsp.ServerOptions{
		Err:                io.Discard,
		Cwd:                "/home/projects",
		FS:                 bundled.WrapFS(fs),
		DefaultLibraryPath: bundled.LibPath(),
		ProgressDelay:      0,
	}, onServerRequest)

	initMsg, _, ok := client.SendRequest(t, lsproto.InitializeInfo, &lsproto.InitializeParams{
		Capabilities: &lsproto.ClientCapabilities{
			Workspace: &lsproto.WorkspaceClientCapabilities{
				Configuration: new(true),
				DidChangeWatchedFiles: &lsproto.DidChangeWatchedFilesClientCapabilities{
					DynamicRegistration: new(true),
				},
			},
		},
	})
	assert.Assert(t, ok)
	assert.Assert(t, initMsg.AsResponse().Error == nil)

	if sendInitialized {
		client.SendNotification(t, lsproto.InitializedInfo, &lsproto.InitializedParams{})
		<-client.Server.InitComplete()
	}

	return client, closeClient
}

func TestServerPreInitializedDocumentRequestReturnsServerNotInitialized(t *testing.T) {
	t.Parallel()
	client, closeClient := startLifecycleTestClient(t, false)
	defer func() { _ = closeClient() }()

	// Document request sent between initialize and initialized must return
	// ServerNotInitialized instead of panicking on nil s.session.
	msg, _, ok := client.SendRequest(t, lsproto.TextDocumentHoverInfo, &lsproto.HoverParams{
		TextDocument: lsproto.TextDocumentIdentifier{Uri: "file:///home/projects/index.ts"},
		Position:     lsproto.Position{Line: 0, Character: 13},
	})
	assert.Assert(t, !ok)
	assert.Assert(t, msg != nil)
	resp := msg.AsResponse()
	assert.Assert(t, resp.Error != nil, "expected ServerNotInitialized error")
	assert.Equal(t, resp.Error.Code, int32(lsproto.ErrorCodeServerNotInitialized))
}

func TestServerPostShutdownRequestReturnsInvalidRequest(t *testing.T) {
	t.Parallel()
	client, closeClient := startLifecycleTestClient(t, true)
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
	assert.Assert(t, ok)
	assert.Assert(t, shutResp.Error == nil)

	// Notifications other than exit after shutdown must be ignored without panicking.
	client.SendNotification(t, lsproto.TextDocumentDidCloseInfo, &lsproto.DidCloseTextDocumentParams{
		TextDocument: lsproto.TextDocumentIdentifier{Uri: uri},
	})

	// Requests after shutdown must return InvalidRequest per LSP 3.17.
	msg, _, ok := client.SendRequest(t, lsproto.TextDocumentHoverInfo, &lsproto.HoverParams{
		TextDocument: lsproto.TextDocumentIdentifier{Uri: uri},
		Position:     lsproto.Position{Line: 0, Character: 13},
	})
	assert.Assert(t, !ok)
	assert.Assert(t, msg != nil)
	resp := msg.AsResponse()
	assert.Assert(t, resp.Error != nil, "expected InvalidRequest error after shutdown")
	assert.Equal(t, resp.Error.Code, int32(lsproto.ErrorCodeInvalidRequest))
}

func TestServerDuplicateInitializedIsIgnored(t *testing.T) {
	t.Parallel()
	client, closeClient := startLifecycleTestClient(t, true)
	defer func() { _ = closeClient() }()

	// Duplicate initialized notification must not overwrite s.session or double-close initComplete.
	client.SendNotification(t, lsproto.InitializedInfo, &lsproto.InitializedParams{})

	uri := lsproto.DocumentUri("file:///home/projects/index.ts")
	client.SendNotification(t, lsproto.TextDocumentDidOpenInfo, &lsproto.DidOpenTextDocumentParams{
		TextDocument: &lsproto.TextDocumentItem{
			Uri:        uri,
			LanguageId: "typescript",
			Text:       "export const x = 1;",
		},
	})

	msg, _, ok := client.SendRequest(t, lsproto.TextDocumentHoverInfo, &lsproto.HoverParams{
		TextDocument: lsproto.TextDocumentIdentifier{Uri: uri},
		Position:     lsproto.Position{Line: 0, Character: 13},
	})
	assert.Assert(t, ok)
	assert.Assert(t, msg.AsResponse().Error == nil)
}
