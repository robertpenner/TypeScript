package contentmapper

import (
	"context"
	"io"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/ipc"
	"github.com/microsoft/TypeScript/tsc/internal/locale"
	"gotest.tools/v3/assert"
)

func TestHostTransformAfterCloseReturnsError(t *testing.T) {
	t.Parallel()

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

	assert.NilError(t, h.Close())

	_, err := h.Transform(mapper, Request{FileName: "/proj/a.vue", Content: "<script></script>"})
	assert.ErrorContains(t, err, "closed")
}

func TestHostProjectDuplicateMapperDoesNotLeakConnRef(t *testing.T) {
	t.Parallel()

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
	assert.NilError(t, proj.Close())

	h.mu.Lock()
	leakedProjects := len(h.projects)
	leakedRefs := 0
	if connEntry := h.conns[mapper.Identity()]; connEntry != nil {
		leakedRefs = connEntry.refs
	}
	h.mu.Unlock()

	assert.Equal(t, leakedProjects, 0)
	assert.Equal(t, leakedRefs, 0)
}
