package contentmapper

import (
	"context"
	"io"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/ipc"
	"github.com/microsoft/TypeScript/tsc/internal/locale"
)

func TestReproContentMapperHostTransformAfterCloseNilDerefPanic(t *testing.T) {
	// TLC trace (ContentMapperTransformClose / NoNilProjectDeref):
	// 1. host.Close() sets h.projects = nil.
	// 2. host.Transform(mapper, request) calls project := h.Project(...) which returns nil.
	// 3. host.Transform does not check `project == nil`; `project.Transform(...)` (and
	//    `defer project.Close()`) immediately panics with a nil-pointer dereference.
	mapper := &Mapper{
		Definition: Definition{Package: "test-mapper", Extensions: []string{".vue"}},
	}
	h := newWithDial(
		context.Background(),
		locale.Default,
		&timingCollector{mappers: map[string]*mapperTimingCollector{}},
		func(_ context.Context, _ *Mapper, _ locale.Locale) (ipc.Conn, io.Closer, PositionEncoding, string, error) {
			t.Fatal("dial should not be called after host.Close()")
			return nil, nil, "", "", nil
		},
	)

	if err := h.Close(); err != nil {
		t.Fatal(err)
	}

	// Deterministic crash: host.Transform dereferences nil project returned by h.Project(...).
	_, _ = h.Transform(mapper, Request{FileName: "/proj/a.vue", Content: "<script></script>"})
	t.Fatal("expected nil-pointer dereference panic in host.Transform after host.Close()")
}

func TestReproContentMapperProjectDuplicateMapperLeaksConnRef(t *testing.T) {
	// TLC trace (ContentMapperTransformClose / NoLeakedConnRef):
	// 1. Caller invokes host.Project with duplicate *Mapper pointer [mapper, mapper].
	// 2. Unlike host.Acquire, host.Project does not deduplicate spec.Mappers: it inserts
	//    2 entries into h.projects and increments connEntry.refs to 2, while overwriting
	//    lease.entries[mapper] (a map keyed by *Mapper) so only 1 entry key is retained.
	// 3. proj.Close() iterates lease.entries once, deleting 1 entry and decrementing refs
	//    by 1 — leaving 1 leaked h.projects entry and connEntry.refs == 1 forever.
	mapper := &Mapper{
		Definition: Definition{Package: "test-mapper", Extensions: []string{".vue"}},
	}
	h := newWithDial(
		context.Background(),
		locale.Default,
		&timingCollector{mappers: map[string]*mapperTimingCollector{}},
		func(_ context.Context, _ *Mapper, _ locale.Locale) (ipc.Conn, io.Closer, PositionEncoding, string, error) {
			return nil, nil, PositionEncodingUTF8, "vue", nil
		},
	)
	defer h.Close()

	proj := h.Project(ProjectSpec{
		ConfigFileName:  "/proj/tsconfig.json",
		Mappers:         []*Mapper{mapper, mapper},
		CompilerOptions: &core.CompilerOptions{},
	})
	if err := proj.Close(); err != nil {
		t.Fatal(err)
	}

	h.mu.Lock()
	leakedProjects := len(h.projects)
	leakedRefs := 0
	if connEntry := h.conns[mapper.Identity()]; connEntry != nil {
		leakedRefs = connEntry.refs
	}
	h.mu.Unlock()

	if leakedProjects > 0 || leakedRefs > 0 {
		t.Fatalf("BUG REPRODUCED (NoLeakedConnRef): duplicate *Mapper in host.Project left %d leaked h.projects entry(ies) and connEntry.refs=%d after proj.Close()", leakedProjects, leakedRefs)
	}
}
