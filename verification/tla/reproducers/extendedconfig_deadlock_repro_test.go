package tsc_test

import (
	"sync"
	"testing"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/execute/tsc"
	"github.com/microsoft/TypeScript/tsc/internal/tsoptions"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs"
	"github.com/microsoft/TypeScript/tsc/internal/vfs/vfstest"
)

type barrierFS struct {
	vfs.FS
	mu      sync.Mutex
	seenA   bool
	seenB   bool
	release chan struct{}
}

func (b *barrierFS) ReadFile(path tspath.RootedFilePath) (string, bool) {
	p := path.AsString()
	if p == "/project/a.json" || p == "/project/b.json" {
		b.mu.Lock()
		if p == "/project/a.json" {
			b.seenA = true
		} else {
			b.seenB = true
		}
		if b.seenA && b.seenB {
			select {
			case <-b.release:
			default:
				close(b.release)
			}
		}
		b.mu.Unlock()
		<-b.release
	}
	return b.FS.ReadFile(path)
}

func TestReproExtendedConfigCacheABBADeadlock(t *testing.T) {
	// TLC trace (ExtendedConfigDeadlock, 3 states):
	// a.json extends b.json, b.json extends a.json.
	// Goroutine 1 parses tsconfig1.json (extends a.json) -> locks entry[a.json], reads a.json.
	// Goroutine 2 parses tsconfig2.json (extends b.json) -> locks entry[b.json], reads b.json.
	// Both pass single-goroutine resolutionStack check (!slices.Contains(stack, child)):
	// Goroutine 1 tries to lock entry[b.json]; Goroutine 2 tries to lock entry[a.json] -> AB-BA DEADLOCK!
	files := map[string]any{
		"/project/tsconfig1.json": `{"extends": "./a.json"}`,
		"/project/tsconfig2.json": `{"extends": "./b.json"}`,
		"/project/a.json":         `{"extends": "./b.json"}`,
		"/project/b.json":         `{"extends": "./a.json"}`,
		"/project/main.ts":        `export const x = 1;`,
	}

	bfs := &barrierFS{
		FS:      vfstest.FromMap(files, tspath.CaseInsensitive),
		release: make(chan struct{}),
	}
	cache := &tsc.ExtendedConfigCache{}

	done := make(chan struct{})
	go func() {
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			tsoptions.GetParsedCommandLineOfConfigFile("/project/tsconfig1.json", nil, nil, tsoptions.NewDefaultParseConfigHost(bfs), cache)
		}()
		go func() {
			defer wg.Done()
			tsoptions.GetParsedCommandLineOfConfigFile("/project/tsconfig2.json", nil, nil, tsoptions.NewDefaultParseConfigHost(bfs), cache)
		}()
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		// Completed without deadlock
	case <-time.After(300 * time.Millisecond):
		t.Fatalf("BUG REPRODUCED (ExtendedConfigDeadlock): permanent AB-BA deadlock between two concurrent GetExtendedConfig calls on cyclic a.json <-> b.json")
	}
}
