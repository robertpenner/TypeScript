package contentmapper

import (
	"context"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/ipc"
	"github.com/microsoft/TypeScript/tsc/internal/json"
	"github.com/microsoft/TypeScript/tsc/internal/locale"
)

type fakeIPCConn struct {
	id          int
	mu          sync.Mutex
	openHandles map[string]bool
	closed      atomic.Bool

	onOpenProject func(handle string)
	onTransform   func(connID int, handle string, isOpen bool)
}

func (c *fakeIPCConn) Call(_ context.Context, method string, params any) (json.Value, error) {
	switch method {
	case MethodOpenProject:
		p := params.(OpenProjectParams)
		c.mu.Lock()
		c.openHandles[p.ProjectHandle] = true
		c.mu.Unlock()
		if c.onOpenProject != nil {
			c.onOpenProject(p.ProjectHandle)
		}
		return json.Value(`{}`), nil
	case MethodCloseProject:
		p := params.(CloseProjectParams)
		c.mu.Lock()
		delete(c.openHandles, p.ProjectHandle)
		c.mu.Unlock()
		return json.Value(`{}`), nil
	case MethodTransform:
		p := params.(TransformParams)
		c.mu.Lock()
		isOpen := c.openHandles[p.ProjectHandle]
		c.mu.Unlock()
		if c.onTransform != nil {
			c.onTransform(c.id, p.ProjectHandle, isOpen)
		}
		if !isOpen {
			return nil, fmt.Errorf("unknown or closed project handle %q on conn #%d", p.ProjectHandle, c.id)
		}
		return json.Value(`{"text":"export const x = 1;","extension":".ts"}`), nil
	default:
		return nil, fmt.Errorf("unexpected method %s", method)
	}
}

func (c *fakeIPCConn) Run(context.Context) error                  { return nil }
func (c *fakeIPCConn) Notify(context.Context, string, any) error { return nil }
func (c *fakeIPCConn) Close() error {
	c.closed.Store(true)
	return nil
}

func TestReproContentMapperTransformVsRefreshClosedHandle(t *testing.T) {
	// TLC trace (ContentMapperHost / NoTransformOnClosedHandle, 4 states):
	// 1. G1 calls p.Transform(mapper, req) -> holds h.mu, calls openProjectLocked -> opens handle, unlocks h.mu.
	// 2. G2 calls p.Refresh() -> acquires h.mu, sends MethodCloseProject(handle), sets entry.opened = false, unlocks h.mu.
	// 3. G1 calls h.transformLocked -> sends MethodTransform(handle) for the CLOSED handle -> FAILS!
	var conn *fakeIPCConn
	mapper := &Mapper{
		Definition: Definition{Package: "test-mapper", Extensions: []string{".vue"}},
	}

	h := newWithDial(context.Background(), locale.Default, &timingCollector{mappers: map[string]*mapperTimingCollector{}},
		func(_ context.Context, _ *Mapper, _ locale.Locale) (ipc.Conn, io.Closer, PositionEncoding, string, error) {
			conn = &fakeIPCConn{
				id:          1,
				openHandles: make(map[string]bool),
			}
			return conn, conn, PositionEncodingUTF8, "vue", nil
		})
	defer h.Close()

	proj := h.Project(ProjectSpec{
		ConfigFileName:  "/proj/tsconfig.json",
		Mappers:         []*Mapper{mapper},
		CompilerOptions: &core.CompilerOptions{},
	})
	defer proj.Close()

	// Pre-dial once so conn exists.
	if _, _, _, err := h.connFor(mapper); err != nil {
		t.Fatal(err)
	}

	for attempt := range 500 {
		var wg sync.WaitGroup
		var gotErr error
		start := make(chan struct{})
		wg.Go(func() {
			<-start
			_, gotErr = proj.Transform(mapper, Request{FileName: "/proj/a.vue", Content: "<script></script>"})
		})
		wg.Go(func() {
			<-start
			_ = proj.Refresh()
		})
		close(start)
		wg.Wait()
		if gotErr != nil {
			t.Fatalf("BUG REPRODUCED (NoTransformOnClosedHandle, attempt %d): Transform raced Refresh and sent MethodTransform on closed handle: %v", attempt+1, gotErr)
		}
	}
	t.Logf("Refresh test finished 500 iterations without error")
}

func TestReproContentMapperTransformVsCloseOrphanProcess(t *testing.T) {
	// TLC trace (ContentMapperHost / NoOrphanedZeroRefConn, 4 states):
	// 1. G1 calls p.Transform(mapper, req) -> holds h.mu, opens handle on conn #1, unlocks h.mu.
	// 2. G2 calls p.Close() -> acquires h.mu, closes handle, deletes project & conn #1 (refs -> 0), closes conn #1!
	// 3. G1 resumes in h.transformLocked -> calls h.connFor(mapper) -> h.conns[id] is nil!
	//    h.connForLocked creates a BRAND-NEW mapperConn{refs: 0}, SPAWNS ORPHAN CHILD PROCESS #2,
	//    and sends MethodTransform(handle) to conn #2 which never received MethodOpenProject!
	for attempt := range 500 {
		var dialCount atomic.Int32
		var conns []*fakeIPCConn
		var connsMu sync.Mutex

		mapper := &Mapper{
			Definition: Definition{Package: "test-mapper", Extensions: []string{".vue"}},
		}

		h := newWithDial(context.Background(), locale.Default, &timingCollector{mappers: map[string]*mapperTimingCollector{}},
			func(_ context.Context, _ *Mapper, _ locale.Locale) (ipc.Conn, io.Closer, PositionEncoding, string, error) {
				id := int(dialCount.Add(1))
				c := &fakeIPCConn{
					id:          id,
					openHandles: make(map[string]bool),
				}
				connsMu.Lock()
				conns = append(conns, c)
				connsMu.Unlock()
				return c, c, PositionEncodingUTF8, "vue", nil
			})

		proj := h.Project(ProjectSpec{
			ConfigFileName:  "/proj/tsconfig.json",
			Mappers:         []*Mapper{mapper},
			CompilerOptions: &core.CompilerOptions{},
		})

		var txErr error
		var wg sync.WaitGroup
		start := make(chan struct{})
		wg.Go(func() {
			<-start
			_, txErr = proj.Transform(mapper, Request{FileName: "/proj/a.vue", Content: "<script></script>"})
		})
		wg.Go(func() {
			<-start
			_ = proj.Close()
		})
		close(start)
		wg.Wait()

		h.mu.Lock()
		leakedConn := h.conns[mapper.Identity()]
		var leakedRefs int
		if leakedConn != nil {
			leakedRefs = leakedConn.refs
		}
		h.mu.Unlock()

		if dialCount.Load() == 2 && leakedConn != nil && leakedRefs == 0 {
			wasOpen := !conns[1].closed.Load()
			_ = h.Close()
			t.Fatalf("BUG REPRODUCED (NoOrphanedZeroRefConn, attempt %d): Transform vs Close spawned orphan child process #2 with refs=%d (still open=%v), and Transform failed with: %v",
				attempt+1, leakedRefs, wasOpen, txErr)
		}
		_ = h.Close()
	}
	t.Logf("Close test finished 500 iterations without hitting race window")
}
