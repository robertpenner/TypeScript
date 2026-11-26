------------------------ MODULE SessionGlobalDiag ------------------------
EXTENDS Integers

\* Faithful model of Session.EnqueuePublishGlobalDiagnostics / publishGlobalDiagnostics
\* (tsc/internal/project/session.go:1998-2024) + checkerPool.TakeNewGlobalDiagnostics
\* (tsc/internal/project/checkerpool.go:405-425).
\*
\* UseFix = FALSE: buggy atomic.Bool cleared by defer at function exit.
\* UseFix = TRUE:  3-state atomic latch (0=idle, 1=running, 2=rerun) with single-worker rerun loop.

CONSTANTS
    MaxEvents, \* Max number of new global diagnostic events to produce, e.g. 3
    UseFix     \* BOOLEAN: FALSE models buggy defer latch, TRUE models 3-state rerun loop

IDLE    == 0
RUNNING == 1
RERUN   == 2

VARIABLES
    producedCount,    \* 0..MaxEvents: total global diagnostics accumulated in checkerPool
    globalDiagChanged,\* BOOLEAN: checkerPool.globalDiagChanged
    publishState,     \* IDLE (0) | RUNNING (1) | RERUN (2)
    publishedCount,   \* 0..MaxEvents: latest global diagnostics count actually published to client
    workerPC,         \* "idle" | "queued" | "took_flag" | "read_diags" | "sent_rpc" | "reset_rerun"
    workerSawChange,  \* BOOLEAN: return value of TakeNewGlobalDiagnostics()
    workerDiagSnap,   \* 0..MaxEvents: snapshot read by GetProjectDiagnostics()
    outOfOrderPublish \* BOOLEAN: TRUE if a publish sent a smaller count than already published

vars == <<producedCount, globalDiagChanged, publishState, publishedCount,
          workerPC, workerSawChange, workerDiagSnap, outOfOrderPublish>>

Init ==
    /\ producedCount = 0
    /\ globalDiagChanged = FALSE
    /\ publishState = IDLE
    /\ publishedCount = 0
    /\ workerPC = "idle"
    /\ workerSawChange = FALSE
    /\ workerDiagSnap = 0
    /\ outOfOrderPublish = FALSE

\* Diagnostics checker finishes, merges new global diag, calls EnqueuePublishGlobalDiagnostics().
ProduceGlobalDiagAndEnqueue ==
    /\ producedCount < MaxEvents
    /\ producedCount' = producedCount + 1
    /\ globalDiagChanged' = TRUE
    /\ IF ~UseFix
       THEN IF publishState = IDLE
            THEN /\ publishState' = RUNNING
                 /\ workerPC' = "queued"
            ELSE UNCHANGED <<publishState, workerPC>>
       ELSE IF publishState = IDLE
            THEN /\ publishState' = RUNNING
                 /\ workerPC' = "queued"
            ELSE IF publishState = RUNNING
            THEN /\ publishState' = RERUN
                 /\ UNCHANGED workerPC
            ELSE UNCHANGED <<publishState, workerPC>>
    /\ UNCHANGED <<publishedCount, workerSawChange, workerDiagSnap, outOfOrderPublish>>

\* publishGlobalDiagnostics calls project.checkerPool.TakeNewGlobalDiagnostics()
WorkerTakeFlag ==
    /\ workerPC = "queued"
    /\ workerSawChange' = globalDiagChanged
    /\ globalDiagChanged' = FALSE
    /\ workerPC' = "took_flag"
    /\ UNCHANGED <<producedCount, publishState, publishedCount, workerDiagSnap, outOfOrderPublish>>

\* If TakeNewGlobalDiagnostics() returned TRUE, calls project.GetProjectDiagnostics(ctx)
WorkerReadDiags ==
    /\ workerPC = "took_flag"
    /\ IF workerSawChange
       THEN /\ workerDiagSnap' = producedCount
            /\ workerPC' = "read_diags"
       ELSE /\ workerPC' = "sent_rpc"
            /\ UNCHANGED workerDiagSnap
    /\ UNCHANGED <<producedCount, globalDiagChanged, publishState, publishedCount, workerSawChange, outOfOrderPublish>>

\* Sends PublishDiagnostics RPC to client
WorkerSendRPC ==
    /\ workerPC = "read_diags"
    /\ outOfOrderPublish' = (outOfOrderPublish \/ workerDiagSnap < publishedCount)
    /\ publishedCount' = workerDiagSnap
    /\ workerPC' = "sent_rpc"
    /\ UNCHANGED <<producedCount, globalDiagChanged, publishState, workerSawChange, workerDiagSnap>>

\* End of pass step 1:
\* - Buggy mode: defer Store(false) unconditionally
\* - Fixed mode: CAS(RUNNING, IDLE) -> exit; else state was RERUN -> advance to reset_rerun
\*   (split so TLC explicitly checks producers racing between CAS failure and Store(RUNNING)!)
WorkerEndPass ==
    /\ workerPC = "sent_rpc"
    /\ workerSawChange' = FALSE
    /\ IF ~UseFix
       THEN /\ publishState' = IDLE
            /\ workerPC' = "idle"
       ELSE IF publishState = RUNNING
            THEN /\ publishState' = IDLE
                 /\ workerPC' = "idle"
            ELSE /\ workerPC' = "reset_rerun"
                 /\ UNCHANGED publishState
    /\ UNCHANGED <<producedCount, globalDiagChanged, publishedCount, workerDiagSnap, outOfOrderPublish>>

\* End of pass step 2 (fixed mode only): Store(RUNNING) and loop back to scan
WorkerResetRunning ==
    /\ workerPC = "reset_rerun"
    /\ publishState' = RUNNING
    /\ workerPC' = "queued"
    /\ UNCHANGED <<producedCount, globalDiagChanged, publishedCount, workerSawChange,
                   workerDiagSnap, outOfOrderPublish>>

Next ==
    \/ ProduceGlobalDiagAndEnqueue
    \/ WorkerTakeFlag
    \/ WorkerReadDiags
    \/ WorkerSendRPC
    \/ WorkerEndPass
    \/ WorkerResetRunning

Spec == Init /\ [][Next]_vars /\ WF_vars(WorkerTakeFlag \/ WorkerReadDiags \/ WorkerSendRPC \/ WorkerEndPass \/ WorkerResetRunning)

\* Safety at quiescence: when no background publish is pending/running,
\* the client must have received all produced global diagnostics!
NoLostGlobalDiagnostics ==
    (workerPC = "idle" /\ publishState = IDLE) => (publishedCount = producedCount /\ ~globalDiagChanged)

NoOutOfOrderPublish == ~outOfOrderPublish

\* Liveness: every produced diagnostic is eventually published
EventuallyAllPublished == <>(publishedCount = producedCount /\ publishState = IDLE)

=============================================================================
