------------------------ MODULE SessionGlobalDiag ------------------------
EXTENDS Integers

\* Faithful model of Session.EnqueuePublishGlobalDiagnostics / publishGlobalDiagnostics
\* (tsc/internal/project/session.go:1998-2024) + checkerPool.TakeNewGlobalDiagnostics
\* (tsc/internal/project/checkerpool.go:405-425) + background.Queue.Enqueue.

CONSTANTS
    MaxEvents \* Max number of new global diagnostic events to produce, e.g. 2

VARIABLES
    \* CheckerPool state
    producedCount,    \* 0..MaxEvents: total global diagnostics produced by checker 0
    globalDiagChanged,\* BOOLEAN: checkerPool.globalDiagChanged
    \* Session state
    publishPending,   \* BOOLEAN: Session.globalDiagPublishPending
    publishedCount,   \* 0..MaxEvents: latest global diagnostics count actually published to client
    \* Background worker state
    workerPC,         \* "idle" | "queued" | "took_flag" | "read_diags" | "sent_rpc"
    workerSawChange,  \* BOOLEAN: return value of TakeNewGlobalDiagnostics()
    workerDiagSnap    \* 0..MaxEvents: snapshot read by GetProjectDiagnostics()

vars == <<producedCount, globalDiagChanged, publishPending, publishedCount,
          workerPC, workerSawChange, workerDiagSnap>>

Init ==
    /\ producedCount = 0
    /\ globalDiagChanged = FALSE
    /\ publishPending = FALSE
    /\ publishedCount = 0
    /\ workerPC = "idle"
    /\ workerSawChange = FALSE
    /\ workerDiagSnap = 0

\* Diagnostics checker finishes, merges new global diag, calls EnqueuePublishGlobalDiagnostics().
ProduceGlobalDiagAndEnqueue ==
    /\ producedCount < MaxEvents
    /\ producedCount' = producedCount + 1
    /\ globalDiagChanged' = TRUE
    /\ IF ~publishPending
       THEN /\ publishPending' = TRUE
            /\ workerPC' = "queued"
       ELSE /\ UNCHANGED <<publishPending, workerPC>>
    /\ UNCHANGED <<publishedCount, workerSawChange, workerDiagSnap>>

\* publishGlobalDiagnostics calls project.checkerPool.TakeNewGlobalDiagnostics()
WorkerTakeFlag ==
    /\ workerPC = "queued"
    /\ workerSawChange' = globalDiagChanged
    /\ globalDiagChanged' = FALSE
    /\ workerPC' = "took_flag"
    /\ UNCHANGED <<producedCount, publishPending, publishedCount, workerDiagSnap>>

\* If TakeNewGlobalDiagnostics() returned TRUE, calls project.GetProjectDiagnostics(ctx)
WorkerReadDiags ==
    /\ workerPC = "took_flag"
    /\ IF workerSawChange
       THEN /\ workerDiagSnap' = producedCount
            /\ workerPC' = "read_diags"
       ELSE /\ workerPC' = "sent_rpc"
            /\ UNCHANGED workerDiagSnap
    /\ UNCHANGED <<producedCount, globalDiagChanged, publishPending, publishedCount, workerSawChange>>

\* Sends PublishDiagnostics RPC to client (while globalDiagPublishPending is still TRUE!)
WorkerSendRPC ==
    /\ workerPC = "read_diags"
    /\ publishedCount' = workerDiagSnap
    /\ workerPC' = "sent_rpc"
    /\ UNCHANGED <<producedCount, globalDiagChanged, publishPending, workerSawChange, workerDiagSnap>>

\* publishGlobalDiagnostics returns -> executes: defer s.globalDiagPublishPending.Store(false)
WorkerDeferClear ==
    /\ workerPC = "sent_rpc"
    /\ publishPending' = FALSE
    /\ workerSawChange' = FALSE
    /\ workerPC' = "idle"
    /\ UNCHANGED <<producedCount, globalDiagChanged, publishedCount, workerDiagSnap>>

Next ==
    \/ ProduceGlobalDiagAndEnqueue
    \/ WorkerTakeFlag
    \/ WorkerReadDiags
    \/ WorkerSendRPC
    \/ WorkerDeferClear

\* Safety at quiescence: when no background publish is pending/running,
\* the client must have received all produced global diagnostics!
NoLostGlobalDiagnostics ==
    (workerPC = "idle" /\ ~publishPending) => (publishedCount = producedCount)

=============================================================================
