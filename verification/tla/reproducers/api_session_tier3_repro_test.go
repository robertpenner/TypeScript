package api

import (
	"context"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/json"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/projecttestutil"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"gotest.tools/v3/assert"
)

func TestReproApiSessionLspSnapshotAfterCloseLeaksRefs(t *testing.T) {
	// TLC trace (ApiSessionLifecycle / NoPostCloseLspRefLeak):
	// 1. Session.Close() runs inside s.closeOnce.Do(...), calls releaseLanguageServerRefs()
	//    under s.languageServerUpdateMu, and unlocks — with no closed flag.
	// 2. A concurrent handleGetCurrentLanguageServerSnapshot acquires s.languageServerUpdateMu
	//    after Close() unlocked, calls s.projectSession.APIUpdate(...) to open a configured
	//    project on the live shared LSP project.Session, and commits s.openProjects.
	// 3. Because s.closeOnce already fired, releaseLanguageServerRefs() will never run again:
	//    the opened project leaks permanently into both s.openProjects and projectSession.
	projectSession, _ := projecttestutil.Setup(map[string]any{
		"/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/index.ts":      "export const x: number = 1;",
	})
	defer projectSession.Close()

	session := NewLSPSession(projectSession, nil)
	session.Close()

	// Simulates the concurrent IPC handler acquiring s.languageServerUpdateMu right after Close().
	_, err := session.handleGetCurrentLanguageServerSnapshot(context.Background(), &GetCurrentLanguageServerSnapshotParams{
		Changes: &LanguageServerSnapshotChanges{
			SnapshotRequestChangesParams: SnapshotRequestChangesParams{
				OpenProjects: []DocumentIdentifier{{FileName: "/tsconfig.json"}},
			},
		},
	})
	assert.NilError(t, err)

	session.languageServerUpdateMu.Lock()
	leakedLocalProjects := session.openProjects.Len()
	session.languageServerUpdateMu.Unlock()

	snap := projectSession.Snapshot()
	leakedProject := snap.ProjectCollection.ConfiguredProject(tspath.PathKey("/tsconfig.json"))

	// Calling Close() again is a no-op because of s.closeOnce.
	session.Close()

	if leakedLocalProjects > 0 || leakedProject != nil {
		t.Fatalf("BUG REPRODUCED (NoPostCloseLspRefLeak): handleGetCurrentLanguageServerSnapshot after Session.Close() leaked %d local openProjects and left configured project %v pinned in live project.Session", leakedLocalProjects, leakedProject != nil)
	}
}

func TestReproApiSessionSourceFileLeaseAfterCloseLeak(t *testing.T) {
	// TLC trace (ApiSessionLifecycle / NoPostCloseLeaseLeak):
	// 1. Session.Close() runs releaseSourceFileLeases() under s.sourceFileLeasesMu with no closed flag.
	// 2. A concurrent handleCreateSourceFile completes after Close() unlocked and calls
	//    registerSourceFileLease(lease), storing a live lease in s.sourceFileLeases and pinning
	//    the *ast.SourceFile refcount in the shared parseCache forever.
	projectSession, _ := projecttestutil.Setup(map[string]any{
		"/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/index.ts":      "export const x: number = 1;",
	})
	defer projectSession.Close()

	session := NewLSPSession(projectSession, nil)
	session.Close()

	_, err := session.handleCreateSourceFile(context.Background(), &CreateSourceFileParams{
		FileName:   "/temp.ts",
		SourceText: "export const a = 1;",
	})
	assert.NilError(t, err)

	session.sourceFileLeasesMu.Lock()
	leakedLeases := len(session.sourceFileLeases)
	for id, lease := range session.sourceFileLeases {
		lease.Release()
		delete(session.sourceFileLeases, id)
	}
	session.sourceFileLeasesMu.Unlock()

	if leakedLeases > 0 {
		t.Fatalf("BUG REPRODUCED (NoPostCloseLeaseLeak): handleCreateSourceFile -> registerSourceFileLease inserted %d lease(s) into s.sourceFileLeases AFTER Session.Close() completed", leakedLeases)
	}
}

func TestReproApiSessionBatchResponsePagesAfterCloseLeak(t *testing.T) {
	// TLC trace (ApiSessionLifecycle / NoPostCloseBatchPageLeak):
	// 1. Session.Close() clears s.batchResponsePages with no closed flag.
	// 2. A concurrent handleBatchRequests -> paginateBatchResponses stores a continuation
	//    page into s.batchResponsePages after Close() completed, leaking the page forever.
	projectSession, _ := projecttestutil.Setup(map[string]any{
		"/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/index.ts":      "export const x: number = 1;",
	})
	defer projectSession.Close()

	session := NewLSPSession(projectSession, nil)
	session.Close()

	page := batchResponsePage{
		encodedResponses: []json.Value{
			json.Value(`{"method":"echo","result":"aaaaaaaaaaaaaaaaaaaa"}`),
			json.Value(`{"method":"echo","result":"bbbbbbbbbbbbbbbbbbbb"}`),
		},
	}
	resp, err := session.paginateBatchResponses(page, nil, 70)
	assert.NilError(t, err)

	leakedPages := 0
	session.batchResponsePages.Range(func(_, _ any) bool {
		leakedPages++
		return true
	})

	if leakedPages > 0 {
		t.Fatalf("BUG REPRODUCED (NoPostCloseBatchPageLeak): paginateBatchResponses stored %d continuation page(s) (token=%q) into s.batchResponsePages AFTER Session.Close() completed", leakedPages, resp.ContinuationToken)
	}
}
