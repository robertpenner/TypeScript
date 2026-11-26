package autoimport_test

import (
	"context"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/ls"
	"github.com/microsoft/TypeScript/tsc/internal/ls/autoimport"
	"github.com/microsoft/TypeScript/tsc/internal/ls/lsutil"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/modulespecifiers"
	"github.com/microsoft/TypeScript/tsc/internal/project"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/projecttestutil"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
)

// cancelAfterBuildProjectBucketEntryCtx wraps a Context so that the very first
// ctx.Err() call inside buildProjectBucket (registry.go:1247, the entry guard)
// sees nil and immediately triggers cancellation, so every subsequent ctx.Err()
// check inside the worker loop (registry.go:1280) sees context.Canceled.
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

// TestReproAutoImportBuildProjectBucketCancelCommitsTruncatedCleanBucket
// reproduces Defect 4.2a (AutoImportRegistry.tla / AutoImportRegistry_CancelCleanCommit.cfg,
// registry.go:1240-1315 & session.go:1311-1351).
//
// buildProjectBucket checks ctx.Err() at entry (line 1247) and guards each
// worker with `if ctx.Err() == nil` (line 1280), but omits `result.err = ctx.Err()`
// after wg.Wait() (contrast buildNodeModulesBucket:1712 and updateNodeModulesBucket:1832).
// Worse, Session.GetLanguageServiceWithAutoImports (session.go:1320) enqueues
// adoptSnapshotChange without checking ctx.Err(). A cancelled LSP request thus
// permanently commits a 0-export CLEAN project bucket into Session.snapshot.
func TestReproAutoImportBuildProjectBucketCancelCommitsTruncatedCleanBucket(t *testing.T) {
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

	// Drive the exact lsp/server.go:1446-1457 request sequence:
	// WithLanguageServiceAndSnapshot -> GetLanguageServiceWithAutoImports(reqCtx, snapshot, uri).
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
	if err != nil {
		t.Fatalf("WithLanguageServiceAndSnapshot setup failed: %v", err)
	}
	if err := asyncWork(); err != nil {
		t.Fatalf("GetLanguageServiceWithAutoImports returned unexpected error: %v", err)
	}
	if reqCtx.Err() == nil {
		t.Fatalf("test setup error: reqCtx was not cancelled inside buildProjectBucket")
	}

	// Wait for tryAdoptSnapshotChangeInBackground to finish running adoptSnapshotChange.
	session.WaitForBackgroundTasks()

	// Now simulate a subsequent fresh, non-cancelled request: inspect Session.snapshot!
	snap := session.Snapshot()
	reg := snap.AutoImportRegistry()
	if reg == nil {
		t.Fatalf("expected non-nil AutoImportRegistry")
	}
	stats := reg.GetCacheStats()
	if len(stats.ProjectBuckets) != 1 {
		t.Fatalf("expected 1 project bucket, got %d", len(stats.ProjectBuckets))
	}
	pb := stats.ProjectBuckets[0]
	proj := snap.GetDefaultProject(indexURI)
	prepared := reg.IsPreparedForImportingFile(indexURI.FileName(), proj.ID(), lsutil.NewDefaultUserPreferences())

	// Even a subsequent non-cancelled GetCurrentLanguageServiceWithAutoImports will NOT
	// rebuild because the truncated project bucket is already marked clean!
	_, err = session.GetCurrentLanguageServiceWithAutoImports(context.Background(), indexURI)
	if err != nil {
		t.Fatalf("subsequent GetCurrentLanguageServiceWithAutoImports failed: %v", err)
	}
	statsAfter := session.Snapshot().AutoImportRegistry().GetCacheStats()
	pbAfter := statsAfter.ProjectBuckets[0]

	if !pb.State.Dirty() && prepared && pb.ExportCount == 0 && pbAfter.ExportCount == 0 {
		t.Fatalf("BUG REPRODUCED: cancelled buildProjectBucket committed truncated CLEAN bucket (dirty=%v, prepared=%v, files=%d, exports=%d) into Session.snapshot; subsequent non-cancelled request stayed empty (exports=%d, expected >=2)",
			pb.State.Dirty(), prepared, pb.FileCount, pb.ExportCount, pbAfter.ExportCount)
	}
}

// TestReproAutoImportSharedEntrypointsCrossBucketClobber reproduces Defect 4.2b
// (AutoImportRegistry.tla / AutoImportRegistry_EntrypointClobber.cfg,
// registry.go:1066-1075, 1692-1701; specifiers.go:38-57).
//
// Registry.entrypoints is a single registry-wide map keyed only by ResolvedPath,
// shared across all node_modules buckets. When two sibling apps (app1 and app2)
// each have their own node_modules symlinking to the same workspace package
// (/monorepo/packages/shared-pkg) with conditional package "exports" (e.g. a
// "browser"-only entrypoint), removing shared-pkg from app2 rebuilds app2's
// node_modules bucket and unconditionally deletes the shared ResolvedPath from
// Registry.entrypoints — even though app1's node_modules bucket is untouched
// and still owns that package. App1's View.GetModuleSpecifier then misses
// v.registry.entrypoints[export.Path] (specifiers.go:38), bypasses the
// condition-mismatch rejection at specifiers.go:55, and falls through to
// GetModuleSpecifiersForFileWithInfo, leaking an illegal relative path into
// packages/shared-pkg/dist/!
func TestReproAutoImportSharedEntrypointsCrossBucketClobber(t *testing.T) {
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

		// App1 depends on shared-pkg via app1/node_modules (bucket B1).
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

		// App2 also depends on shared-pkg via app2/node_modules (bucket B2).
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

	// Step 1: Build both app1/node_modules (B1) and app2/node_modules (B2).
	if _, err := session.GetCurrentLanguageServiceWithAutoImports(ctx, app1IndexURI); err != nil {
		t.Fatalf("initial app1 auto-imports build failed: %v", err)
	}
	if _, err := session.GetCurrentLanguageServiceWithAutoImports(ctx, app2IndexURI); err != nil {
		t.Fatalf("initial app2 auto-imports build failed: %v", err)
	}

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

	// Verify baseline: app1 is a NodeNext project (conditions do not include "browser"),
	// so Registry.entrypoints rejects browserOnlyHelper with ("", ResultKindNone).
	specBefore, kindBefore, okBefore := resolveApp1BrowserHelper()
	if !okBefore || specBefore != "" || kindBefore != modulespecifiers.ResultKindNone {
		t.Fatalf("baseline setup failed: expected browserOnlyHelper indexed and rejected by exports condition, got ok=%v spec=%q kind=%v", okBefore, specBefore, kindBefore)
	}

	// Step 2: App2 drops shared-pkg from app2/package.json and app2/node_modules,
	// while app1/package.json and app1/node_modules/shared-pkg are completely untouched!
	if err := utils.FsFromFileMap().WriteFile(tspath.RootedFilePath(app2Dir+"/package.json"), `{"name":"app2","dependencies":{}}`); err != nil {
		t.Fatalf("write app2 package.json: %v", err)
	}
	if err := utils.FsFromFileMap().Remove(tspath.RootedPath(app2Dir + "/node_modules/shared-pkg")); err != nil {
		t.Fatalf("remove app2 symlink: %v", err)
	}
	session.DidChangeWatchedFiles(ctx, []*lsproto.FileEvent{
		{Uri: lsproto.DocumentUri("file://" + app2Dir + "/package.json"), Type: lsproto.FileChangeTypeChanged},
		{Uri: lsproto.DocumentUri("file://" + app2Dir + "/node_modules/shared-pkg"), Type: lsproto.FileChangeTypeDeleted},
	})

	// Step 3: Trigger auto-imports refresh for app2 — only app2/node_modules (B2) rebuilds,
	// adding sharedDir/dist/browser.d.ts to removedEntrypointPaths and unconditionally
	// deleting it from Registry.entrypoints!
	if _, err := session.GetCurrentLanguageServiceWithAutoImports(ctx, app2IndexURI); err != nil {
		t.Fatalf("post-change app2 auto-imports build failed: %v", err)
	}

	// Step 4: Query app1 again — untouched app1/node_modules still has browserOnlyHelper,
	// but Registry.entrypoints[sharedDir/dist/browser.d.ts] was deleted by app2's rebuild!
	specAfter, kindAfter, okAfter := resolveApp1BrowserHelper()
	if !okAfter {
		t.Fatalf("expected browserOnlyHelper export to remain indexed in untouched app1/node_modules bucket")
	}
	if specAfter != "" || kindAfter != modulespecifiers.ResultKindNone {
		t.Fatalf("BUG REPRODUCED: rebuilding app2/node_modules deleted shared Registry.entrypoints owned by untouched app1/node_modules; app1 bypassed exports condition check and emitted %q (kind=%v, expected \"\" / ResultKindNone)",
			specAfter, kindAfter)
	}
}

