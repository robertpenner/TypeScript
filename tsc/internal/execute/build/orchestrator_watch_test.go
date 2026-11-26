package build

import (
	"fmt"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/collections"
	"github.com/microsoft/TypeScript/tsc/internal/compiler"
	"github.com/microsoft/TypeScript/tsc/internal/diagnostics"
	"github.com/microsoft/TypeScript/tsc/internal/execute/incremental"
	"github.com/microsoft/TypeScript/tsc/internal/execute/watchmanager"
	"github.com/microsoft/TypeScript/tsc/internal/fswatch"
	"github.com/microsoft/TypeScript/tsc/internal/locale"
	"github.com/microsoft/TypeScript/tsc/internal/tsoptions"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
	"gotest.tools/v3/assert"
)

type watchTestNoopCloser struct{}

func (watchTestNoopCloser) Close() error { return nil }

type watchTestMockBackend struct {
	mu       sync.Mutex
	callback func(events []watchmanager.WatchEvent, err error)
}

func (m *watchTestMockBackend) WatchDirectories(requests []watchmanager.WatchDirectoryRequest) ([]io.Closer, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	closers := make([]io.Closer, len(requests))
	for i, req := range requests {
		if req.Callback != nil {
			m.callback = req.Callback
		}
		closers[i] = watchTestNoopCloser{}
	}
	return closers, nil
}

func (m *watchTestMockBackend) SendEvents(events []watchmanager.WatchEvent) {
	m.mu.Lock()
	cb := m.callback
	m.mu.Unlock()
	if cb != nil {
		cb(events, nil)
	}
}

type watchTestSystem struct {
	fs      vfs.FS
	cwd     tspath.RootedDirectoryPath
	backend *watchTestMockBackend
	now     time.Time
}

func newWatchTestSystem(files map[string]any, cwd tspath.RootedDirectoryPath) *watchTestSystem {
	return &watchTestSystem{
		fs:      vfstest.FromMap(files, tspath.CaseSensitive),
		cwd:     cwd,
		backend: &watchTestMockBackend{},
		now:     time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC),
	}
}

func (s *watchTestSystem) Writer() io.Writer                                 { return io.Discard }
func (s *watchTestSystem) ErrorWriter() io.Writer                            { return io.Discard }
func (s *watchTestSystem) FS() vfs.FS                                        { return s.fs }
func (s *watchTestSystem) DefaultLibraryPath() tspath.RootedDirectoryPath    { return "/project" }
func (s *watchTestSystem) GetCurrentDirectory() tspath.RootedDirectoryPath   { return s.cwd }
func (s *watchTestSystem) WriteOutputIsTTY() bool                            { return false }
func (s *watchTestSystem) GetWidthOfTerminal() int                           { return 80 }
func (s *watchTestSystem) NewLine() string                                   { return "\n" }
func (s *watchTestSystem) Now() time.Time                                    { return s.now }
func (s *watchTestSystem) SinceStart() time.Duration                         { return 0 }
func (s *watchTestSystem) GetEnvironmentVariable(name string) (string, bool) { return "", false }
func (s *watchTestSystem) Spawn([]string, string, io.Writer) (io.ReadWriteCloser, error) {
	return nil, fmt.Errorf("not implemented")
}
func (s *watchTestSystem) WatchBackend() watchmanager.WatchBackend { return s.backend }
func (s *watchTestSystem) OnEmittedFiles(*compiler.EmitResult, *collections.SyncMap[tspath.PathKey, time.Time]) {
}
func (s *watchTestSystem) OnListFilesStart(io.Writer)         {}
func (s *watchTestSystem) OnListFilesEnd(io.Writer)           {}
func (s *watchTestSystem) OnStatisticsStart(io.Writer)        {}
func (s *watchTestSystem) OnStatisticsEnd(io.Writer)          {}
func (s *watchTestSystem) OnBuildStatusReportStart(io.Writer) {}
func (s *watchTestSystem) OnBuildStatusReportEnd(io.Writer)   {}
func (s *watchTestSystem) OnWatchStatusReportStart()          {}
func (s *watchTestSystem) OnWatchStatusReportEnd()            {}
func (s *watchTestSystem) GetTrace(io.Writer, locale.Locale) func(msg *diagnostics.Message, args ...any) {
	return nil
}
func (s *watchTestSystem) OnProgram(*incremental.Program) {}

const watchTestMinimalLibDts = `
interface Array<T> {}
interface Boolean {}
interface CallableFunction {}
interface Function {}
interface IArguments {}
interface NewableFunction {}
interface Number {}
interface Object {}
interface RegExp {}
interface String {}
`

func TestBuildWatchUnresolvedProjectRebuildsCleanly(t *testing.T) {
	t.Parallel()

	files := map[string]any{
		"/project/lib.d.ts": watchTestMinimalLibDts,
		"/project/valid/tsconfig.json": `{
			"compilerOptions": { "composite": true, "noLib": true, "outDir": "dist" },
			"files": ["../lib.d.ts", "index.ts"]
		}`,
		"/project/valid/index.ts": `export const x = 1;`,
	}
	sys := newWatchTestSystem(files, "/project")
	command := tsoptions.ParseBuildCommandLine([]string{"--build", "--watch", "missing", "valid"}, sys.FS(), sys.GetCurrentDirectory())
	o := NewOrchestrator(Options{
		Sys:     sys,
		Command: command,
		Testing: sys,
	})

	ctx := t.Context()
	_ = o.Start(ctx)

	for i := 2; i <= 4; i++ {
		assert.NilError(t, sys.FS().WriteFile("/project/valid/index.ts", fmt.Sprintf(`export const x = %d;`, i)))
		sys.backend.SendEvents([]watchmanager.WatchEvent{{Kind: fswatch.EventUpdate, Path: "/project/valid/index.ts"}})
		o.DoCycle(ctx)
	}
}

func TestBuildWatchDownstreamTasksClearedOnConfigReload(t *testing.T) {
	t.Parallel()

	files := map[string]any{
		"/project/lib.d.ts": watchTestMinimalLibDts,
		"/project/A/tsconfig.json": `{
			"compilerOptions": { "composite": true, "noLib": true, "outDir": "dist" },
			"files": ["../lib.d.ts", "index.ts"]
		}`,
		"/project/A/index.ts": `export const a = 1;`,
		"/project/B/tsconfig.json": `{
			"compilerOptions": { "composite": true, "noLib": true, "outDir": "dist" },
			"files": ["../lib.d.ts", "index.ts"],
			"references": [{ "path": "../A" }]
		}`,
		"/project/B/index.ts": `import { a } from "../A/index"; export const b = a + 1;`,
	}
	sys := newWatchTestSystem(files, "/project")
	command := tsoptions.ParseBuildCommandLine([]string{"--build", "--watch", "B"}, sys.FS(), sys.GetCurrentDirectory())
	o := NewOrchestrator(Options{
		Sys:     sys,
		Command: command,
		Testing: sys,
	})

	ctx := t.Context()
	_ = o.Start(ctx)

	for i := range 3 {
		cfg := fmt.Sprintf(`{
			"compilerOptions": { "composite": true, "noLib": true, "outDir": "dist", "removeComments": %v },
			"files": ["../lib.d.ts", "index.ts"],
			"references": [{ "path": "../A" }]
		}`, i%2 == 0)
		assert.NilError(t, sys.FS().WriteFile("/project/B/tsconfig.json", cfg))
		sys.backend.SendEvents([]watchmanager.WatchEvent{{Kind: fswatch.EventUpdate, Path: "/project/B/tsconfig.json"}})
		o.DoCycle(ctx)
	}

	taskA := o.getTask(o.caseSensitivity.PathKey("/project/A/tsconfig.json"))
	liveB := o.getTask(o.caseSensitivity.PathKey("/project/B/tsconfig.json"))

	assert.Equal(t, len(taskA.downStream), 1)
	assert.Equal(t, taskA.downStream[0], liveB)
}
