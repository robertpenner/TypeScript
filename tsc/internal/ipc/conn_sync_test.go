package ipc_test

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"testing/synctest"

	"github.com/microsoft/TypeScript/tsc/internal/ipc"
	"github.com/microsoft/TypeScript/tsc/internal/json"
	"github.com/microsoft/TypeScript/tsc/internal/jsonrpc"
	"gotest.tools/v3/assert"
)

type syncFailingResponseProtocol struct {
	message     *ipc.Message
	responseErr error
}

func (p *syncFailingResponseProtocol) ReadMessage() (*ipc.Message, error) {
	if p.message == nil {
		return nil, io.EOF
	}
	message := p.message
	p.message = nil
	return message, nil
}

func (*syncFailingResponseProtocol) WriteRequest(*jsonrpc.ID, string, any) error {
	return nil
}

func (*syncFailingResponseProtocol) WriteNotification(string, any) error {
	return nil
}

func (p *syncFailingResponseProtocol) WriteResponse(*jsonrpc.ID, any) error {
	return p.responseErr
}

func (p *syncFailingResponseProtocol) WriteError(*jsonrpc.ID, *jsonrpc.ResponseError) error {
	return p.responseErr
}

type panicHandler struct{}

func (panicHandler) HandleRequest(context.Context, string, json.Value) (any, error) {
	panic("handler panic")
}

func (panicHandler) HandleNotification(context.Context, string, json.Value) error {
	return nil
}

func TestSyncConnRunReturnsResponseWriteFailure(t *testing.T) {
	t.Parallel()
	responseErr := errors.New("response write failed")
	protocol := &syncFailingResponseProtocol{
		message:     &ipc.Message{ID: jsonrpc.NewIDInt(1), Method: "transform"},
		responseErr: responseErr,
	}
	conn := ipc.NewSyncConn(nil, protocol, noOpHandler{})

	err := conn.Run(t.Context())
	assert.Assert(t, errors.Is(err, responseErr), "expected response write error, got %v", err)
}

func TestSyncConnRunReturnsPanicResponseWriteFailure(t *testing.T) {
	t.Parallel()
	responseErr := errors.New("response write failed")
	protocol := &syncFailingResponseProtocol{
		message:     &ipc.Message{ID: jsonrpc.NewIDInt(1), Method: "transform"},
		responseErr: responseErr,
	}
	conn := ipc.NewSyncConn(nil, protocol, panicHandler{})

	err := conn.Run(t.Context())
	assert.Assert(t, errors.Is(err, responseErr), "expected panic response write error, got %v", err)
	assert.ErrorContains(t, err, "original panic: handler panic")
}

type gatedHandler map[string]chan struct{}

func (h gatedHandler) HandleRequest(_ context.Context, _ string, params json.Value) (any, error) {
	<-h[string(params)]
	return params, nil
}

func (gatedHandler) HandleNotification(context.Context, string, json.Value) error {
	return nil
}

func TestSyncConnAnswersNestedRequestsInStackOrder(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
		server, client := net.Pipe()
		handler := gatedHandler{`"a"`: make(chan struct{}), `"b"`: make(chan struct{})}
		conn := ipc.NewSyncConn(server, ipc.NewJSONRPCProtocol(server), handler)
		peer := ipc.NewJSONRPCProtocol(client)
		answers := map[string]string{}
		var serve func() json.Value
		serve = func() json.Value {
			for {
				msg, err := peer.ReadMessage()
				if err != nil {
					return nil
				}
				if msg.IsResponse() {
					return msg.Result
				}
				_ = peer.WriteRequest(jsonrpc.NewIDString("resolve"), "resolve", msg.Params)
				answers[string(msg.Params)] = string(serve())
				_ = peer.WriteResponse(msg.ID, msg.Params)
			}
		}
		go serve()

		var wg sync.WaitGroup
		var a, b json.Value
		wg.Go(func() { a, _ = conn.Call(t.Context(), "callback", json.Value(`"a"`)) })
		synctest.Wait()
		wg.Go(func() { b, _ = conn.Call(t.Context(), "callback", json.Value(`"b"`)) })
		synctest.Wait()
		close(handler[`"a"`])
		synctest.Wait()
		close(handler[`"b"`])
		wg.Wait()
		assert.NilError(t, client.Close())

		assert.DeepEqual(t, answers, map[string]string{`"a"`: `"a"`, `"b"`: `"b"`})
		assert.Equal(t, string(a), `"a"`)
		assert.Equal(t, string(b), `"b"`)
	})
}

type callingNotificationHandler struct {
	noOpHandler
	conn *ipc.SyncConn
}

func (h *callingNotificationHandler) HandleNotification(ctx context.Context, _ string, _ json.Value) error {
	_, err := h.conn.Call(ctx, "inner", nil)
	return err
}

func TestSyncConnNotificationHandlerCanCall(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
		server, client := net.Pipe()
		handler := &callingNotificationHandler{}
		conn := ipc.NewSyncConn(server, ipc.NewJSONRPCProtocol(server), handler)
		handler.conn = conn
		peer := ipc.NewJSONRPCProtocol(client)
		go func() {
			outer, _ := peer.ReadMessage()
			_ = peer.WriteNotification("notify", nil)
			inner, _ := peer.ReadMessage()
			_ = peer.WriteResponse(inner.ID, inner.Method)
			_ = peer.WriteResponse(outer.ID, outer.Method)
		}()

		result, err := conn.Call(t.Context(), "outer", nil)
		assert.NilError(t, err)
		assert.Equal(t, string(result), `"outer"`)
	})
}

type bufferedChannelProtocol struct {
	in  chan *ipc.Message
	out chan *ipc.Message
}

func newBufferedChannelProtocolPair(buf int) (*bufferedChannelProtocol, *bufferedChannelProtocol) {
	aToB := make(chan *ipc.Message, buf)
	bToA := make(chan *ipc.Message, buf)
	return &bufferedChannelProtocol{in: bToA, out: aToB}, &bufferedChannelProtocol{in: aToB, out: bToA}
}

func (p *bufferedChannelProtocol) ReadMessage() (*ipc.Message, error) {
	msg, ok := <-p.in
	if !ok {
		return nil, io.EOF
	}
	return msg, nil
}

func (p *bufferedChannelProtocol) WriteRequest(id *jsonrpc.ID, method string, params any) error {
	raw, _ := json.Marshal(params)
	p.out <- &ipc.Message{ID: id, Method: method, Params: raw}
	return nil
}

func (p *bufferedChannelProtocol) WriteNotification(method string, params any) error {
	raw, _ := json.Marshal(params)
	p.out <- &ipc.Message{Method: method, Params: raw}
	return nil
}

func (p *bufferedChannelProtocol) WriteResponse(id *jsonrpc.ID, result any) error {
	raw, _ := json.Marshal(result)
	p.out <- &ipc.Message{ID: id, Result: raw}
	return nil
}

func (p *bufferedChannelProtocol) WriteError(id *jsonrpc.ID, err *jsonrpc.ResponseError) error {
	p.out <- &ipc.Message{ID: id, Error: err}
	return nil
}

func (p *bufferedChannelProtocol) Close() {
	close(p.out)
}

type blockingSyncNotifHandler struct {
	noOpHandler
	entered chan struct{}
	release chan struct{}
}

func (h *blockingSyncNotifHandler) HandleNotification(context.Context, string, json.Value) error {
	close(h.entered)
	<-h.release
	return nil
}

func TestSyncConnNotificationDoesNotSwapConcurrentCallResponses(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
		serverProto, peerProto := newBufferedChannelProtocolPair(8)
		handler := &blockingSyncNotifHandler{
			entered: make(chan struct{}),
			release: make(chan struct{}),
		}
		conn := ipc.NewSyncConn(nil, serverProto, handler)

		go func() {
			req1, err := peerProto.ReadMessage()
			if err != nil {
				return
			}
			// Peer sends a notification followed immediately by G1's response
			// without waiting for the server to handle the notification.
			_ = peerProto.WriteNotification("log", "progress")
			_ = peerProto.WriteResponse(req1.ID, "CONTENT_A")

			req2, err := peerProto.ReadMessage()
			if err != nil {
				return
			}
			_ = peerProto.WriteResponse(req2.ID, "CONTENT_B")
		}()

		var wg sync.WaitGroup
		var res1, res2 json.Value
		var err1, err2 error

		wg.Go(func() {
			res1, err1 = conn.Call(t.Context(), "readFile", "a.ts")
		})

		<-handler.entered

		// G1 is inside HandleNotification; an unrelated concurrent Call must not
		// steal the wire and consume G1's already-buffered response.
		wg.Go(func() {
			res2, err2 = conn.Call(t.Context(), "readFile", "b.ts")
		})
		synctest.Wait()

		close(handler.release)
		wg.Wait()
		serverProto.Close()
		peerProto.Close()

		assert.NilError(t, err1)
		assert.NilError(t, err2)
		assert.Equal(t, string(res1), `"CONTENT_A"`)
		assert.Equal(t, string(res2), `"CONTENT_B"`)
	})
}

type cancelledCallHandler struct {
	noOpHandler
	conn *ipc.SyncConn
}

func (h *cancelledCallHandler) HandleRequest(_ context.Context, _ string, _ json.Value) (any, error) {
	cancelledCtx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := h.conn.Call(cancelledCtx, "readFile", "cancelled.ts")
	if !errors.Is(err, context.Canceled) {
		return nil, err
	}
	return "ok", nil
}

func TestSyncConnCancelledCallDoesNotWriteOrPoisonRun(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
		serverProto, peerProto := newBufferedChannelProtocolPair(8)
		handler := &cancelledCallHandler{}
		conn := ipc.NewSyncConn(nil, serverProto, handler)
		handler.conn = conn

		runErrCh := make(chan error, 1)
		go func() {
			runErrCh <- conn.Run(t.Context())
		}()

		assert.NilError(t, peerProto.WriteRequest(jsonrpc.NewIDInt(1), "check", nil))

		// Because the callback's context was already cancelled, no "readFile"
		// request should be written on the wire; the peer should directly receive
		// the response to "check" (id=1).
		msg, err := peerProto.ReadMessage()
		assert.NilError(t, err)
		if msg.IsRequest() {
			// If buggy code still wrote the cancelled callback request, reply to it
			// and drain the "check" response so Run() fails visibly.
			_ = peerProto.WriteResponse(msg.ID, "STALE_REPLY")
			_, _ = peerProto.ReadMessage()
			t.Fatalf("cancelled Call wrote unexpected request %q on wire", msg.Method)
		}
		assert.Assert(t, msg.IsResponse())
		assert.Equal(t, string(msg.Result), `"ok"`)

		peerProto.Close()
		assert.NilError(t, <-runErrCh)
	})
}

type cancelOnWriteProtocol struct {
	*bufferedChannelProtocol
	cancel context.CancelFunc
}

func (p *cancelOnWriteProtocol) WriteRequest(id *jsonrpc.ID, method string, params any) error {
	err := p.bufferedChannelProtocol.WriteRequest(id, method, params)
	p.cancel()
	return err
}

func TestSyncConnCallCancelledDuringWriteDrainsResponse(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
		serverProto, peerProto := newBufferedChannelProtocolPair(8)
		ctx, cancel := context.WithCancel(t.Context())
		wrapped := &cancelOnWriteProtocol{bufferedChannelProtocol: serverProto, cancel: cancel}
		conn := ipc.NewSyncConn(nil, wrapped, noOpHandler{})

		var peerWg sync.WaitGroup
		peerWg.Go(func() {
			defer peerProto.Close()
			req, err := peerProto.ReadMessage()
			if err != nil {
				return
			}
			_ = peerProto.WriteResponse(req.ID, "DRAINED_REPLY")
		})

		_, err := conn.Call(ctx, "readFile", "midflight.ts")
		assert.Assert(t, errors.Is(err, context.Canceled), "expected context.Canceled, got %v", err)

		peerWg.Wait()
		// The response must have been drained so Run() does not fail with an
		// unexpected response message.
		assert.NilError(t, conn.Run(t.Context()))
	})
}
