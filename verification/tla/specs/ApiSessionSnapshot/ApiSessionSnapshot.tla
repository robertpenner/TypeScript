----------------------- MODULE ApiSessionSnapshot -----------------------
EXTENDS Integers

\* Faithful model of tsc/internal/api/session.go:
\* - UseFix = FALSE: getSnapshotData unlocks without retaining; Close clears map without setting closed.
\* - UseFix = TRUE:  getSnapshotData retains underlying project.Snapshot under snapshotsMu.RLock()
\*   and returns a release() closure calling Deref(); Close sets closed=TRUE under snapshotsMu.Lock();
\*   registerSnapshot checks closed and immediately Deref()s if closed.

CONSTANTS
    UseFix \* BOOLEAN

VARIABLES
    inMap,           \* BOOLEAN: handle S is in s.snapshots
    clientRefs,      \* 0..2: sd.refCount (client-owned refs)
    snapRefCount,    \* Int: underlying project.Snapshot atomic refCount (initial 1 owned by s.snapshots[S])
    s2RefCount,      \* Int: underlying project.Snapshot refCount for in-flight S2 (0 before create, 1 when built)
    sessionClosed,   \* BOOLEAN: Session.Close() has run
    queryPC,         \* "idle" | "using_snapshot" | "done"
    createPC,        \* "idle" | "built_unregistered" | "done"
    s2InMap,         \* BOOLEAN: S2 inserted into s.snapshots
    \* Ghost violation flags
    useAfterDeref,   \* TRUE if query uses sd.snapshot while snapRefCount <= 0
    leakedAfterClose,\* TRUE if S2 was registered into s.snapshots after Session.Close()
    negativeSnapRef  \* TRUE if Deref() dropped any snapshot refCount below 0

vars == <<inMap, clientRefs, snapRefCount, s2RefCount, sessionClosed,
          queryPC, createPC, s2InMap, useAfterDeref, leakedAfterClose, negativeSnapRef>>

Init ==
    /\ inMap = TRUE
    /\ clientRefs = 1
    /\ snapRefCount = 1
    /\ s2RefCount = 0
    /\ sessionClosed = FALSE
    /\ queryPC = "idle"
    /\ createPC = "idle"
    /\ s2InMap = FALSE
    /\ useAfterDeref = FALSE
    /\ leakedAfterClose = FALSE
    /\ negativeSnapRef = FALSE

\* getSnapshotData(S)
QueryStart ==
    /\ queryPC = "idle"
    /\ inMap
    /\ snapRefCount' = IF UseFix THEN snapRefCount + 1 ELSE snapRefCount
    /\ queryPC' = "using_snapshot"
    /\ UNCHANGED <<inMap, clientRefs, s2RefCount, sessionClosed, createPC, s2InMap,
                   useAfterDeref, leakedAfterClose, negativeSnapRef>>

\* Query uses sd.snapshot and (if UseFix) runs defer release() -> sd.snapshot.Deref()
QueryUseAndRelease ==
    /\ queryPC = "using_snapshot"
    /\ useAfterDeref' = (useAfterDeref \/ snapRefCount <= 0)
    /\ IF UseFix
       THEN /\ negativeSnapRef' = (negativeSnapRef \/ snapRefCount - 1 < 0)
            /\ snapRefCount' = snapRefCount - 1
       ELSE UNCHANGED <<negativeSnapRef, snapRefCount>>
    /\ queryPC' = "done"
    /\ UNCHANGED <<inMap, clientRefs, s2RefCount, sessionClosed, createPC, s2InMap, leakedAfterClose>>

\* handleRelease(S) -> releaseSnapshot(S)
ReleaseS ==
    /\ inMap
    /\ clientRefs' = clientRefs - 1
    /\ IF clientRefs - 1 <= 0
       THEN /\ inMap' = FALSE
            /\ negativeSnapRef' = (negativeSnapRef \/ snapRefCount - 1 < 0)
            /\ snapRefCount' = snapRefCount - 1
       ELSE UNCHANGED <<inMap, negativeSnapRef, snapRefCount>>
    /\ UNCHANGED <<s2RefCount, sessionClosed, queryPC, createPC, s2InMap, useAfterDeref, leakedAfterClose>>

\* Concurrent createSnapshot builds retained S2 (s2RefCount = 1) before Close()
CreateStart ==
    /\ createPC = "idle"
    /\ ~sessionClosed
    /\ s2RefCount' = 1
    /\ createPC' = "built_unregistered"
    /\ UNCHANGED <<inMap, clientRefs, snapRefCount, sessionClosed, queryPC, s2InMap,
                   useAfterDeref, leakedAfterClose, negativeSnapRef>>

\* registerSnapshot(S2)
RegisterS2 ==
    /\ createPC = "built_unregistered"
    /\ IF UseFix /\ sessionClosed
       THEN \* Reject post-close registration and immediately Deref S2!
            /\ negativeSnapRef' = (negativeSnapRef \/ s2RefCount - 1 < 0)
            /\ s2RefCount' = s2RefCount - 1
            /\ UNCHANGED <<s2InMap, leakedAfterClose>>
       ELSE /\ s2InMap' = TRUE
            /\ leakedAfterClose' = (leakedAfterClose \/ sessionClosed)
            /\ UNCHANGED <<negativeSnapRef, s2RefCount>>
    /\ createPC' = "done"
    /\ UNCHANGED <<inMap, clientRefs, snapRefCount, sessionClosed, queryPC, useAfterDeref>>

\* Session.Close(): drains and clears s.snapshots, calls Deref() on drained entries
CloseSession ==
    /\ ~sessionClosed
    /\ sessionClosed' = TRUE
    /\ LET decS  == IF inMap THEN 1 ELSE 0
           decS2 == IF s2InMap THEN 1 ELSE 0
       IN
       /\ negativeSnapRef' = (negativeSnapRef \/ (snapRefCount - decS < 0) \/ (s2RefCount - decS2 < 0))
       /\ snapRefCount' = snapRefCount - decS
       /\ s2RefCount' = s2RefCount - decS2
       /\ inMap' = FALSE
       /\ s2InMap' = FALSE
    /\ UNCHANGED <<clientRefs, queryPC, createPC, useAfterDeref, leakedAfterClose>>

AllDone ==
    /\ sessionClosed
    /\ queryPC \in {"idle", "done"}
    /\ createPC \in {"idle", "done"}
    /\ UNCHANGED vars

Next ==
    \/ QueryStart
    \/ QueryUseAndRelease
    \/ ReleaseS
    \/ CreateStart
    \/ RegisterS2
    \/ CloseSession
    \/ AllDone

NoUseAfterDeref  == ~useAfterDeref
NoLeakAfterClose == ~leakedAfterClose
NoNegativeSnapRef == ~negativeSnapRef

\* At quiescence after CloseSession (with all in-flight queries and creates done),
\* no snapshot remains in the map and all underlying snapshot refCounts reached 0!
QuiescentClean ==
    (sessionClosed /\ queryPC \in {"idle", "done"} /\ createPC \in {"idle", "done"}) =>
        (~inMap /\ ~s2InMap /\ snapRefCount = 0 /\ s2RefCount = 0)

=============================================================================
