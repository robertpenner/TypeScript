package ipc_test

import (
	"context"
	"net"
	"strings"
	"sync"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/ipc"
	"github.com/microsoft/TypeScript/tsc/internal/json"
	"github.com/microsoft/TypeScript/tsc/internal/jsonrpc"
)

// newLoopbackPair returns a buffered TCP loopback connection pair, mirroring
// production Unix sockets / named pipes where a peer can write a notification
// followed immediately by a response without blocking on the server's read.
func newLoopbackPair(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := ln.Accept()
		if err == nil {
			accepted <- c
		}
	}()

	client, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	server := <-accepted
	t.Cleanup(func() {
		_ = server.Close()
		_ = client.Close()
	})
	return server, client
}

type blockingNotifHandler struct {
	entered chan struct{}
	release chan struct{}
}

func (blockingNotifHandler) HandleRequest(context.Context, string, json.Value) (any, error) {
	return nil, nil
}

func (h *blockingNotifHandler) HandleNotification(context.Context, string, json.Value) error {
	close(h.entered)
	<-h.release
	return nil
}

// TestReproIpcSyncConnNotificationConcurrentCallResponseSwap reproduces Defect 4.1a
// (IpcSyncConn.tla / IpcSyncConn_NotificationSwap.cfg, conn_sync.go:183-256).
//
// When G1 is waiting for the response to Call("readFile", "a.ts") and G2 is
// waiting in lockTurn for Call("readFile", "b.ts"), a fire-and-forget peer
// notification followed immediately by G1's response causes G1 to clear
// c.reading and unlock c.mu before HandleNotification. G2 wakes up, sends its
// "readFile" request, and consumes G1's response off the wire because
// SyncConn.Call matches responses solely by method name. Both calls succeed
// with err == nil and silently swapped payloads.
func TestReproIpcSyncConnNotificationConcurrentCallResponseSwap(t *testing.T) {
	t.Parallel()
	server, client := newLoopbackPair(t)
	handler := &blockingNotifHandler{
		entered: make(chan struct{}),
		release: make(chan struct{}),
	}
	conn := ipc.NewSyncConn(server, ipc.NewJSONRPCProtocol(server), handler)
	peer := ipc.NewJSONRPCProtocol(client)

	g1Sent := make(chan struct{})
	g2Done := make(chan struct{})

	go func() {
		// 1. Read G1's request ("a.ts").
		req1, err := peer.ReadMessage()
		if err != nil {
			return
		}
		close(g1Sent)

		// Wait until G2 has started (we synchronize via G1 entering HandleNotification
		// after peer writes Notification + Response for G1).
		_ = peer.WriteNotification("log", json.Value(`"progress"`))
		_ = peer.WriteResponse(req1.ID, json.Value(`"CONTENT_A"`))

		// 2. Read G2's request ("b.ts") and reply with CONTENT_B.
		req2, err := peer.ReadMessage()
		if err != nil {
			return
		}
		// Wait until G2 has finished consuming G1's response before releasing G1's
		// notification handler, then deliver G2's response which G1 will consume.
		<-g2Done
		_ = peer.WriteResponse(req2.ID, json.Value(`"CONTENT_B"`))
	}()

	var wg sync.WaitGroup
	var res1, res2 json.Value
	var err1, err2 error

	wg.Go(func() {
		res1, err1 = conn.Call(t.Context(), "readFile", json.Value(`"a.ts"`))
	})

	<-g1Sent
	<-handler.entered

	// G1 is now inside HandleNotification with c.reading == false and c.mu unlocked.
	// G2 enters Call("readFile", "b.ts"), grabs the turn, sends its request, and
	// immediately reads G1's already-buffered response "CONTENT_A".
	wg.Go(func() {
		res2, err2 = conn.Call(t.Context(), "readFile", json.Value(`"b.ts"`))
		close(g2Done)
	})

	<-g2Done
	close(handler.release)
	wg.Wait()

	if err1 != nil || err2 != nil {
		t.Fatalf("expected clean responses, got err1=%v err2=%v", err1, err2)
	}
	if string(res1) != `"CONTENT_A"` || string(res2) != `"CONTENT_B"` {
		t.Fatalf("BUG REPRODUCED: silent cross-call response swap on notification: G1(a.ts) got %s (err=%v), G2(b.ts) got %s (err=%v)",
			string(res1), err1, string(res2), err2)
	}
}

type cancelledCallbackHandler struct {
	conn *ipc.SyncConn
}

func (h *cancelledCallbackHandler) HandleRequest(_ context.Context, _ string, _ json.Value) (any, error) {
	// Simulate an already-cancelled caller context invoking SyncConn.Call from
	// inside an incoming request handler (the production API callback pattern).
	cancelledCtx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _ = h.conn.Call(cancelledCtx, "readFile", json.Value(`"cancelled.ts"`))
	return json.Value(`"ok"`), nil
}

func (*cancelledCallbackHandler) HandleNotification(context.Context, string, json.Value) error {
	return nil
}

// TestReproIpcSyncConnCancelledCallOrphansResponseAndPoisonsConn reproduces Defect 4.1b
// (IpcSyncConn.tla / IpcSyncConn_CancelOrphan.cfg, conn_sync.go:205-218).
//
// SyncConn.Call invokes protocol.WriteRequest BEFORE checking ctx.Err(). When
// ctx is cancelled, the request is still sent to the peer, Call returns
// ctx.Err() without reading the peer's reply, and the orphaned response poisons
// the stream so Run() immediately fails with "unexpected response message".
func TestReproIpcSyncConnCancelledCallOrphansResponseAndPoisonsConn(t *testing.T) {
	t.Parallel()
	server, client := newLoopbackPair(t)
	handler := &cancelledCallbackHandler{}
	conn := ipc.NewSyncConn(server, ipc.NewJSONRPCProtocol(server), handler)
	handler.conn = conn
	peer := ipc.NewJSONRPCProtocol(client)

	runErrCh := make(chan error, 1)
	go func() {
		runErrCh <- conn.Run(t.Context())
	}()

	// Peer sends an API request to the server.
	if err := peer.WriteRequest(jsonrpc.NewIDInt(1), "check", nil); err != nil {
		t.Fatalf("write initial request: %v", err)
	}

	// Server's handler called conn.Call(cancelledCtx, "readFile", ...).
	// Because WriteRequest runs BEFORE checking ctx.Err(), the peer still
	// receives the "readFile" callback request and replies normally.
	cbReq, err := peer.ReadMessage()
	if err != nil {
		t.Fatalf("read callback request: %v", err)
	}
	if !cbReq.IsRequest() || cbReq.Method != "readFile" {
		t.Fatalf("expected readFile callback request, got %+v", cbReq)
	}
	if err := peer.WriteResponse(cbReq.ID, json.Value(`"STALE_REPLY"`)); err != nil {
		t.Fatalf("write callback response: %v", err)
	}

	// Read the response to the initial "check" request (id=1).
	initResp, err := peer.ReadMessage()
	if err != nil {
		t.Fatalf("read initial response: %v", err)
	}
	if !initResp.IsResponse() {
		t.Fatalf("expected initial response, got %+v", initResp)
	}

	// Run() now loops around and reads the orphaned "readFile" response, which
	// permanently terminates the SyncConn with an unexpected-response error!
	runErr := <-runErrCh
	if runErr != nil && strings.Contains(runErr.Error(), "unexpected response message") {
		t.Fatalf("BUG REPRODUCED: cancelled Call() still wrote request and orphaned response poisoned SyncConn.Run(): %v", runErr)
	}
}
