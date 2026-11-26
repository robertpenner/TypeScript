----------------------- MODULE ApiSessionSnapshot -----------------------
EXTENDS Integers

\* Faithful model of tsc/internal/api/session.go:
\* - getSnapshotData (lines 703-711): looks up sd under RLock, unlocks WITHOUT retaining!
\* - releaseSnapshot (lines 725-743): decrements refCount, deletes from s.snapshots, calls sd.snapshot.Deref()
\* - registerSnapshot (lines 1865-1891): inserts into s.snapshots without checking closed
\* - Close (lines 5789-5810): clears s.snapshots and calls Deref() without setting closed

VARIABLES
    inMap,           \* BOOLEAN: handle S is in s.snapshots
    refCount,        \* 0..2: sd.refCount
    snapshotAlive,   \* BOOLEAN: sd.snapshot has not been Deref()'d to 0 (disposed)
    sessionClosed,   \* BOOLEAN: Session.Close() has run
    \* Query handler goroutine
    queryPC,         \* "idle" | "using_snapshot" | "done"
    \* CreateSnapshot goroutine (in-flight creating S2 during Close)
    createPC,        \* "idle" | "built_unregistered" | "done"
    s2InMap,         \* BOOLEAN: S2 inserted into s.snapshots
    \* Ghost violation flags
    useAfterDeref,   \* TRUE if query is using sd.snapshot after it was disposed by Deref()
    leakedAfterClose \* TRUE if S2 was registered into s.snapshots after Session.Close() completed

vars == <<inMap, refCount, snapshotAlive, sessionClosed, queryPC, createPC, s2InMap,
          useAfterDeref, leakedAfterClose>>

Init ==
    /\ inMap = TRUE
    /\ refCount = 1
    /\ snapshotAlive = TRUE
    /\ sessionClosed = FALSE
    /\ queryPC = "idle"
    /\ createPC = "idle"
    /\ s2InMap = FALSE
    /\ useAfterDeref = FALSE
    /\ leakedAfterClose = FALSE

\* getSnapshotData(S): reads s.snapshots[S] under RLock and unlocks WITHOUT bumping refCount!
QueryStart ==
    /\ queryPC = "idle"
    /\ inMap
    /\ queryPC' = "using_snapshot"
    /\ UNCHANGED <<inMap, refCount, snapshotAlive, sessionClosed, createPC, s2InMap,
                   useAfterDeref, leakedAfterClose>>

\* Query dereferences sd.snapshot (e.g. getProgram / GetChecker / parseCache)
QueryUseSnapshot ==
    /\ queryPC = "using_snapshot"
    /\ useAfterDeref' = (useAfterDeref \/ ~snapshotAlive)
    /\ queryPC' = "done"
    /\ UNCHANGED <<inMap, refCount, snapshotAlive, sessionClosed, createPC, s2InMap,
                   leakedAfterClose>>

\* handleRelease(S) -> releaseSnapshot(S)
ReleaseS ==
    /\ inMap
    /\ refCount' = refCount - 1
    /\ IF refCount - 1 <= 0
       THEN /\ inMap' = FALSE
            /\ snapshotAlive' = FALSE
       ELSE UNCHANGED <<inMap, snapshotAlive>>
    /\ UNCHANGED <<sessionClosed, queryPC, createPC, s2InMap, useAfterDeref, leakedAfterClose>>

\* Concurrent createSnapshot starts building S2 before Close()
CreateStart ==
    /\ createPC = "idle"
    /\ ~sessionClosed
    /\ createPC' = "built_unregistered"
    /\ UNCHANGED <<inMap, refCount, snapshotAlive, sessionClosed, queryPC, s2InMap,
                   useAfterDeref, leakedAfterClose>>

\* registerSnapshot(S2): locks snapshotsMu, inserts S2 WITHOUT checking sessionClosed!
RegisterS2 ==
    /\ createPC = "built_unregistered"
    /\ s2InMap' = TRUE
    /\ leakedAfterClose' = (leakedAfterClose \/ sessionClosed)
    /\ createPC' = "done"
    /\ UNCHANGED <<inMap, refCount, snapshotAlive, sessionClosed, queryPC, useAfterDeref>>

\* Session.Close(): clears s.snapshots and Deref()s all entries, does NOT set closed!
CloseSession ==
    /\ ~sessionClosed
    /\ sessionClosed' = TRUE
    /\ inMap' = FALSE
    /\ s2InMap' = FALSE
    /\ snapshotAlive' = FALSE
    /\ UNCHANGED <<refCount, queryPC, createPC, useAfterDeref, leakedAfterClose>>

Next ==
    \/ QueryStart
    \/ QueryUseSnapshot
    \/ ReleaseS
    \/ CreateStart
    \/ RegisterS2
    \/ CloseSession

NoUseAfterDeref == ~useAfterDeref
NoLeakAfterClose == ~leakedAfterClose

=============================================================================
