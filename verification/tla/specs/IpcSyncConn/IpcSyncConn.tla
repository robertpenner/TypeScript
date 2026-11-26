---------------------------- MODULE IpcSyncConn ----------------------------
(*
 * Models tsc/internal/ipc/conn_sync.go (SyncConn.Call, Run, lockTurn, and
 * notification dispatch).
 *
 * Captures two distinct defects in the Go implementation:
 *
 * 1. NotificationSwap (conn_sync.go:183-256):
 *    When G1 is in Call(method="readFile", req="A"), the peer may send a
 *    fire-and-forget Notification followed immediately by Response(id="readFile",
 *    result="A"). On reading the Notification, G1 sets reading := FALSE,
 *    broadcasts turn, and unlocks mu while running HandleNotification. A
 *    waiting concurrent caller G2 wakes up, sees reading == FALSE, increments
 *    calls to 2, sets reading := TRUE, writes Request(id="readFile", req="B"),
 *    and reads Response(id="readFile", result="A") off the wire! Because
 *    SyncConn.Call sets msg.ID = method (line 205) and matches msg.ID == method
 *    (line 225), G2 silently accepts "A" as the answer to "B" (and G1 later
 *    accepts "B" as the answer to "A").
 *
 * 2. CancelOrphan (conn_sync.go:205-218):
 *    Call() invokes protocol.WriteRequest(id, method, params) BEFORE checking
 *    if ctx.Err() != nil { return nil, ctx.Err() }. When ctx is already
 *    cancelled (or cancels during WriteRequest), the request is still written
 *    to the wire, Call returns ctx.Err() without reading the peer's response,
 *    and the orphaned response sits on the wire until Run() hits
 *    "unexpected response message in sync connection" (line 81) or a later
 *    Call() consumes the stale response.
 *)

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Mode \* "NotificationSwap" or "CancelOrphan"

Callers == {"G1", "G2"}

VARIABLES
    \* SyncConn mutex/cond state (conn_sync.go:34-43)
    calls,      \* c.calls (Nat)
    reading,    \* c.reading (BOOLEAN)
    \* Per-caller state machine:
    \*   "idle"        -> not started
    \*   "waiting"     -> blocked in lockTurn (conn_sync.go:191)
    \*   "acquired"    -> passed lockTurn, about to WriteRequest (line 209-211)
    \*   "after_write" -> WriteRequest succeeded, about to check ctx.Err() (line 215)
    \*   "reading_msg" -> holding reading=TRUE, calling ReadMessage() (line 222)
    \*   "in_notif"    -> released reading=FALSE & mu, running HandleNotification (line 248)
    \*   "done_ok"     -> Call returned (result, nil)
    \*   "done_cancel" -> Call returned (nil, ctx.Err())
    pc,
    ctxCancelled, \* [Callers -> BOOLEAN]
    gotResult,    \* [Callers -> {"none", "G1", "G2"}]
    \* Wire queues (server -> peer requests; peer -> server messages)
    toPeer,       \* Seq of caller IDs ("G1" | "G2")
    fromPeer,     \* Seq of records [kind |-> "notif" | "resp", payload |-> "none" | "G1" | "G2"]
    peerSentNotif,\* BOOLEAN (peer sends at most one notification before G1's response)
    runError      \* BOOLEAN (Run() received an unexpected response, conn_sync.go:81)

vars == <<calls, reading, pc, ctxCancelled, gotResult, toPeer, fromPeer, peerSentNotif, runError>>

TypeOK ==
    /\ calls \in 0..2
    /\ reading \in BOOLEAN
    /\ pc \in [Callers -> {"idle", "waiting", "acquired", "after_write", "reading_msg", "in_notif", "done_ok", "done_cancel"}]
    /\ ctxCancelled \in [Callers -> BOOLEAN]
    /\ gotResult \in [Callers -> {"none", "G1", "G2"}]
    /\ peerSentNotif \in BOOLEAN
    /\ runError \in BOOLEAN

Init ==
    /\ calls = 0
    /\ reading = FALSE
    /\ pc = [g \in Callers |-> "idle"]
    /\ ctxCancelled = [g \in Callers |-> IF Mode = "CancelOrphan" /\ g = "G1" THEN TRUE ELSE FALSE]
    /\ gotResult = [g \in Callers |-> "none"]
    /\ toPeer = <<>>
    /\ fromPeer = <<>>
    /\ peerSentNotif = FALSE
    /\ runError = FALSE

\* Caller g enters Call() and blocks in lockTurn (conn_sync.go:187-194).
StartCall(g) ==
    /\ pc[g] = "idle"
    \* In CancelOrphan mode, G1 starts first with a cancelled ctx; G2 can run after or Run() can read.
    /\ (Mode = "CancelOrphan" => (g = "G1" \/ pc["G1"] = "done_cancel"))
    /\ pc' = [pc EXCEPT ![g] = "waiting"]
    /\ UNCHANGED <<calls, reading, ctxCancelled, gotResult, toPeer, fromPeer, peerSentNotif, runError>>

\* lockTurn succeeds when reading == FALSE (conn_sync.go:191-194).
AcquireTurn(g) ==
    /\ pc[g] = "waiting"
    /\ reading = FALSE
    /\ calls' = calls + 1
    /\ reading' = TRUE
    /\ pc' = [pc EXCEPT ![g] = "acquired"]
    /\ UNCHANGED <<ctxCancelled, gotResult, toPeer, fromPeer, peerSentNotif, runError>>

\* WriteRequest sends Request(id=method, params=g) onto the wire BEFORE checking ctx.Err() (conn_sync.go:211).
WriteRequest(g) ==
    /\ pc[g] = "acquired"
    /\ toPeer' = Append(toPeer, g)
    /\ pc' = [pc EXCEPT ![g] = "after_write"]
    /\ UNCHANGED <<calls, reading, ctxCancelled, gotResult, fromPeer, peerSentNotif, runError>>

\* Post-WriteRequest ctx.Err() check (conn_sync.go:215-217).
CheckCtxAfterWrite(g) ==
    /\ pc[g] = "after_write"
    /\ IF ctxCancelled[g]
       THEN \* Returns ctx.Err() WITHOUT reading peer's response; defer decrements calls & clears reading.
            /\ calls' = calls - 1
            /\ reading' = FALSE
            /\ pc' = [pc EXCEPT ![g] = "done_cancel"]
       ELSE
            /\ pc' = [pc EXCEPT ![g] = "reading_msg"]
            /\ UNCHANGED <<calls, reading>>
    /\ UNCHANGED <<ctxCancelled, gotResult, toPeer, fromPeer, peerSentNotif, runError>>

\* Peer receives a request from toPeer and responds.
\* In NotificationSwap mode, peer may emit a fire-and-forget notification before G1's response.
PeerSendNotifAndResp ==
    /\ Mode = "NotificationSwap"
    /\ Len(toPeer) > 0
    /\ Head(toPeer) = "G1"
    /\ peerSentNotif = FALSE
    /\ toPeer' = Tail(toPeer)
    /\ fromPeer' = Append(Append(fromPeer, [kind |-> "notif", payload |-> "none"]),
                                           [kind |-> "resp",  payload |-> "G1"])
    /\ peerSentNotif' = TRUE
    /\ UNCHANGED <<calls, reading, pc, ctxCancelled, gotResult, runError>>

PeerSendResp ==
    /\ Len(toPeer) > 0
    /\ LET req == Head(toPeer) IN
       /\ toPeer' = Tail(toPeer)
       /\ fromPeer' = Append(fromPeer, [kind |-> "resp", payload |-> req])
    /\ UNCHANGED <<calls, reading, pc, ctxCancelled, gotResult, peerSentNotif, runError>>

\* Caller g reads the next message off the wire (conn_sync.go:222-254).
ReadMessage(g) ==
    /\ pc[g] = "reading_msg"
    /\ Len(fromPeer) > 0
    /\ LET msg == Head(fromPeer) IN
       /\ fromPeer' = Tail(fromPeer)
       /\ IF msg.kind = "resp"
          THEN \* Matches msg.ID.String() == method (conn_sync.go:225): accepts ANY same-method response!
               /\ gotResult' = [gotResult EXCEPT ![g] = msg.payload]
               /\ pc' = [pc EXCEPT ![g] = "done_ok"]
               /\ calls' = calls - 1
               /\ reading' = FALSE
          ELSE \* msg.kind = "notif" (conn_sync.go:244-251): clears reading=FALSE, broadcasts turn, unlocks mu!
               /\ reading' = FALSE
               /\ pc' = [pc EXCEPT ![g] = "in_notif"]
               /\ UNCHANGED <<calls, gotResult>>
    /\ UNCHANGED <<ctxCancelled, toPeer, peerSentNotif, runError>>

\* Notification handler finishes and re-acquires reading turn (conn_sync.go:248-251).
\* Note: conn_sync.go:250 waits only while c.reading || c.calls > depth; once G2 finishes
\* its Call (calls returns to 1), G1 resumes reading.
FinishNotifAndResume(g) ==
    /\ pc[g] = "in_notif"
    /\ reading = FALSE
    /\ calls = 1
    /\ reading' = TRUE
    /\ pc' = [pc EXCEPT ![g] = "reading_msg"]
    /\ UNCHANGED <<calls, ctxCancelled, gotResult, toPeer, fromPeer, peerSentNotif, runError>>

\* Run() loop reads when no Call is reading (conn_sync.go:63-83).
\* If it reads a response message, conn_sync.go:81 returns
\* "ipc: unexpected response message in sync connection", permanently killing the connection.
RunLoopRead ==
    /\ calls = 0
    /\ reading = FALSE
    /\ Len(fromPeer) > 0
    /\ LET msg == Head(fromPeer) IN
       /\ fromPeer' = Tail(fromPeer)
       /\ IF msg.kind = "resp"
          THEN runError' = TRUE
          ELSE UNCHANGED runError
    /\ UNCHANGED <<calls, reading, pc, ctxCancelled, gotResult, toPeer, peerSentNotif>>

Next ==
    \/ \E g \in Callers :
        \/ StartCall(g)
        \/ AcquireTurn(g)
        \/ WriteRequest(g)
        \/ CheckCtxAfterWrite(g)
        \/ ReadMessage(g)
        \/ FinishNotifAndResume(g)
    \/ PeerSendNotifAndResp
    \/ PeerSendResp
    \/ RunLoopRead

Spec == Init /\ [][Next]_vars

\* INVARIANT 1 (NotificationSwap):
\* Every caller that completes Call() with err == nil must receive the response
\* corresponding to its own request, never another caller's response.
NoCrossCallResponseSwap ==
    \A g \in Callers :
        pc[g] = "done_ok" => gotResult[g] = g

\* INVARIANT 2 (CancelOrphan):
\* A cancelled Call() must never orphan a response on the wire that kills Run()
\* or gets silently delivered to a subsequent Call().
NoOrphanedResponsePoison ==
    /\ runError = FALSE
    /\ NoCrossCallResponseSwap

=============================================================================
