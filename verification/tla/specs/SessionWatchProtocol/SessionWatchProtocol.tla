----------------------- MODULE SessionWatchProtocol -----------------------
(*
 * Models tsc/internal/project/session.go:1428-1455, 1510-1595, 1635-1705
 * and tsc/internal/project/watch.go:34-100.
 *
 * Session.updateSnapshot enqueues updateWatches(oldSnapshot, newSnapshot) on
 * background.Queue, which launches an unbounded concurrent goroutine per task
 * without serialization or snapshot-ID ordering.
 *
 * Three scenarios for a shared watch glob G:
 *  1. "AddRemove": S0->S1 adds W1 (T1: Acquire -> WatchFiles), S1->S2 removes
 *     W1 (T2: Release -> UnwatchFiles). Out-of-order execution or RPC inversion
 *     leaves a permanently leaked client watch.
 *  2. "ConcurrentFail": S0->S1 adds W1 (T1) and S1->S2 adds W2 (T2) sharing G.
 *     T1 acquires (0->1, isNew=true), T2 acquires (1->2, isNew=false, skips RPC
 *     and succeeds), T1's WatchFiles fails and rolls back (2->1, marks W1
 *     pending). W2 is live and non-pending, regCount=1 blocks future retries,
 *     and the client holds zero watches for G.
 *  3. "FailThenRemove": W1 previously failed and rolled back its Acquire
 *     (pending={"W1"}), while W2 is active and registered (regCount=1,
 *     clientWatches={"w2"}). A later snapshot removes W1: updateWatch does not
 *     check IsPending(W1) and calls Release(G) + UnwatchFiles("w2"), tearing
 *     down W2's live watch.
 *)
EXTENDS Naturals, FiniteSets

CONSTANT Scenario

VARIABLES
    regCount,      \* watchRegistry[G].count (0 if absent)
    regId,         \* watchRegistry[G].id ("none" if absent)
    pending,       \* watchRegistry.pending subset of {"W1", "W2"}
    clientWatches, \* active WatcherIDs on client
    t1pc,          \* task 1 program counter
    t1AcquiredNew, \* whether T1's Acquire returned isNew=true
    t2pc,          \* task 2 program counter
    t2RemovedId    \* WatcherID returned by T2's Release ("none" if not removed)

vars == <<regCount, regId, pending, clientWatches, t1pc, t1AcquiredNew, t2pc, t2RemovedId>>

Init ==
    CASE Scenario = "AddRemove" ->
            /\ regCount = 0
            /\ regId = "none"
            /\ pending = {}
            /\ clientWatches = {}
            /\ t1pc = "acquire"
            /\ t1AcquiredNew = FALSE
            /\ t2pc = "release"
            /\ t2RemovedId = "none"
      [] Scenario = "ConcurrentFail" ->
            /\ regCount = 0
            /\ regId = "none"
            /\ pending = {}
            /\ clientWatches = {}
            /\ t1pc = "acquire"
            /\ t1AcquiredNew = FALSE
            /\ t2pc = "acquire"
            /\ t2RemovedId = "none"
      [] Scenario = "FailThenRemove" ->
            \* W1 already failed WatchFiles and rolled back (marked pending);
            \* W2 acquired and registered "w2" successfully.
            /\ regCount = 1
            /\ regId = "w2"
            /\ pending = {"W1"}
            /\ clientWatches = {"w2"}
            /\ t1pc = "done"
            /\ t1AcquiredNew = FALSE
            /\ t2pc = "release"
            /\ t2RemovedId = "none"

\* --- Scenario 1: AddRemove (T1 adds W1, T2 removes W1) ---

AddRemove_T1Acquire ==
    /\ Scenario = "AddRemove"
    /\ t1pc = "acquire"
    /\ IF regCount = 0
       THEN /\ regCount' = 1
            /\ regId' = "w1"
            /\ t1AcquiredNew' = TRUE
            /\ t1pc' = "watch_rpc"
       ELSE /\ regCount' = regCount + 1
            /\ UNCHANGED regId
            /\ t1AcquiredNew' = FALSE
            /\ t1pc' = "done"
    /\ UNCHANGED <<pending, clientWatches, t2pc, t2RemovedId>>

AddRemove_T1WatchRPC ==
    /\ Scenario = "AddRemove"
    /\ t1pc = "watch_rpc"
    /\ clientWatches' = clientWatches \cup {"w1"}
    /\ pending' = pending \ {"W1"}
    /\ t1pc' = "done"
    /\ UNCHANGED <<regCount, regId, t1AcquiredNew, t2pc, t2RemovedId>>

AddRemove_T2Release ==
    /\ Scenario = "AddRemove"
    /\ t2pc = "release"
    /\ IF regCount = 0
       THEN /\ t2RemovedId' = "none"
            /\ t2pc' = "done"
            /\ UNCHANGED <<regCount, regId>>
       ELSE IF regCount <= 1
       THEN /\ t2RemovedId' = regId
            /\ regCount' = 0
            /\ regId' = "none"
            /\ t2pc' = "unwatch_rpc"
       ELSE /\ regCount' = regCount - 1
            /\ t2RemovedId' = "none"
            /\ t2pc' = "done"
            /\ UNCHANGED regId
    /\ UNCHANGED <<pending, clientWatches, t1pc, t1AcquiredNew>>

AddRemove_T2UnwatchRPC ==
    /\ Scenario = "AddRemove"
    /\ t2pc = "unwatch_rpc"
    /\ clientWatches' = clientWatches \ {t2RemovedId}
    /\ t2pc' = "done"
    /\ UNCHANGED <<regCount, regId, pending, t1pc, t1AcquiredNew, t2RemovedId>>

\* --- Scenario 2: ConcurrentFail (T1 adds W1 and WatchFiles fails; T2 adds W2) ---

ConcurrentFail_T1Acquire ==
    /\ Scenario = "ConcurrentFail"
    /\ t1pc = "acquire"
    /\ IF regCount = 0
       THEN /\ regCount' = 1
            /\ regId' = "w1"
            /\ t1AcquiredNew' = TRUE
            /\ t1pc' = "watch_fail"
       ELSE /\ regCount' = regCount + 1
            /\ UNCHANGED regId
            /\ t1AcquiredNew' = FALSE
            /\ t1pc' = "done"
    /\ UNCHANGED <<pending, clientWatches, t2pc, t2RemovedId>>

ConcurrentFail_T1FailRollback ==
    /\ Scenario = "ConcurrentFail"
    /\ t1pc = "watch_fail"
    \* WatchFiles("w1") fails -> rolls back newly acquired watchers and marks W1 pending
    /\ IF regCount <= 1
       THEN /\ regCount' = 0
            /\ regId' = "none"
       ELSE /\ regCount' = regCount - 1
            /\ UNCHANGED regId
    /\ pending' = pending \cup {"W1"}
    /\ t1pc' = "done"
    /\ UNCHANGED <<clientWatches, t1AcquiredNew, t2pc, t2RemovedId>>

ConcurrentFail_T2Acquire ==
    /\ Scenario = "ConcurrentFail"
    /\ t2pc = "acquire"
    /\ IF regCount = 0
       THEN /\ regCount' = 1
            /\ regId' = "w2"
            /\ t2pc' = "watch_rpc"
       ELSE /\ regCount' = regCount + 1
            /\ UNCHANGED regId
            /\ t2pc' = "clear_pending"
    /\ UNCHANGED <<pending, clientWatches, t1pc, t1AcquiredNew, t2RemovedId>>

ConcurrentFail_T2WatchRPC ==
    /\ Scenario = "ConcurrentFail"
    /\ t2pc = "watch_rpc"
    /\ clientWatches' = clientWatches \cup {"w2"}
    /\ pending' = pending \ {"W2"}
    /\ t2pc' = "done"
    /\ UNCHANGED <<regCount, regId, t1pc, t1AcquiredNew, t2RemovedId>>

ConcurrentFail_T2ClearPending ==
    /\ Scenario = "ConcurrentFail"
    /\ t2pc = "clear_pending"
    /\ pending' = pending \ {"W2"}
    /\ t2pc' = "done"
    /\ UNCHANGED <<regCount, regId, clientWatches, t1pc, t1AcquiredNew, t2RemovedId>>

\* --- Scenario 3: FailThenRemove (W1 rolled back earlier, now removed while W2 is live) ---

FailThenRemove_T2Release ==
    /\ Scenario = "FailThenRemove"
    /\ t2pc = "release"
    \* updateWatch(ctx, W1, nil) does NOT check IsPending(W1); blindly calls Release(G)
    /\ IF regCount <= 1
       THEN /\ t2RemovedId' = regId
            /\ regCount' = 0
            /\ regId' = "none"
            /\ t2pc' = "unwatch_rpc"
       ELSE /\ regCount' = regCount - 1
            /\ t2RemovedId' = "none"
            /\ t2pc' = "done"
            /\ UNCHANGED regId
    /\ UNCHANGED <<pending, clientWatches, t1pc, t1AcquiredNew>>

FailThenRemove_T2UnwatchRPC ==
    /\ Scenario = "FailThenRemove"
    /\ t2pc = "unwatch_rpc"
    /\ clientWatches' = clientWatches \ {t2RemovedId}
    /\ t2pc' = "done"
    /\ UNCHANGED <<regCount, regId, pending, t1pc, t1AcquiredNew, t2RemovedId>>

Terminated == t1pc = "done" /\ t2pc = "done"
Stutter == Terminated /\ UNCHANGED vars

Next ==
    \/ AddRemove_T1Acquire
    \/ AddRemove_T1WatchRPC
    \/ AddRemove_T2Release
    \/ AddRemove_T2UnwatchRPC
    \/ ConcurrentFail_T1Acquire
    \/ ConcurrentFail_T1FailRollback
    \/ ConcurrentFail_T2Acquire
    \/ ConcurrentFail_T2WatchRPC
    \/ ConcurrentFail_T2ClearPending
    \/ FailThenRemove_T2Release
    \/ FailThenRemove_T2UnwatchRPC
    \/ Stutter

Spec == Init /\ [][Next]_vars

\* Invariants:
InvNoLeakedClientWatch ==
    Terminated => (clientWatches = {} /\ regCount = 0)

InvActiveWatcherCovered ==
    (Terminated /\ "W2" \notin pending) => (clientWatches # {})

InvLiveWatcherNotStolen ==
    Terminated => (regCount = 1 /\ "w2" \in clientWatches)
=============================================================================
