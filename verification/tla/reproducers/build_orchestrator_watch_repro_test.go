package build

import (
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/collections"
	"github.com/microsoft/TypeScript/tsc/internal/compiler"
	"github.com/microsoft/TypeScript/tsc/internal/diagnostics"
	"github.com/microsoft/TypeScript/tsc/internal/execute/incremental"
	"github.com/microsoft/TypeScript/tsc/internal/execute/tsc"
	"github.com/microsoft/TypeScript/tsc/internal/execute/watchmanager"
	"github.com/microsoft/TypeScript/tsc/internal/fswatch"
	"github.com/microsoft/TypeScript/tsc/internal/locale"
	"github.com/microsoft/TypeScript/tsc/internal/tsoptions"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
)

type noopCloser struct{}

func (noopCloser) Close() error { return nil }

type simpleMockWatchBackend struct {
	mu       sync.Mutex
	callback func(events []watchmanager.WatchEvent, err error)
}

func (m *simpleMockWatchBackend) WatchDirectories(requests []watchmanager.WatchDirectoryRequest) ([]io.Closer, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	closers := make([]io.Closer, len(requests))
	for i, req := range requests {
		if req.Callback != nil {
			m.callback = req.Callback
		}
		closers[i] = noopCloser{}
	}
	return closers, nil
}

func (m *simpleMockWatchBackend) SendEvents(events []watchmanager.WatchEvent) {
	m.mu.Lock()
	cb := m.callback
	m.mu.Unlock()
	if cb != nil {
		cb(events, nil)
	}
}

type watchBuildTestSystem struct {
	fs      vfs.FS
	cwd     tspath.RootedDirectoryPath
	backend *simpleMockWatchBackend
	now     time.Time
}

func newWatchBuildTestSystem(files map[string]any, cwd tspath.RootedDirectoryPath) *watchBuildTestSystem {
	return &watchBuildTestSystem{
		fs:      vfstest.FromMap(files, tspath.CaseSensitive),
		cwd:     cwd,
		backend: &simpleMockWatchBackend{},
		now:     time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC),
	}
}

func (s *watchBuildTestSystem) Writer() io.Writer                                   { return io.Discard }
func (s *watchBuildTestSystem) ErrorWriter() io.Writer                              { return io.Discard }
func (s *watchBuildTestSystem) FS() vfs.FS                                          { return s.fs }
func (s *watchBuildTestSystem) DefaultLibraryPath() tspath.RootedDirectoryPath      { return "/project" }
func (s *watchBuildTestSystem) GetCurrentDirectory() tspath.RootedDirectoryPath     { return s.cwd }
func (s *watchBuildTestSystem) WriteOutputIsTTY() bool                              { return false }
func (s *watchBuildTestSystem) GetWidthOfTerminal() int                             { return 80 }
func (s *watchBuildTestSystem) NewLine() string                                     { return "\n" }
func (s *watchBuildTestSystem) Now() time.Time                                      { return s.now }
func (s *watchBuildTestSystem) SinceStart() time.Duration                           { return 0 }
func (s *watchBuildTestSystem) GetEnvironmentVariable(name string) (string, bool)   { return "", false }
func (s *watchBuildTestSystem) Spawn([]string, string, io.Writer) (io.ReadWriteCloser, error) {
	return nil, fmt.Errorf("not implemented")
}
func (s *watchBuildTestSystem) WatchBackend() watchmanager.WatchBackend             { return s.backend }
func (s *watchBuildTestSystem) OnEmittedFiles(*compiler.EmitResult, *collections.SyncMap[tspath.PathKey, time.Time]) {
}
func (s *watchBuildTestSystem) OnListFilesStart(io.Writer)        {}
func (s *watchBuildTestSystem) OnListFilesEnd(io.Writer)          {}
func (s *watchBuildTestSystem) OnStatisticsStart(io.Writer)       {}
func (s *watchBuildTestSystem) OnStatisticsEnd(io.Writer)         {}
func (s *watchBuildTestSystem) OnBuildStatusReportStart(io.Writer) {}
func (s *watchBuildTestSystem) OnBuildStatusReportEnd(io.Writer)   {}
func (s *watchBuildTestSystem) OnWatchStatusReportStart()         {}
func (s *watchBuildTestSystem) OnWatchStatusReportEnd()           {}
func (s *watchBuildTestSystem) GetTrace(io.Writer, locale.Locale) func(msg *diagnostics.Message, args ...any) {
	return nil
}
func (s *watchBuildTestSystem) OnProgram(*incremental.Program) {}

var (
	_ tsc.System             = (*watchBuildTestSystem)(nil)
	_ tsc.CommandLineTesting = (*watchBuildTestSystem)(nil)
)

const minimalLibDts = `
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

func TestReproBuildWatchUnresolvedProjectDoubleClosePanic(t *testing.T) {
	// TLC trace (BuildOrchestratorWatch / NoChannelDoubleClose, 6 states):
	//   1. Initial watch build runs on two projects: "missing" (tsconfig.json absent,
	//      so task.resolved == nil) and "valid" (valid tsconfig.json).
	//      Initial build closes done & built channels on both tasks.
	//   2. Source file valid/index.ts changes -> DoCycle -> checkTasksForEventChanges:
	//      For "missing", `if task.resolved == nil { continue }` (orchestrator.go:609-611)
	//      skips recreating task.built and task.done (lines 723-724).
	//      needsUpdate is true, needsConfigUpdate is false -> buildOrClean runs on all tasks.
	//   3. buildOrCleanProject runs on "missing" -> defer close(t.done) panics with
	//      "close of closed channel"!
	files := map[string]any{
		"/project/lib.d.ts": minimalLibDts,
		"/project/valid/tsconfig.json": `{
			"compilerOptions": { "composite": true, "noLib": true, "outDir": "dist" },
			"files": ["../lib.d.ts", "index.ts"]
		}`,
		"/project/valid/index.ts": `export const x = 1;`,
	}
	sys := newWatchBuildTestSystem(files, "/project")
	command := tsoptions.ParseBuildCommandLine([]string{"--build", "--watch", "missing", "valid"}, sys.FS(), sys.GetCurrentDirectory())
	o := NewOrchestrator(Options{
		Sys:     sys,
		Command: command,
		Testing: sys,
	})

	ctx := t.Context()
	_ = o.Start(ctx)

	// Edit valid/index.ts and send a watch event (no config change).
	if err := sys.FS().WriteFile("/project/valid/index.ts", `export const x = 2;`); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}
	sys.backend.SendEvents([]watchmanager.WatchEvent{{Kind: fswatch.EventUpdate, Path: "/project/valid/index.ts"}})

	var panicVal any
	func() {
		defer func() {
			panicVal = recover()
		}()
		o.DoCycle(ctx)
	}()

	if panicVal != nil {
		t.Fatalf("BUG REPRODUCED (NoChannelDoubleClose): DoCycle panicked with %q when sibling project had missing tsconfig (task.resolved == nil)", fmt.Sprint(panicVal))
	}
}

func TestReproBuildWatchDownstreamUnboundedDuplicationAndStaleRetention(t *testing.T) {
	// TLC trace (BuildOrchestratorWatch / DownstreamNoStaleOrDuplicates, 6 states):
	//   1. Project B references Project A. Initial watch build sets A.downStream = [B_gen1].
	//   2. B/tsconfig.json changes -> GenerateGraphReusingOldTasks reuses A (not dirty)
	//      and creates B_gen2 (dirty). createBuildTasks resets task.upStream = nil
	//      (orchestrator.go:220) but NEVER resets task.downStream!
	//      setupBuildTask appends B_gen2 to A.downStream -> [B_gen1, B_gen2].
	//   3. Repeated config edits accumulate stale replaced *BuildTask pointers on A.downStream.
	files := map[string]any{
		"/project/lib.d.ts": minimalLibDts,
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
	sys := newWatchBuildTestSystem(files, "/project")
	command := tsoptions.ParseBuildCommandLine([]string{"--build", "--watch", "B"}, sys.FS(), sys.GetCurrentDirectory())
	o := NewOrchestrator(Options{
		Sys:     sys,
		Command: command,
		Testing: sys,
	})

	ctx := t.Context()
	_ = o.Start(ctx)

	// Trigger 3 config reloads on B (A remains unchanged and is reused).
	for i := range 3 {
		cfg := fmt.Sprintf(`{
			"compilerOptions": { "composite": true, "noLib": true, "outDir": "dist", "removeComments": %v },
			"files": ["../lib.d.ts", "index.ts"],
			"references": [{ "path": "../A" }]
		}`, i%2 == 0)
		if err := sys.FS().WriteFile("/project/B/tsconfig.json", cfg); err != nil {
			t.Fatalf("WriteFile failed: %v", err)
		}
		sys.backend.SendEvents([]watchmanager.WatchEvent{{Kind: fswatch.EventUpdate, Path: "/project/B/tsconfig.json"}})
		o.DoCycle(ctx)
	}

	taskA := o.getTask(o.caseSensitivity.PathKey("/project/A/tsconfig.json"))
	liveB := o.getTask(o.caseSensitivity.PathKey("/project/B/tsconfig.json"))

	staleCount := 0
	for _, ds := range taskA.downStream {
		if ds != liveB {
			staleCount++
		}
	}
	if len(taskA.downStream) != 1 || staleCount > 0 {
		var ptrs []string
		for _, ds := range taskA.downStream {
			ptrs = append(ptrs, fmt.Sprintf("%p(live=%v)", ds, ds == liveB))
		}
		t.Fatalf("BUG REPRODUCED (DownstreamNoStaleOrDuplicates): A.downStream grew to len=%d with %d stale replaced BuildTask(s): [%s]",
			len(taskA.downStream), staleCount, strings.Join(ptrs, ", "))
	}
}
