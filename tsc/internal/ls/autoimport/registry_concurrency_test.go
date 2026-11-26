package autoimport_test

import (
	"context"
	"errors"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/ls"
	"github.com/microsoft/TypeScript/tsc/internal/ls/autoimport"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/modulespecifiers"
	"github.com/microsoft/TypeScript/tsc/internal/project"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/projecttestutil"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
	"gotest.tools/v3/assert"
)

// cancelAfterBuildProjectBucketEntryCtx lets the entry guard of
// buildProjectBucket see nil, then cancels the context so workers skip
// extraction while buildProjectBucket is in flight.
type cancelAfterBuildProjectBucketEntryCtx struct {
	context.Context
	armed  atomic.Bool
	cancel func()
}

func (c *cancelAfterBuildProjectBucketEntryCtx) Err() error {
	if err := c.Context.Err(); err != nil {
		return err
	}
	if c.armed.Load() {
		var pcs [6]uintptr
		n := runtime.Callers(2, pcs[:])
		frames := runtime.CallersFrames(pcs[:n])
		for {
			frame, more := frames.Next()
			if strings.Contains(frame.Function, "buildProjectBucket") {
				if c.armed.CompareAndSwap(true, false) {
					c.cancel()
					return nil
				}
				break
			}
			if !more {
				break
			}
		}
	}
	return c.Context.Err()
}

func TestAutoImportBuildProjectBucketCancelDoesNotCommitTruncatedCleanBucket(t *testing.T) {
	t.Parallel()
	const root = "/home/src/cancel-clean-commit"
	files := map[string]any{
		root + "/tsconfig.json": `{
			"compilerOptions": { "module": "esnext", "target": "esnext", "strict": true }
		}`,
		root + "/index.ts": "export {};\n",
		root + "/alpha.ts": "export const alphaExport = 1;\n",
		root + "/beta.ts":  "export const betaExport = 2;\n",
	}

	session, _ := projecttestutil.Setup(files)
	t.Cleanup(session.Close)

	indexURI := lsproto.DocumentUri("file://" + root + "/index.ts")
	session.DidOpenFile(context.Background(), indexURI, 1, "export {};\n", lsproto.LanguageKindTypeScript)

	baseCtx, cancelReq := context.WithCancel(context.Background())
	t.Cleanup(cancelReq)
	reqCtx := &cancelAfterBuildProjectBucketEntryCtx{
		Context: baseCtx,
		cancel:  cancelReq,
	}

	asyncWork, err := session.WithLanguageServiceAndSnapshot(
		context.Background(),
		indexURI,
		func(_ *ls.LanguageService, snap *project.Snapshot) (func() error, error) {
			return func() error {
				reqCtx.armed.Store(true)
				_, lsErr := session.GetLanguageServiceWithAutoImports(reqCtx, snap, indexURI)
				return lsErr
			}, nil
		},
	)
	assert.NilError(t, err)
	workErr := asyncWork()
	assert.Assert(t, errors.Is(workErr, context.Canceled), "expected context.Canceled, got: %v", workErr)
	assert.Assert(t, reqCtx.Err() != nil, "expected reqCtx to be cancelled inside buildProjectBucket")

	session.WaitForBackgroundTasks()

	// A subsequent non-cancelled request must build a complete project bucket
	// with both exports (alphaExport and betaExport) rather than inheriting a
	// clean 0-export bucket from the cancelled request.
	_, err = session.GetCurrentLanguageServiceWithAutoImports(context.Background(), indexURI)
	assert.NilError(t, err)

	statsAfter := session.Snapshot().AutoImportRegistry().GetCacheStats()
	assert.Equal(t, len(statsAfter.ProjectBuckets), 1)
	assert.Assert(t, statsAfter.ProjectBuckets[0].ExportCount >= 2,
		"expected at least 2 project exports after non-cancelled rebuild, got %d",
		statsAfter.ProjectBuckets[0].ExportCount)
}

func TestAutoImportSharedEntrypointsPreservedAcrossBucketRebuild(t *testing.T) {
	t.Parallel()
	const root = "/home/src/monorepo-shared-entrypoints"
	sharedDir := root + "/packages/shared-pkg"
	app1Dir := root + "/apps/app1"
	app2Dir := root + "/apps/app2"

	files := map[string]any{
		sharedDir + "/package.json": `{
			"name": "shared-pkg",
			"version": "1.0.0",
			"exports": {
				".": {
					"browser": "./dist/browser.d.ts"
				}
			}
		}`,
		sharedDir + "/dist/browser.d.ts": `export declare const browserOnlyHelper: number;`,

		app1Dir + "/package.json": `{
			"name": "app1",
			"dependencies": {
				"shared-pkg": "*"
			}
		}`,
		app1Dir + "/node_modules/shared-pkg": vfstest.Symlink(sharedDir),
		app1Dir + "/tsconfig.json": `{
			"compilerOptions": {
				"module": "nodenext",
				"moduleResolution": "nodenext",
				"strict": true,
				"noEmit": true
			}
		}`,
		app1Dir + "/index.ts": `export {};`,

		app2Dir + "/package.json": `{
			"name": "app2",
			"dependencies": {
				"shared-pkg": "*"
			}
		}`,
		app2Dir + "/node_modules/shared-pkg": vfstest.Symlink(sharedDir),
		app2Dir + "/tsconfig.json": `{
			"compilerOptions": {
				"module": "nodenext",
				"moduleResolution": "nodenext",
				"strict": true,
				"noEmit": true
			}
		}`,
		app2Dir + "/index.ts": `export {};`,
	}

	session, utils := projecttestutil.Setup(files)
	t.Cleanup(session.Close)

	ctx := context.Background()
	app1IndexURI := lsproto.DocumentUri("file://" + app1Dir + "/index.ts")
	app2IndexURI := lsproto.DocumentUri("file://" + app2Dir + "/index.ts")
	session.DidOpenFile(ctx, app1IndexURI, 1, "export {};", lsproto.LanguageKindTypeScript)
	session.DidOpenFile(ctx, app2IndexURI, 1, "export {};", lsproto.LanguageKindTypeScript)

	_, err := session.GetCurrentLanguageServiceWithAutoImports(ctx, app1IndexURI)
	assert.NilError(t, err)
	_, err = session.GetCurrentLanguageServiceWithAutoImports(ctx, app2IndexURI)
	assert.NilError(t, err)

	resolveApp1BrowserHelper := func() (tspath.ModuleSpecifier, modulespecifiers.ResultKind, bool) {
		snap := session.Snapshot()
		proj := snap.GetDefaultProject(app1IndexURI)
		prog := proj.GetProgram()
		file := prog.GetSourceFile(app1IndexURI.FileName())
		ch, done := prog.GetTypeChecker(ctx)
		defer done()
		view := autoimport.NewView(snap.AutoImportRegistry(), file, proj.ID(), prog, ch, modulespecifiers.UserPreferences{})
		matches := view.Search("browserOnlyHelper", autoimport.QueryKindExactMatch)
		if len(matches) == 0 {
			return "", modulespecifiers.ResultKindNone, false
		}
		spec, kind := view.GetModuleSpecifier(matches[0], modulespecifiers.UserPreferences{})
		return spec, kind, true
	}

	specBefore, kindBefore, okBefore := resolveApp1BrowserHelper()
	assert.Assert(t, okBefore)
	assert.Equal(t, specBefore, tspath.ModuleSpecifier(""))
	assert.Equal(t, kindBefore, modulespecifiers.ResultKindNone)

	// App2 removes shared-pkg while app1 remains untouched.
	assert.NilError(t, utils.FsFromFileMap().WriteFile(tspath.RootedFilePath(app2Dir+"/package.json"), `{"name":"app2","dependencies":{}}`))
	assert.NilError(t, utils.FsFromFileMap().Remove(tspath.RootedPath(app2Dir+"/node_modules/shared-pkg")))
	session.DidChangeWatchedFiles(ctx, []*lsproto.FileEvent{
		{Uri: lsproto.DocumentUri("file://" + app2Dir + "/package.json"), Type: lsproto.FileChangeTypeChanged},
		{Uri: lsproto.DocumentUri("file://" + app2Dir + "/node_modules/shared-pkg"), Type: lsproto.FileChangeTypeDeleted},
	})

	_, err = session.GetCurrentLanguageServiceWithAutoImports(ctx, app2IndexURI)
	assert.NilError(t, err)

	// Untouched app1 must retain its entrypoint metadata and keep rejecting the
	// browser-only export under nodenext conditions.
	specAfter, kindAfter, okAfter := resolveApp1BrowserHelper()
	assert.Assert(t, okAfter)
	assert.Equal(t, specAfter, tspath.ModuleSpecifier(""))
	assert.Equal(t, kindAfter, modulespecifiers.ResultKindNone)
}
