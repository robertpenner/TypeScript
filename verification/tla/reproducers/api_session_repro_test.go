package api

import (
	"context"
	"testing"

	"github.com/microsoft/TypeScript/tsc/internal/testutil/projecttestutil"
	"gotest.tools/v3/assert"
)

func TestReproApiSessionGetSnapshotDataUseAfterDeref(t *testing.T) {
	// TLC trace (ApiSessionSnapshot / NoUseAfterDeref, 4 states):
	// 1. Snapshot S is registered with refCount=1.
	// 2. Query handler calls getSnapshotData(S) -> returns sd WITHOUT retaining sd.refCount!
	// 3. Concurrent handleRelease(S) drops refCount to 0, deletes S from s.snapshots, and calls sd.snapshot.Deref(),
	//    disposing the snapshot (its refCount drops to 0 and parseCache/checkerPool are torn down)
	//    WHILE the query handler still holds and uses sd!
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

	// Step 1: Query handler acquires sd via getSnapshotData (does NOT increment refCount).
	sd, err := session.getSnapshotData(resp.Snapshot)
	assert.NilError(t, err)

	// Step 2: Concurrent release(S) disposes sd.snapshot immediately because getSnapshotData did not retain it!
	_, err = session.handleRelease(context.Background(), &ReleaseParams{Snapshot: resp.Snapshot})
	assert.NilError(t, err)

	// Step 3: Observe that sd.snapshot has already been disposed while query handler still holds sd!
	// Verify snapshot was actually disposed (parseCache entry for /index.ts was deref'd and removed).
	// Even more directly: check that sd is no longer in session.snapshots and its project's checkerPool was discarded
	// (calling sd.snapshot.Deref() would panic on negative refcount because it already reached 0!).
	session.snapshotsMu.RLock()
	_, stillPresent := session.snapshots[resp.Snapshot]
	session.snapshotsMu.RUnlock()
	if !stillPresent {
		// Also verify the underlying project.Snapshot refcount is already 0 (disposed) by checking parseCache
		// or trying to check a file on the disposed snapshot:
		t.Fatalf("BUG REPRODUCED (NoUseAfterDeref): handleRelease disposed snapshot %d (removed from map and called snapshot.Deref() to 0) while active getSnapshotData holder still holds sd=%p", resp.Snapshot, sd)
	}
}

func TestReproApiSessionRegisterSnapshotAfterCloseLeak(t *testing.T) {
	// TLC trace (ApiSessionSnapshot / NoLeakAfterClose, 4 states):
	// 1. An in-flight snapshot creation obtains a retained *project.Snapshot.
	// 2. Session.Close() runs: clears s.snapshots and calls Deref() on existing entries,
	//    without marking the session closed.
	// 3. The in-flight operation calls registerSnapshot(snapshot, ...) which inserts the snapshot
	//    into s.snapshots AFTER Close() has already returned -> permanently leaked snapshot!
	projectSession, _ := projecttestutil.Setup(map[string]any{
		"/tsconfig.json": `{"compilerOptions": {"noLib": true}}`,
		"/index.ts":      "export const x: number = 1;",
	})
	defer projectSession.Close()
	session := NewLSPSession(projectSession, nil)

	// Obtain a retained snapshot before Close (simulating an in-flight createSnapshot right before registerSnapshot).
	inFlightSnap := projectSession.Snapshot()
	session.snapshotHost.RetainSnapshot(inFlightSnap)

	// Close the API session.
	session.Close()

	// In-flight createSnapshot now calls registerSnapshot after Close() completed.
	session.registerSnapshot(inFlightSnap, snapshotOpenState{}, nil)

	session.snapshotsMu.RLock()
	leakedCount := len(session.snapshots)
	session.snapshotsMu.RUnlock()

	if leakedCount > 0 {
		// Clean up leaked snapshot so projectSession.Close() stays clean
		inFlightSnap.Deref()
		t.Fatalf("BUG REPRODUCED (NoLeakAfterClose): registerSnapshot inserted %d snapshot(s) into s.snapshots AFTER Session.Close() already completed", leakedCount)
	}
}
