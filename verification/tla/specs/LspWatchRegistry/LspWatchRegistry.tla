---- MODULE LspWatchRegistry ----
EXTENDS Naturals

(*
 * Models Server.WatchFiles / Server.UnwatchFiles in:
 *   tsc/internal/lsp/server.go:300-355
 *
 * Two defects:
 *   1. Timed-out WatchFiles strands client registration (InvTimedOutWatchCanBeUnwatched):
 *      WatchFiles sends client/registerCapability(id) over JSON-RPC, waits on
 *      ctx.Done(), and only calls s.watchers.Add(id) if the RPC succeeds before
 *      ctx expires. When the 1s watchRequestTimeout fires while the client still
 *      installs registration `id`, s.watchers never contains `id`. Any subsequent
 *      UnwatchFiles(id) checks `if s.watchers.Has(id)` and refuses with
 *      "no file watcher exists with ID ...", permanently stranding the client watch.
 *   2. Concurrent UnwatchFiles TOCTOU (InvNoDuplicateUnwatch):
 *      UnwatchFiles checks `s.watchers.Has(id)`, sends client/unregisterCapability(id)
 *      without locking, and calls `s.watchers.Delete(id)` only after the RPC returns.
 *      Two concurrent UnwatchFiles(id) calls both pass Has(id) and issue duplicate
 *      unregister RPCs for the same ID.
 *)

WORKERS == {1, 2}

VARIABLES
    serverWatchers,     \* s.watchers.Has(id)
    clientInstalled,    \* Client has installed registration id
    regInFlight,        \* client/registerCapability(id) sent over wire, not yet processed by client
    watchPC,            \* "idle" | "sent" | "timedOut" | "done"
    unwatchPC,          \* [WORKERS -> {"idle", "checkedHas", "sentUnreg", "done", "refused"}]
    unregSentCount,     \* Total client/unregisterCapability RPCs sent by Server
    strandedRefusal     \* Sticky: UnwatchFiles refused while clientInstalled = TRUE

vars == <<serverWatchers, clientInstalled, regInFlight, watchPC,
          unwatchPC, unregSentCount, strandedRefusal>>

TypeOK ==
    /\ serverWatchers \in BOOLEAN
    /\ clientInstalled \in BOOLEAN
    /\ regInFlight \in BOOLEAN
    /\ watchPC \in {"idle", "sent", "timedOut", "done"}
    /\ unwatchPC \in [WORKERS -> {"idle", "checkedHas", "sentUnreg", "done", "refused"}]
    /\ unregSentCount \in 0..2
    /\ strandedRefusal \in BOOLEAN

Init ==
    /\ serverWatchers = FALSE
    /\ clientInstalled = FALSE
    /\ regInFlight = FALSE
    /\ watchPC = "idle"
    /\ unwatchPC = [w \in WORKERS |-> "idle"]
    /\ unregSentCount = 0
    /\ strandedRefusal = FALSE

\* WatchFiles(ctx, id, ...): sends client/registerCapability(id)
WatchSend ==
    /\ watchPC = "idle"
    /\ regInFlight' = TRUE
    /\ watchPC' = "sent"
    /\ UNCHANGED <<serverWatchers, clientInstalled, unwatchPC, unregSentCount, strandedRefusal>>

\* Normal fast path: client installs id and replies before ctx expires -> s.watchers.Add(id)
WatchSucceed ==
    /\ watchPC = "sent"
    /\ regInFlight
    /\ regInFlight' = FALSE
    /\ clientInstalled' = TRUE
    /\ serverWatchers' = TRUE
    /\ watchPC' = "done"
    /\ UNCHANGED <<unwatchPC, unregSentCount, strandedRefusal>>

\* Timeout path: ctx expires while registerCapability is still in flight on the client
WatchTimeout ==
    /\ watchPC = "sent"
    /\ regInFlight
    /\ watchPC' = "timedOut"
    /\ UNCHANGED <<serverWatchers, clientInstalled, regInFlight, unwatchPC, unregSentCount, strandedRefusal>>

\* Client finishes processing the timed-out registerCapability and installs watcher id
ClientInstallAfterTimeout ==
    /\ watchPC = "timedOut"
    /\ regInFlight
    /\ regInFlight' = FALSE
    /\ clientInstalled' = TRUE
    /\ UNCHANGED <<serverWatchers, watchPC, unwatchPC, unregSentCount, strandedRefusal>>

\* UnwatchFiles(ctx, id): checks s.watchers.Has(id) BEFORE sending RPC (server.go:341)
UnwatchCheckHas(w) ==
    /\ unwatchPC[w] = "idle"
    /\ watchPC \in {"timedOut", "done"}
    /\ ~regInFlight
    /\ IF serverWatchers
       THEN /\ unwatchPC' = [unwatchPC EXCEPT ![w] = "checkedHas"]
            /\ UNCHANGED strandedRefusal
       ELSE /\ unwatchPC' = [unwatchPC EXCEPT ![w] = "refused"]
            /\ strandedRefusal' = (strandedRefusal \/ clientInstalled)
    /\ UNCHANGED <<serverWatchers, clientInstalled, regInFlight, watchPC, unregSentCount>>

\* UnwatchFiles(ctx, id): sends client/unregisterCapability(id) (server.go:342)
UnwatchSendRPC(w) ==
    /\ unwatchPC[w] = "checkedHas"
    /\ unregSentCount < 2
    /\ unregSentCount' = unregSentCount + 1
    /\ clientInstalled' = FALSE
    /\ unwatchPC' = [unwatchPC EXCEPT ![w] = "sentUnreg"]
    /\ UNCHANGED <<serverWatchers, regInFlight, watchPC, strandedRefusal>>

\* UnwatchFiles(ctx, id): deletes id from s.watchers AFTER RPC returns (server.go:351)
UnwatchDelete(w) ==
    /\ unwatchPC[w] = "sentUnreg"
    /\ serverWatchers' = FALSE
    /\ unwatchPC' = [unwatchPC EXCEPT ![w] = "done"]
    /\ UNCHANGED <<clientInstalled, regInFlight, watchPC, unregSentCount, strandedRefusal>>

Next ==
    \/ WatchSend
    \/ WatchSucceed
    \/ WatchTimeout
    \/ ClientInstallAfterTimeout
    \/ \E w \in WORKERS : UnwatchCheckHas(w)
    \/ \E w \in WORKERS : UnwatchSendRPC(w)
    \/ \E w \in WORKERS : UnwatchDelete(w)

Spec == Init /\ [][Next]_vars

\* Bug 3.3a: UnwatchFiles must not refuse while the client actually has watcher id installed
InvTimedOutWatchCanBeUnwatched == ~strandedRefusal

\* Bug 3.3b: Server must never send duplicate client/unregisterCapability RPCs for the same id
InvNoDuplicateUnwatch == unregSentCount <= 1
====
