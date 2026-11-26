----------------------- MODULE ContentMapperHost -----------------------
EXTENDS Integers

\* Faithful model of tsc/internal/contentmapper/hostimpl.go:
\* - projectLease.Transform (lines 792-811) -> unlocks h.mu -> h.transformLocked (lines 568-584) -> h.connFor
\* - projectLease.Refresh (lines 679-699) -> holds lifecycleMu.RLock + h.mu -> closeProject + entry.opened = false
\* - projectLease.release (lines 821-857) -> deletes project + h.release -> deletes conn & closes process

VARIABLES
    \* Host state
    connExists,       \* BOOLEAN: h.conns[id] != nil
    connRefs,         \* Int: h.conns[id].refs
    connLive,         \* BOOLEAN: h.conns[id].conn != nil (child process spawned)
    projectExists,    \* BOOLEAN: h.projects[handle] != nil
    projectOpened,    \* BOOLEAN: entry.opened
    \* Child process state (for current conn)
    childHasHandle,   \* BOOLEAN: child process currently has handle open
    \* Transform caller state
    txPC,             \* "idle" | "after_open_unlocked" | "done"
    \* Refresh caller state
    refPC,            \* "idle" | "done"
    \* Close caller state (optional: tests Transform vs Close)
    closePC,          \* "idle" | "done"
    \* Ghost violation flags
    transformClosedHandle, \* TRUE if MethodTransform sent while childHasHandle = FALSE
    orphanedZeroRefConn    \* TRUE if connFor spawned a fresh child process with connRefs = 0

vars == <<connExists, connRefs, connLive, projectExists, projectOpened, childHasHandle,
          txPC, refPC, closePC, transformClosedHandle, orphanedZeroRefConn>>

Init ==
    /\ connExists = TRUE
    /\ connRefs = 1
    /\ connLive = FALSE
    /\ projectExists = TRUE
    /\ projectOpened = FALSE
    /\ childHasHandle = FALSE
    /\ txPC = "idle"
    /\ refPC = "idle"
    /\ closePC = "idle"
    /\ transformClosedHandle = FALSE
    /\ orphanedZeroRefConn = FALSE

\* Transform part 1 (lines 795-809): acquires lifecycleMu.RLock + h.mu, opens project, unlocks h.mu
TransformOpenAndUnlock ==
    /\ txPC = "idle"
    /\ projectExists
    /\ connExists' = TRUE
    /\ connLive' = TRUE
    /\ projectOpened' = TRUE
    /\ childHasHandle' = TRUE
    /\ txPC' = "after_open_unlocked"
    /\ UNCHANGED <<connRefs, projectExists, refPC, closePC, transformClosedHandle, orphanedZeroRefConn>>

\* Transform part 2 (lines 810, 568-584): calls transformLocked -> h.connFor(mapper) -> conn.Call(MethodTransform)
TransformSendRPC ==
    /\ txPC = "after_open_unlocked"
    /\ IF ~connExists
       THEN \* h.connForLocked creates a brand-new mapperConn with refs = 0 and dials a NEW orphan process!
            /\ connExists' = TRUE
            /\ connLive' = TRUE
            /\ orphanedZeroRefConn' = (orphanedZeroRefConn \/ connRefs = 0)
            /\ transformClosedHandle' = TRUE \* brand-new child never received openProject!
       ELSE /\ transformClosedHandle' = (transformClosedHandle \/ ~childHasHandle)
            /\ UNCHANGED <<connExists, connLive, orphanedZeroRefConn>>
    /\ txPC' = "done"
    /\ UNCHANGED <<connRefs, projectExists, projectOpened, childHasHandle, refPC, closePC>>

\* Refresh (lines 679-699): acquires lifecycleMu.RLock + h.mu, calls closeProject, sets entry.opened = false
RefreshRun ==
    /\ refPC = "idle"
    /\ projectExists
    /\ IF projectOpened /\ connExists /\ connLive
       THEN /\ childHasHandle' = FALSE
            /\ projectOpened' = FALSE
       ELSE UNCHANGED <<childHasHandle, projectOpened>>
    /\ refPC' = "done"
    /\ UNCHANGED <<connExists, connRefs, connLive, projectExists, txPC, closePC,
                   transformClosedHandle, orphanedZeroRefConn>>

\* Close / release (lines 821-881): closes project, deletes from h.projects, decrements connRefs to 0, closes child!
CloseRun ==
    /\ closePC = "idle"
    /\ projectExists
    /\ projectExists' = FALSE
    /\ projectOpened' = FALSE
    /\ childHasHandle' = FALSE
    /\ connRefs' = connRefs - 1
    /\ IF connRefs - 1 = 0
       THEN /\ connExists' = FALSE
            /\ connLive' = FALSE
       ELSE UNCHANGED <<connExists, connLive>>
    /\ closePC' = "done"
    /\ UNCHANGED <<txPC, refPC, transformClosedHandle, orphanedZeroRefConn>>

Next ==
    \/ TransformOpenAndUnlock
    \/ TransformSendRPC
    \/ RefreshRun
    \/ CloseRun

NoTransformOnClosedHandle == ~transformClosedHandle
NoOrphanedZeroRefConn == ~orphanedZeroRefConn

=============================================================================
