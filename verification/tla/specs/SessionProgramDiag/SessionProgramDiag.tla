------------------------ MODULE SessionProgramDiag ------------------------
(*
 * Models tsc/internal/project/session.go:1428-1455, 1902-1965.
 *
 * Session.updateSnapshot enqueues publishProgramDiagnostics(old, new) onto
 * background.Queue (unbounded concurrent goroutines) with no serialization
 * mutex or snapshot-ID monotonicity guard, unlike
 * updateContentMapperRegistrations right beside it (session.go:1615-1620).
 *
 * Snapshot S1 has a program diagnostic ("err") on tsconfig.json.
 * Snapshot S2 fixes the error or closes the project ("empty").
 * Both tasks run concurrently and call client.PublishDiagnostics without
 * ordering, allowing S1's task to overwrite S2's cleared diagnostics.
 *)
VARIABLES
    clientDiags, \* "none", "err", "empty"
    t1pc,        \* S0->S1 task: "pending", "done"
    t2pc         \* S1->S2 task: "pending", "done"

vars == <<clientDiags, t1pc, t2pc>>

Init ==
    /\ clientDiags = "none"
    /\ t1pc = "pending"
    /\ t2pc = "pending"

T1Publish ==
    /\ t1pc = "pending"
    /\ clientDiags' = "err"
    /\ t1pc' = "done"
    /\ UNCHANGED t2pc

T2Publish ==
    /\ t2pc = "pending"
    /\ clientDiags' = "empty"
    /\ t2pc' = "done"
    /\ UNCHANGED t1pc

Stutter ==
    /\ t1pc = "done"
    /\ t2pc = "done"
    /\ UNCHANGED vars

Next == T1Publish \/ T2Publish \/ Stutter
Spec == Init /\ [][Next]_vars

InvFinalDiagnosticsMatchLatest ==
    (t1pc = "done" /\ t2pc = "done") => clientDiags = "empty"
=============================================================================
