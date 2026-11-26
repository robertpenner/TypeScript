------------------------- MODULE LspServerCancel -------------------------
EXTENDS Integers, Sequences

\* Faithful model of tsc/internal/lsp/server.go:
\* - readLoop (lines 994-1005): puts normal requests in requestQueue, but handles
\*   $/cancelRequest immediately by calling s.cancelRequest(id) against pendingClientRequests.
\* - dispatchLoop (lines 1025-1075): pops from requestQueue, inserts into pendingClientRequests,
\*   and executes the handler.

CONSTANTS
    Reqs \* e.g. {1, 2}

VARIABLES
    wireQueue,        \* Sequence of messages from client: [kind: "req"|"cancel", id: Reqs]
    requestQueue,     \* Sequence of req IDs in s.requestQueue
    pendingMap,       \* [Reqs -> "absent" | "active" | "canceled"] (s.pendingClientRequests)
    dispatchPC,       \* "idle" | "busy"
    dispatchReq,      \* 0 or Reqs currently being dispatched
    \* Ghost tracking
    clientCanceled,   \* SUBSET Reqs: requests for which client sent $/cancelRequest
    ranUncanceled     \* SUBSET Reqs: requests that entered handler with uncanceled ctx AFTER cancel was processed

vars == <<wireQueue, requestQueue, pendingMap, dispatchPC, dispatchReq,
          clientCanceled, ranUncanceled>>

\* Client sends req 1, req 2, then $/cancelRequest(2) in order on the LSP wire.
Init ==
    /\ wireQueue = << [kind |-> "req", id |-> 1],
                      [kind |-> "req", id |-> 2],
                      [kind |-> "cancel", id |-> 2] >>
    /\ requestQueue = << >>
    /\ pendingMap = [r \in Reqs |-> "absent"]
    /\ dispatchPC = "idle"
    /\ dispatchReq = 0
    /\ clientCanceled = {}
    /\ ranUncanceled = {}

\* readLoop reads next message from wire
ReadLoopStep ==
    /\ Len(wireQueue) > 0
    /\ LET msg == Head(wireQueue) IN
       /\ wireQueue' = Tail(wireQueue)
       /\ IF msg.kind = "req"
          THEN /\ requestQueue' = Append(requestQueue, msg.id)
               /\ UNCHANGED <<pendingMap, clientCanceled>>
          ELSE \* $/cancelRequest: bypasses requestQueue, checks pendingClientRequests immediately!
               /\ clientCanceled' = clientCanceled \cup {msg.id}
               /\ IF pendingMap[msg.id] = "active"
                  THEN pendingMap' = [pendingMap EXCEPT ![msg.id] = "canceled"]
                  ELSE UNCHANGED pendingMap \* SILENTLY DROPPED because req is still in requestQueue!
               /\ UNCHANGED requestQueue
    /\ UNCHANGED <<dispatchPC, dispatchReq, ranUncanceled>>

\* dispatchLoop pops next request from requestQueue and registers it in pendingClientRequests
DispatchPop ==
    /\ dispatchPC = "idle"
    /\ Len(requestQueue) > 0
    /\ LET r == Head(requestQueue) IN
       /\ requestQueue' = Tail(requestQueue)
       /\ pendingMap' = [pendingMap EXCEPT ![r] = "active"]
       /\ dispatchReq' = r
       /\ dispatchPC' = "busy"
       \* If $/cancelRequest(r) was ALREADY processed by readLoop before dispatchLoop popped r,
       \* r starts executing with an UNCANCELED context!
       /\ ranUncanceled' = IF r \in clientCanceled THEN ranUncanceled \cup {r} ELSE ranUncanceled
    /\ UNCHANGED <<wireQueue, clientCanceled>>

\* dispatchLoop finishes handling current request and removes it from pendingClientRequests
DispatchFinish ==
    /\ dispatchPC = "busy"
    /\ LET r == dispatchReq IN
       /\ pendingMap' = [pendingMap EXCEPT ![r] = "absent"]
       /\ dispatchReq' = 0
       /\ dispatchPC' = "idle"
    /\ UNCHANGED <<wireQueue, requestQueue, clientCanceled, ranUncanceled>>

Next ==
    \/ ReadLoopStep
    \/ DispatchPop
    \/ DispatchFinish

\* Safety invariant: a request whose $/cancelRequest was already processed by readLoop
\* must NOT later start executing with an uncanceled context!
NoDroppedCancellation == ranUncanceled = {}

=============================================================================
