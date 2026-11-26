package compiler

import (
	"context"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/module"
	"github.com/microsoft/TypeScript/tsc/internal/tsoptions"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
	"gotest.tools/v3/assert"
)

func TestReproCompilerFilesParserElideOnDepthDropsTransitiveImports(t *testing.T) {
	// TLC trace (CompilerFilesParserDepth / LoadedFileStartsSubtasks):
	// /node_modules/pkg/entry.js is reached at depth 1 by two edges:
	//   - /src/a.ts: `import "pkg/entry"` -> depth 1, elideOnDepth = true (JS from node_modules)
	//   - /src/b.ts -> /node_modules/pkg/types.d.ts -> `/// <reference path="./entry.js" />`
	//     -> depth 1, elideOnDepth = false
	// /node_modules/pkg/entry.js references `./dep.d.ts` (`/// <reference path="./dep.d.ts" />`).
	//
	// Because filesParser.start() mutates data.lowestDepth = 1 and data.startedSubTasks = true
	// BEFORE checking `if task.elideOnDepth && currentDepth > w.maxDepth { return }`,
	// when the elided task from a.ts runs before the non-elided task from b.ts/types.d.ts:
	//   - task 1 poisons data.lowestDepth = 1 and returns without loading entry.js.
	//   - task 2 sees lowered = (1 < 1) = false, loads entry.js (so entry.js IS in the Program),
	//     and skips w.start(..., subTasks, ...) — silently dropping /node_modules/pkg/dep.d.ts!
	files := map[string]any{
		"/src/a.ts":                  `import "pkg/entry";`,
		"/src/b.ts":                  `import "pkg/types";`,
		"/node_modules/pkg/types.d.ts": `/// <reference path="./entry.js" />`,
		"/node_modules/pkg/entry.js": `/// <reference path="./dep.d.ts" />` + "\nexport const entry = 1;",
		"/node_modules/pkg/dep.d.ts": `export declare const dep: number;`,
	}

	buildProgram := func(rootFiles []tspath.RootedFilePath) *Program {
		fs := vfstest.FromMap(files, tspath.CaseSensitive)
		opts := &core.CompilerOptions{
			NoLib:   core.TSTrue,
			AllowJs: core.TSTrue,
		}
		config := tsoptions.NewParsedCommandLine(opts, rootFiles, nil, "/src", tspath.CaseSensitive)
		host := NewCompilerHost(fs, "/", nil, nil, nil)
		prog, err := NewProgram(context.Background(), ProgramOptions{
			Config:         config,
			SingleThreaded: core.TSTrue,
			Host:           host,
		})
		assert.NilError(t, err)
		return prog
	}

	// Order 1 (["/src/a.ts", "/src/b.ts"]): singleThreadedWorkGroup runs LIFO, so b.ts runs first
	// -> types.d.ts -> entry.js (depth 1, non-elided) -> both entry.js and dep.d.ts are loaded.
	progGood := buildProgram([]tspath.RootedFilePath{"/src/a.ts", "/src/b.ts"})
	assert.Assert(t, progGood.GetSourceFile("/node_modules/pkg/entry.js") != nil, "entry.js should be loaded in good order")
	assert.Assert(t, progGood.GetSourceFile("/node_modules/pkg/dep.d.ts") != nil, "dep.d.ts should be loaded in good order")

	// Order 2 (["/src/b.ts", "/src/a.ts"]): singleThreadedWorkGroup runs LIFO, so a.ts runs first
	// -> elided JS import to entry.js at depth 1 poisons data.lowestDepth = 1 and returns early.
	// When b.ts -> types.d.ts -> entry.js (depth 1, non-elided) runs next, entry.js IS loaded
	// into the Program, but its transitive reference /node_modules/pkg/dep.d.ts is silently dropped!
	progBuggy := buildProgram([]tspath.RootedFilePath{"/src/b.ts", "/src/a.ts"})
	entryLoaded := progBuggy.GetSourceFile("/node_modules/pkg/entry.js") != nil
	depLoaded := progBuggy.GetSourceFile("/node_modules/pkg/dep.d.ts") != nil
	if entryLoaded && !depLoaded {
		t.Fatalf("BUG REPRODUCED (LoadedFileStartsSubtasks): swapping rootFiles order caused /node_modules/pkg/dep.d.ts to disappear from Program even though /node_modules/pkg/entry.js was loaded")
	}
}

func TestReproCompilerFilesParserElideOnDepthPoisonsDepthRestart(t *testing.T) {
	// TLC trace (CompilerFilesParserDepth / LowestNonElidedDepthReached):
	// With MaxNodeModuleJsDepth = 1:
	//   - Task 1 (deep, depth 3, elideOnDepth = false): loads /node_modules/pkg/entry.js at depth 3
	//     and starts its subtask /node_modules/pkg/dep.d.ts at depth 3.
	//   - Task 2 (elided, depth 2 > maxDepth 1, elideOnDepth = true): lowers data.lowestDepth
	//     from 3 to 2 and returns early WITHOUT restarting subtasks!
	//   - Task 3 (shallow, depth 2, elideOnDepth = false): sees lowered = (2 < 2) = false and
	//     never restarts subtasks at depth 2 — leaving dep.d.ts stuck at lowestDepth = 3 instead of 2!
	fs := vfstest.FromMap(map[string]any{
		"/node_modules/pkg/entry.js": `/// <reference path="./dep.d.ts" />` + "\nexport const entry = 1;",
		"/node_modules/pkg/dep.d.ts": `export declare const dep: number;`,
	}, tspath.CaseSensitive)
	maxDepth := 1
	opts := &core.CompilerOptions{
		NoLib:                core.TSTrue,
		AllowJs:              core.TSTrue,
		MaxNodeModuleJsDepth: &maxDepth,
	}
	config := tsoptions.NewParsedCommandLine(opts, nil, nil, "/src", tspath.CaseSensitive)
	host := NewCompilerHost(fs, "/", nil, nil, nil)
	supportedExtensions := tsoptions.GetSupportedExtensions(opts, config.ContentMapperExtensions())
	loader := &fileLoader{
		opts:               ProgramConfig{Config: config},
		host:               host,
		defaultLibraryPath: host.DefaultLibraryPath(),
		caseSensitivity:    fs.CaseSensitivity(),
		filesParser: &filesParser{
			wg:       core.NewWorkGroup(1), // single-threaded deterministic execution order
			maxDepth: maxDepth,
		},
		supportedExtensions: supportedExtensions,
		supportedExtensionsWithJsonIfResolveJsonModule: tsoptions.GetSupportedExtensionsWithJsonIfResolveJsonModule(opts, supportedExtensions),
	}
	loader.addProjectReferenceTasks(context.Background(), true)
	loader.resolver = module.NewResolver(module.ResolverOptions{
		Host:            loader.projectReferences.host,
		CompilerOptions: opts,
	})

	entryName := tspath.RootedFilePathFromNormalized("/node_modules/pkg/entry.js")
	entryPath := tspath.PathKey("/node_modules/pkg/entry.js")
	depPath := tspath.PathKey("/node_modules/pkg/dep.d.ts")

	// Step 1: non-elided arrival at depth 3 loads entry.js and starts dep.d.ts at depth 3.
	loader.filesParser.start(context.Background(), loader, []*parseTask{{
		normalizedFilePath: entryName,
		path:               entryPath,
		elideOnDepth:       false,
	}}, 3)
	loader.filesParser.wg.RunAndWait()

	// Step 2: elided JS arrival at depth 2 (> maxDepth=1) poisons entry.js's data.lowestDepth to 2 and returns early.
	loader.filesParser.wg = core.NewWorkGroup(1)
	loader.filesParser.start(context.Background(), loader, []*parseTask{{
		normalizedFilePath: entryName,
		path:               entryPath,
		elideOnDepth:       true,
	}}, 2)
	loader.filesParser.wg.RunAndWait()

	// Step 3: non-elided arrival at depth 2 should restart dep.d.ts at depth 2, but sees lowered=(2<2)=false!
	loader.filesParser.wg = core.NewWorkGroup(1)
	loader.filesParser.start(context.Background(), loader, []*parseTask{{
		normalizedFilePath: entryName,
		path:               entryPath,
		elideOnDepth:       false,
	}}, 2)
	loader.filesParser.wg.RunAndWait()

	entryData, ok := loader.filesParser.taskDataByPath.Load(entryPath)
	assert.Assert(t, ok)
	depData, ok := loader.filesParser.taskDataByPath.Load(depPath)
	assert.Assert(t, ok)

	if entryData.lowestDepth == 2 && depData.lowestDepth == 3 {
		t.Fatalf("BUG REPRODUCED (LowestNonElidedDepthReached): elided arrival at depth 2 poisoned entry.js lowestDepth=%d without restarting subtasks, preventing subsequent non-elided depth-2 arrival from lowering dep.d.ts (stuck at lowestDepth=%d)", entryData.lowestDepth, depData.lowestDepth)
	}
}
