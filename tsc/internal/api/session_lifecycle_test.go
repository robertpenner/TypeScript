package api

import (
	"context"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/json"
	"github.com/microsoft/TypeScript/tsc/internal/testutil/projecttestutil"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"gotest.tools/v3/assert"
)

func TestSessionCloseRejectsPostCloseLspSnapshotUpdate(t *testing.T) {
	t.Parallel()

	projectSession, _ := projecttestutil.Setup(map[string]any{
		"/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/index.ts":      "export const x: number = 1;",
	})
	defer projectSession.Close()

	session := NewLSPSession(projectSession, nil)
	session.Close()

	_, err := session.handleGetCurrentLanguageServerSnapshot(context.Background(), &GetCurrentLanguageServerSnapshotParams{
		Changes: &LanguageServerSnapshotChanges{
			SnapshotRequestChangesParams: SnapshotRequestChangesParams{
				OpenProjects: []DocumentIdentifier{{FileName: "/tsconfig.json"}},
			},
		},
	})
	assert.ErrorContains(t, err, "session is closed")

	session.languageServerUpdateMu.Lock()
	leakedLocalProjects := session.openProjects.Len()
	session.languageServerUpdateMu.Unlock()
	assert.Equal(t, leakedLocalProjects, 0)

	snap := projectSession.Snapshot()
	assert.Assert(t, snap.ProjectCollection.ConfiguredProject(tspath.PathKey("/tsconfig.json")) == nil)
}

func TestSessionCloseRejectsPostCloseSourceFileLease(t *testing.T) {
	t.Parallel()

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
	assert.ErrorContains(t, err, "session is closed")

	session.sourceFileLeasesMu.Lock()
	leakedLeases := len(session.sourceFileLeases)
	session.sourceFileLeasesMu.Unlock()
	assert.Equal(t, leakedLeases, 0)
}

func TestSessionCloseRejectsPostCloseBatchResponsePage(t *testing.T) {
	t.Parallel()

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
	_, err := session.paginateBatchResponses(page, nil, 70)
	assert.ErrorContains(t, err, "session is closed")

	session.batchResponsePagesMu.Lock()
	leakedPages := len(session.batchResponsePages)
	session.batchResponsePagesMu.Unlock()
	assert.Equal(t, leakedPages, 0)
}

func TestSessionCloseStopsActiveCPUProfiler(t *testing.T) {
	// Not parallel because runtime/pprof CPU profiling is process-global.
	projectSession, _ := projecttestutil.Setup(map[string]any{
		"/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/index.ts":      "export const x: number = 1;",
	})
	defer projectSession.Close()

	profileDir := t.TempDir()

	session1 := NewLSPSession(projectSession, nil)
	_, err := session1.handleStartCPUProfile(context.Background(), &ProfileParams{Dir: profileDir})
	assert.NilError(t, err)

	// Closing session1 must stop the active CPU profile so later sessions can profile.
	session1.Close()

	// Starting profiling on a closed session must also be rejected.
	_, err = session1.handleStartCPUProfile(context.Background(), &ProfileParams{Dir: profileDir})
	assert.ErrorContains(t, err, "session is closed")

	session2 := NewLSPSession(projectSession, nil)
	defer session2.Close()

	_, err = session2.handleStartCPUProfile(context.Background(), &ProfileParams{Dir: profileDir})
	assert.NilError(t, err)

	_, err = session2.handleStopCPUProfile(context.Background())
	assert.NilError(t, err)
}
