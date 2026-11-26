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

func TestFilesParserElideOnDepthDoesNotDropTransitiveImports(t *testing.T) {
	t.Parallel()

	// /node_modules/pkg/entry.js is reached at depth 1 by two edges:
	//   - /src/a.ts: `import "pkg/entry"` -> depth 1, elideOnDepth = true (JS from node_modules)
	//   - /src/b.ts -> /node_modules/pkg/types.d.ts -> `/// <reference path="./entry.js" />`
	//     -> depth 1, elideOnDepth = false
	// Swapping rootFiles order must not cause /node_modules/pkg/dep.d.ts to disappear.
	files := map[string]any{
		"/src/a.ts":                    `import "pkg/entry";`,
		"/src/b.ts":                    `import "pkg/types";`,
		"/node_modules/pkg/types.d.ts": `/// <reference path="./entry.js" />`,
		"/node_modules/pkg/entry.js":   `/// <reference path="./dep.d.ts" />` + "\nexport const entry = 1;",
		"/node_modules/pkg/dep.d.ts":   `export declare const dep: number;`,
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

	for _, order := range [][]tspath.RootedFilePath{
		{"/src/a.ts", "/src/b.ts"},
		{"/src/b.ts", "/src/a.ts"},
	} {
		prog := buildProgram(order)
		assert.Assert(t, prog.GetSourceFile("/node_modules/pkg/entry.js") != nil, "entry.js should be loaded for order %v", order)
		assert.Assert(t, prog.GetSourceFile("/node_modules/pkg/dep.d.ts") != nil, "dep.d.ts should be loaded for order %v", order)
	}
}

func TestFilesParserElideOnDepthDoesNotPoisonDepthRestart(t *testing.T) {
	t.Parallel()

	// With MaxNodeModuleJsDepth = 1:
	//   1. Non-elided arrival at depth 3 loads entry.js and starts dep.d.ts at depth 3.
	//   2. Elided arrival at depth 2 (> maxDepth) must not lower data.lowestDepth without restarting subtasks.
	//   3. Non-elided arrival at depth 2 must lower entry.js to depth 2 and restart dep.d.ts at depth 2.
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
			wg:       core.NewWorkGroup(1),
			maxDepth: maxDepth,
		},
		supportedExtensions:                            supportedExtensions,
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

	loader.filesParser.start(context.Background(), loader, []*parseTask{{
		normalizedFilePath: entryName,
		path:               entryPath,
		elideOnDepth:       false,
	}}, 3)
	loader.filesParser.wg.RunAndWait()

	loader.filesParser.wg = core.NewWorkGroup(1)
	loader.filesParser.start(context.Background(), loader, []*parseTask{{
		normalizedFilePath: entryName,
		path:               entryPath,
		elideOnDepth:       true,
	}}, 2)
	loader.filesParser.wg.RunAndWait()

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

	assert.Equal(t, entryData.lowestDepth, 2)
	assert.Equal(t, depData.lowestDepth, 2)
}
