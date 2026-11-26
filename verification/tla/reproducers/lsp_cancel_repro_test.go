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

func TestReproLspServerDroppedCancelInQueue(t *testing.T) {
	// TLC trace (LspServerCancel / NoDroppedCancellation, 7 states):
	// Client sends synchronous DidChange notifications to keep dispatchLoop briefly busy,
	// then sends Hover request #N followed immediately by $/cancelRequest(#N).
	// readLoop reads Hover #N into s.requestQueue (NOT yet in s.pendingClientRequests),
	// then immediately intercepts $/cancelRequest(#N) and calls s.cancelRequest(#N).
	// Because #N is still in s.requestQueue, pendingClientRequests lookup misses and
	// SILENTLY DROPS the cancellation. dispatchLoop then pops #N and executes hover
	// with an uncanceled context, returning a normal result instead of ErrorCodeRequestCancelled!
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	fs := bundled.WrapFS(vfstest.FromMap(map[string]string{
		"/home/projects/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/home/projects/index.ts":      "export const x: number = 1;\n",
	}, tspath.CaseInsensitive))

	onServerRequest := func(_ context.Context, req *lsproto.RequestMessage) *lsproto.ResponseMessage {
		return &lsproto.ResponseMessage{
			ID:      req.ID,
			JSONRPC: req.JSONRPC,
			Result:  lsproto.Null{},
		}
	}

	client, closeClient := lsptestutil.NewLSPClient(t, lsp.ServerOptions{
		Err:                io.Discard,
		Cwd:                "/home/projects",
		FS:                 fs,
		DefaultLibraryPath: bundled.LibPath(),
	}, onServerRequest)
	defer func() { assert.NilError(t, closeClient()) }()

	initMsg, _, ok := client.SendRequest(t, lsproto.InitializeInfo, &lsproto.InitializeParams{
		Capabilities: &lsproto.ClientCapabilities{},
	})
	assert.Assert(t, ok && initMsg.AsResponse().Error == nil)
	client.SendNotification(t, lsproto.InitializedInfo, &lsproto.InitializedParams{})
	<-client.Server.InitComplete()

	client.SendNotification(t, lsproto.TextDocumentDidOpenInfo, &lsproto.DidOpenTextDocumentParams{
		TextDocument: &lsproto.TextDocumentItem{
			Uri:        "file:///home/projects/index.ts",
			LanguageId: lsproto.LanguageKindTypeScript,
			Version:    1,
			Text:       "export const x: number = 1;\n",
		},
	})

	// Send a burst of DidChange notifications (queued into s.requestQueue ahead of Hover)
	// followed immediately by Hover #id and $/cancelRequest(#id).
	var version int32 = 2
	for attempt := range 20 {
		for range 15 {
			client.SendNotification(t, lsproto.TextDocumentDidChangeInfo, &lsproto.DidChangeTextDocumentParams{
				TextDocument: lsproto.VersionedTextDocumentIdentifier{
					Uri:     "file:///home/projects/index.ts",
					Version: version,
				},
				ContentChanges: []lsproto.TextDocumentContentChangePartialOrWholeDocument{{
					WholeDocument: &lsproto.TextDocumentContentChangeWholeDocument{
						Text: "export const x: number = 1;\n",
					},
				}},
			})
			version++
		}

		// Predict the exact ID that SendRequestAsync will allocate (it calls NextID() once).
		// Better yet: read NextID? No, SendRequestAsync calls c.NextID() internally!
		// Peek next ID by calling SendRequestWorker directly with explicit reqID.
		reqIDInt := client.NextID()
		reqID := lsproto.NewID(lsproto.IntegerOrString{Integer: &reqIDInt})
		hoverReq := lsproto.TextDocumentHoverInfo.NewRequestMessage(reqID, &lsproto.HoverParams{
			TextDocument: lsproto.TextDocumentIdentifier{Uri: "file:///home/projects/index.ts"},
			Position:     lsproto.Position{Line: 0, Character: 13},
		})

		doneResp := make(chan *lsproto.ResponseMessage, 1)
		go func() {
			resp, _ := client.SendRequestWorker(t, hoverReq, reqID)
			doneResp <- resp
		}()

		// Immediately cancel the same request ID while it is still behind the DidChange burst in requestQueue.
		client.SendNotification(t, lsproto.CancelRequestInfo, &lsproto.CancelParams{
			Id: lsproto.IntegerOrString{Integer: &reqIDInt},
		})

		resp := <-doneResp
		if resp != nil && resp.Error == nil {
			t.Fatalf("BUG REPRODUCED (NoDroppedCancellation, attempt %d): $/cancelRequest(%d) was silently dropped while request sat in requestQueue; server returned normal hover result instead of RequestCancelled: %#v",
				attempt+1, reqIDInt, resp.Result)
		}
	}
	t.Log("all 20 attempts returned cancelled")
}
