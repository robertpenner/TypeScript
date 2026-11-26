package lsp

import (
	"bytes"
	"context"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/bundled"
	"github.com/microsoft/TypeScript/tsc/internal/jsonrpc"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
	"gotest.tools/v3/assert"
)

type sliceReader struct {
	mu   sync.Mutex
	msgs []*lsproto.Message
	idx  int
	done chan struct{}
	once sync.Once
}

func (r *sliceReader) Read() (*lsproto.Message, error) {
	r.mu.Lock()
	if r.idx < len(r.msgs) {
		msg := r.msgs[r.idx]
		r.idx++
		r.mu.Unlock()
		return msg, nil
	}
	r.mu.Unlock()
	r.once.Do(func() { close(r.done) })
	return nil, io.EOF
}

type captureWriter struct {
	mu        sync.Mutex
	responses map[string]*lsproto.ResponseMessage
	notify    chan string
}

func (w *captureWriter) Write(msg *lsproto.Message) error {
	if msg.Kind == jsonrpc.MessageKindResponse {
		resp := msg.AsResponse()
		if resp.ID != nil {
			key := resp.ID.String()
			w.mu.Lock()
			w.responses[key] = resp
			w.mu.Unlock()
			select {
			case w.notify <- key:
			default:
			}
		}
	}
	return nil
}

func TestCancelRequestWhileQueuedInRequestQueue(t *testing.T) {
	t.Parallel()
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	fs := bundled.WrapFS(vfstest.FromMap(map[string]string{
		"/home/projects/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/home/projects/index.ts":      "export const x: number = 1;\n",
	}, tspath.CaseInsensitive))

	reqIDInt := int32(42)
	reqID := jsonrpc.NewIDInt(reqIDInt)
	unknownIDInt := int32(999)

	hoverReq := lsproto.TextDocumentHoverInfo.NewRequestMessage(reqID, &lsproto.HoverParams{
		TextDocument: lsproto.TextDocumentIdentifier{Uri: "file:///home/projects/index.ts"},
		Position:     lsproto.Position{Line: 0, Character: 13},
	}).Message()
	cancelReq := lsproto.CancelRequestInfo.NewNotificationMessage(&lsproto.CancelParams{
		Id: lsproto.IntegerOrString{Integer: &reqIDInt},
	}).Message()
	unknownCancel := lsproto.CancelRequestInfo.NewNotificationMessage(&lsproto.CancelParams{
		Id: lsproto.IntegerOrString{Integer: &unknownIDInt},
	}).Message()

	// Round-trip through ToWriter -> ToReader so Params are wire-encoded exactly as stdin delivers them.
	var wireBuf bytes.Buffer
	bw := ToWriter(&wireBuf)
	for _, msg := range []*lsproto.Message{hoverReq, cancelReq, cancelReq, unknownCancel} {
		assert.NilError(t, bw.Write(msg))
	}
	br := ToReader(&wireBuf)
	var wireMsgs []*lsproto.Message
	for range 4 {
		m, readErr := br.Read()
		assert.NilError(t, readErr)
		wireMsgs = append(wireMsgs, m)
	}

	reader := &sliceReader{
		msgs: wireMsgs,
		done: make(chan struct{}),
	}
	writer := &captureWriter{
		responses: make(map[string]*lsproto.ResponseMessage),
		notify:    make(chan string, 8),
	}

	s := NewServer(&ServerOptions{
		In:                 reader,
		Out:                writer,
		Err:                io.Discard,
		Cwd:                "/home/projects",
		FS:                 fs,
		DefaultLibraryPath: bundled.LibPath(),
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.backgroundCtx = ctx
	// Mark initialized so readLoop routes messages to requestQueue / cancelRequest directly.
	s.initializeParams = &lsproto.InitializeParams{Capabilities: &lsproto.ClientCapabilities{}}

	// Step 1: Run readLoop to EOF before starting dispatchLoop, guaranteeing #42 sits in s.requestQueue
	// when $/cancelRequest(#42) is processed by readLoop.
	err := s.readLoop(ctx)
	assert.ErrorIs(t, err, io.EOF)

	// Unknown cancel ID must never be stored in pendingClientRequests.
	s.pendingClientRequestsMu.Lock()
	_, hasUnknown := s.pendingClientRequests[*jsonrpc.NewIDInt(unknownIDInt)]
	s.pendingClientRequestsMu.Unlock()
	assert.Assert(t, !hasUnknown, "unknown cancel ID must not leak into pendingClientRequests")

	// Step 2: Start dispatchLoop and writeLoop; #42 must immediately respond with RequestCancelled
	// without invoking the hover handler (session is nil, so running hover would panic/fail differently).
	dispatchDone := make(chan error, 1)
	go func() { dispatchDone <- s.dispatchLoop(ctx) }()
	writeDone := make(chan error, 1)
	go func() { writeDone <- s.writeLoop(ctx) }()

	var resp *lsproto.ResponseMessage
	deadline := time.After(5 * time.Second)
	for {
		writer.mu.Lock()
		r, ok := writer.responses[reqID.String()]
		writer.mu.Unlock()
		if ok {
			resp = r
			break
		}
		select {
		case <-writer.notify:
		case <-deadline:
			t.Fatal("timed out waiting for cancelled response")
		}
	}

	cancel()
	<-dispatchDone
	<-writeDone

	assert.Assert(t, resp.Error != nil, "queued request canceled before dispatch must return an error response")
	assert.Equal(t, resp.Error.Code, int32(lsproto.ErrorCodeRequestCancelled))

	s.pendingClientRequestsMu.Lock()
	remaining := len(s.pendingClientRequests)
	s.pendingClientRequestsMu.Unlock()
	assert.Equal(t, remaining, 0, "pendingClientRequests must be empty after queued canceled request completes")
}

func TestCancelActiveRequestCancelsContext(t *testing.T) {
	t.Parallel()
	s := NewServer(&ServerOptions{
		In:  shutdownTestReader{},
		Out: shutdownTestWriter{},
		Err: io.Discard,
		Cwd: "/home/projects",
	})
	idInt := int32(7)
	id := jsonrpc.NewIDInt(idInt)
	reqCtx, cancel := context.WithCancel(context.Background())
	defer cancel()

	s.pendingClientRequestsMu.Lock()
	s.pendingClientRequests[*id] = pendingClientRequest{
		req:    &lsproto.RequestMessage{ID: id},
		cancel: cancel,
	}
	s.pendingClientRequestsMu.Unlock()

	s.cancelRequest(lsproto.IntegerOrString{Integer: &idInt})

	assert.ErrorIs(t, reqCtx.Err(), context.Canceled)
	s.pendingClientRequestsMu.Lock()
	remaining := len(s.pendingClientRequests)
	s.pendingClientRequestsMu.Unlock()
	assert.Equal(t, remaining, 0, "active canceled request must be removed from pendingClientRequests")

	// Canceling an already-completed or unknown ID must be a no-op with no map growth.
	s.cancelRequest(lsproto.IntegerOrString{Integer: &idInt})
	s.pendingClientRequestsMu.Lock()
	remaining = len(s.pendingClientRequests)
	s.pendingClientRequestsMu.Unlock()
	assert.Equal(t, remaining, 0)
}
