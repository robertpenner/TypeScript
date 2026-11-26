---------------------- MODULE SessionInferredOptions ----------------------
(*
 * Models tsc/internal/project/session.go:321-342 (DidOpenFile),
 * 500-506 (DidChangeCompilerOptionsForInferredProjects),
 * 1393-1425 (updateSnapshot), and 1725-1734 (Close).
 *
 * Every other caller of UpdateSnapshot acquires s.snapshotUpdateMu first.
 * DidChangeCompilerOptionsForInferredProjects does not: it writes
 * s.compilerOptionsForInferredProjects unsynchronized, reads s.fs.Overlays(),
 * and calls s.UpdateSnapshot(ctx, overlays, ...) without s.snapshotUpdateMu.
 *
 * Two safety failures:
 *  1. EnableClose = FALSE (InvNoLostOverlay): DidChange reads fsOverlays={},
 *     DidOpenFile adds "a.ts" to fsOverlays and commits S1 with {"a.ts"}, then
 *     DidChange runs UpdateSnapshot with stale overlays={}, committing S2 and
 *     dropping open file "a.ts" from the active snapshot.
 *  2. EnableClose = TRUE (InvNoNilSnapshotClone): Close acquires
 *     snapshotUpdateMu and snapshotMu, sets s.snapshot = nil, and releases
 *     both locks. Concurrent DidChange enters updateSnapshot, locks
 *     snapshotMu, reads oldSnapshot = nil, and panics on oldSnapshot.Clone.
 *)
EXTENDS FiniteSets

CONSTANT EnableClose

VARIABLES
    updateMu,     \* "none", "open", "close"
    fsOverlays,   \* current overlays in s.fs
    snapAlive,    \* TRUE if s.snapshot # nil, FALSE after Close
    snapOverlays, \* overlays stored on current s.snapshot
    openPc,       \* "start", "flushed", "done"
    openOverlays, \* overlays captured by DidOpenFile
    optPc,        \* "start", "read_overlays", "done", "nil_panic"
    optOverlays,  \* overlays captured by DidChangeCompilerOptionsForInferredProjects
    closePc       \* "start", "done"

vars == <<updateMu, fsOverlays, snapAlive, snapOverlays, openPc, openOverlays, optPc, optOverlays, closePc>>

Init ==
    /\ updateMu = "none"
    /\ fsOverlays = {}
    /\ snapAlive = TRUE
    /\ snapOverlays = {}
    /\ openPc = IF EnableClose THEN "done" ELSE "start"
    /\ openOverlays = {}
    /\ optPc = "start"
    /\ optOverlays = {}
    /\ closePc = IF EnableClose THEN "start" ELSE "done"

\* DidOpenFile: locks snapshotUpdateMu, flushes "a.ts" into s.fs
OpenLockAndFlush ==
    /\ openPc = "start"
    /\ updateMu = "none"
    /\ updateMu' = "open"
    /\ fsOverlays' = fsOverlays \cup {"a"}
    /\ openOverlays' = fsOverlays \cup {"a"}
    /\ openPc' = "flushed"
    /\ UNCHANGED <<snapAlive, snapOverlays, optPc, optOverlays, closePc>>

\* DidOpenFile: calls UpdateSnapshot (under snapshotMu) and releases snapshotUpdateMu
OpenUpdateAndUnlock ==
    /\ openPc = "flushed"
    /\ snapAlive
    /\ snapOverlays' = openOverlays
    /\ updateMu' = "none"
    /\ openPc' = "done"
    /\ UNCHANGED <<fsOverlays, snapAlive, openOverlays, optPc, optOverlays, closePc>>

\* DidChangeCompilerOptionsForInferredProjects: reads s.fs.Overlays() WITHOUT snapshotUpdateMu
OptReadOverlays ==
    /\ optPc = "start"
    /\ optOverlays' = fsOverlays
    /\ optPc' = "read_overlays"
    /\ UNCHANGED <<updateMu, fsOverlays, snapAlive, snapOverlays, openPc, openOverlays, closePc>>

\* DidChangeCompilerOptionsForInferredProjects: calls UpdateSnapshot WITHOUT snapshotUpdateMu
OptUpdateSnapshot ==
    /\ optPc = "read_overlays"
    /\ IF ~snapAlive
       THEN /\ optPc' = "nil_panic"
            /\ UNCHANGED snapOverlays
       ELSE /\ snapOverlays' = optOverlays
            /\ optPc' = "done"
    /\ UNCHANGED <<updateMu, fsOverlays, snapAlive, openPc, openOverlays, optOverlays, closePc>>

\* Session.Close: locks snapshotUpdateMu + snapshotMu, sets s.snapshot = nil
CloseSession ==
    /\ closePc = "start"
    /\ updateMu = "none"
    /\ snapAlive' = FALSE
    /\ closePc' = "done"
    /\ UNCHANGED <<updateMu, fsOverlays, snapOverlays, openPc, openOverlays, optPc, optOverlays>>

Terminated ==
    /\ openPc = "done"
    /\ closePc = "done"
    /\ optPc \in {"done", "nil_panic"}

Stutter == Terminated /\ UNCHANGED vars

Next ==
    \/ OpenLockAndFlush
    \/ OpenUpdateAndUnlock
    \/ OptReadOverlays
    \/ OptUpdateSnapshot
    \/ CloseSession
    \/ Stutter

Spec == Init /\ [][Next]_vars

InvNoLostOverlay ==
    (Terminated /\ ~EnableClose) => ("a" \in snapOverlays)

InvNoNilSnapshotClone ==
    optPc # "nil_panic"
=============================================================================
