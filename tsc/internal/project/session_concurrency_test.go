package project_test

import (
	"context"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/bundled"
	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/project"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/projecttestutil"
	"gotest.tools/v3/assert"
)

func TestSessionProgramDiagnosticsSerializedInOrder(t *testing.T) {
	t.Parallel()
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/p1/tsconfig.json": `{"compilerOptions": {"noLib": true, "unknownOptionBogus": true}}`,
		"/home/projects/TS/p1/index.ts":      `export const x = 1;`,
	}
	init, utils := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})
	init.Options.PushDiagnosticsEnabled = true

	var mu sync.Mutex
	var lastPublished []*lsproto.Diagnostic
	var publishSeq []int
	firstNonEmptyBlocked := make(chan struct{})
	releaseFirstNonEmpty := make(chan struct{})
	clearedPublished := make(chan struct{})
	var blockedOnce atomic.Bool
	var clearedOnce atomic.Bool

	utils.Client().PublishDiagnosticsFunc = func(ctx context.Context, params *lsproto.PublishDiagnosticsParams) error {
		if !strings.HasSuffix(string(params.Uri), "tsconfig.json") {
			return nil
		}
		if len(params.Diagnostics) > 0 && blockedOnce.CompareAndSwap(false, true) {
			close(firstNonEmptyBlocked)
			<-releaseFirstNonEmpty
		}
		mu.Lock()
		lastPublished = params.Diagnostics
		publishSeq = append(publishSeq, len(params.Diagnostics))
		mu.Unlock()
		if len(params.Diagnostics) == 0 && clearedOnce.CompareAndSwap(false, true) {
			close(clearedPublished)
		}
		return nil
	}

	session := project.NewSession(init)
	defer session.Close()

	p1URI := lsproto.DocumentUri("file:///home/projects/TS/p1/index.ts")
	session.DidOpenFile(context.Background(), p1URI, 1, files["/home/projects/TS/p1/index.ts"].(string), lsproto.LanguageKindTypeScript)

	select {
	case <-firstNonEmptyBlocked:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for non-empty tsconfig diagnostic publish")
	}

	// Close p1 and open another file so S1->S2 clears p1's tsconfig diagnostics.
	session.DidCloseFile(context.Background(), p1URI)
	session.DidOpenFile(context.Background(), "file:///home/projects/TS/other.ts", 1, "export const y = 2;", lsproto.LanguageKindTypeScript)

	// Give the newer background task a chance to overtake if unserialized.
	select {
	case <-clearedPublished:
	case <-time.After(100 * time.Millisecond):
	}

	close(releaseFirstNonEmpty)
	session.WaitForBackgroundTasks()

	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, len(lastPublished), 0, "expected cleared tsconfig diagnostics, got sequence %v", publishSeq)
}

func TestSessionDidChangeInferredOptionsSynchronized(t *testing.T) {
	t.Parallel()
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/a.ts": `export const x = 1;`,
	}
	init, _ := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})
	session := project.NewSession(init)
	defer session.Close()

	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := range 2 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			opts := &core.CompilerOptions{NoLib: core.TSTrue, Strict: core.TSTrue}
			if i == 1 {
				opts.Strict = core.TSFalse
			}
			session.DidChangeCompilerOptionsForInferredProjects(context.Background(), opts)
		}(i)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		<-start
		session.DidOpenFile(context.Background(), "file:///home/projects/TS/a.ts", 1, "export const x = 2;", lsproto.LanguageKindTypeScript)
	}()
	close(start)
	wg.Wait()
	session.WaitForBackgroundTasks()

	// The concurrent DidOpenFile overlay must not be lost by an unlocked snapshot update.
	snap := session.Snapshot()
	content, ok := snap.ReadFile("/home/projects/TS/a.ts")
	assert.Assert(t, ok)
	assert.Equal(t, content, "export const x = 2;")
}

func TestSessionDidChangeInferredOptionsAfterCloseDoesNotPanic(t *testing.T) {
	t.Parallel()
	if !bundled.Embedded {
		t.Skip("bundled files are not embedded")
	}

	files := map[string]any{
		"/home/projects/TS/a.ts": `export const x = 1;`,
	}
	init, _ := projecttestutil.GetSessionInitOptions(files, nil, &projecttestutil.TypingsInstallerOptions{})
	session := project.NewSession(init)
	session.Close()

	session.DidChangeCompilerOptionsForInferredProjects(
		context.Background(),
		&core.CompilerOptions{NoLib: core.TSTrue},
	)
}
