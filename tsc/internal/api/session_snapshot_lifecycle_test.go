package api

import (
	"context"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/testutil/projecttestutil"
	"gotest.tools/v3/assert"
)

func TestGetSnapshotDataRetainsAcrossRelease(t *testing.T) {
	t.Parallel()

	projectSession, _ := projecttestutil.Setup(map[string]any{
		"/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/index.ts":      "export const x: number = 1;",
	})
	defer projectSession.Close()
	session := NewLSPSession(projectSession, nil)
	defer session.Close()

	resp, err := session.handleCreateSnapshot(context.Background(), &CreateSnapshotParams{
		OpenProjects: []DocumentIdentifier{{FileName: "/tsconfig.json"}},
	})
	assert.NilError(t, err)

	// Acquire snapshot data for an in-flight read handler.
	sd, release, err := session.getSnapshotData(resp.Snapshot)
	assert.NilError(t, err)

	// Concurrent client release removes the handle from s.snapshots,
	// while the in-flight handler's pin keeps sd.snapshot alive.
	_, err = session.handleRelease(context.Background(), &ReleaseParams{Snapshot: resp.Snapshot})
	assert.NilError(t, err)

	// A duplicate client release must fail with not-found rather than double-decrementing.
	_, err = session.handleRelease(context.Background(), &ReleaseParams{Snapshot: resp.Snapshot})
	assert.ErrorContains(t, err, "not found")

	// While pinned, sd.snapshot remains usable (e.g. retrieving the project/program).
	proj, err := sd.getProject(resp.Projects[0].Handle)
	assert.NilError(t, err)
	assert.Assert(t, proj.GetProgram() != nil)

	// Releasing the handler pin disposes the snapshot cleanly (idempotent sync.OnceFunc).
	release()
	release()
}

func TestGetSnapshotDataRetainsAcrossSessionClose(t *testing.T) {
	t.Parallel()

	projectSession, _ := projecttestutil.Setup(map[string]any{
		"/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/index.ts":      "export const x: number = 1;",
	})
	defer projectSession.Close()
	session := NewLSPSession(projectSession, nil)

	resp, err := session.handleCreateSnapshot(context.Background(), &CreateSnapshotParams{
		OpenProjects: []DocumentIdentifier{{FileName: "/tsconfig.json"}},
	})
	assert.NilError(t, err)

	sd, release, err := session.getSnapshotData(resp.Snapshot)
	assert.NilError(t, err)

	// Close the API session while the query pin is still active.
	session.Close()

	// Snapshot stays alive until the in-flight handler calls release().
	proj, err := sd.getProject(resp.Projects[0].Handle)
	assert.NilError(t, err)
	assert.Assert(t, proj.GetProgram() != nil)

	release()
}

func TestRegisterSnapshotAfterCloseRejectsAndDerefs(t *testing.T) {
	t.Parallel()

	projectSession, _ := projecttestutil.Setup(map[string]any{
		"/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/index.ts":      "export const x: number = 1;",
	})
	defer projectSession.Close()
	session := NewLSPSession(projectSession, nil)

	inFlightSnap := projectSession.Snapshot()
	session.snapshotHost.RetainSnapshot(inFlightSnap)

	session.Close()

	err := session.registerSnapshot(inFlightSnap, snapshotOpenState{}, nil)
	assert.ErrorContains(t, err, "session is closed")

	session.snapshotsMu.RLock()
	leakedCount := len(session.snapshots)
	session.snapshotsMu.RUnlock()
	assert.Equal(t, leakedCount, 0, "closed session must not retain newly registered snapshots")
}
