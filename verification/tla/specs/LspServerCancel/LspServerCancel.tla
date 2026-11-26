------------------------- MODULE LspServerCancel -------------------------
EXTENDS Integers, Sequences

\* Faithful model of tsc/internal/lsp/server.go:
\* - UseFix = FALSE: readLoop puts normal requests in requestQueue without registering
\*   pendingClientRequests; $/cancelRequest checks pendingClientRequests immediately and misses.
\* - UseFix = TRUE:  readLoop registers pendingClientRequests[id] = "queued" BEFORE Put;
\*   $/cancelRequest marks "queued_canceled" (or cancels "active" and deletes);
\*   dispatchLoop checks pendingClientRequests on Pop and immediately returns RequestCancelled
\*   without running the handler if "queued_canceled".

CONSTANTS
    Reqs,   \* e.g. {1, 2}
    UseFix  \* BOOLEAN

VARIABLES
    wireQueue,        \* Sequence of messages from client: [kind: "req"|"cancel", id: Reqs \cup {99}]
    requestQueue,     \* Sequence of req IDs in s.requestQueue
    pendingMap,       \* [Reqs \cup {99} -> "absent" | "queued" | "queued_canceled" | "active" | "canceled"]
    dispatchPC,       \* "idle" | "busy"
    dispatchReq,      \* 0 or Reqs currently being dispatched
    clientCanceled,   \* SUBSET (Reqs \cup {99}): requests for which client sent $/cancelRequest
    canceledInQueue,  \* SUBSET Reqs: requests whose $/cancelRequest arrived while still queued
    ranUncanceled,    \* SUBSET Reqs: requests that entered handler uncanceled AFTER cancel processed
    respondedCancel   \* SUBSET Reqs: requests that returned RequestCancelled

AllIDs == Reqs \cup {99}

vars == <<wireQueue, requestQueue, pendingMap, dispatchPC, dispatchReq,
          clientCanceled, canceledInQueue, ranUncanceled, respondedCancel>>

\* Client sends req 1, req 2, $/cancelRequest(2), duplicate $/cancelRequest(2), and unknown $/cancelRequest(99).
Init ==
    /\ wireQueue = << [kind |-> "req", id |-> 1],
                      [kind |-> "req", id |-> 2],
                      [kind |-> "cancel", id |-> 2],
                      [kind |-> "cancel", id |-> 2],
                      [kind |-> "cancel", id |-> 99] >>
    /\ requestQueue = << >>
    /\ pendingMap = [r \in AllIDs |-> "absent"]
    /\ dispatchPC = "idle"
    /\ dispatchReq = 0
    /\ clientCanceled = {}
    /\ canceledInQueue = {}
    /\ ranUncanceled = {}
    /\ respondedCancel = {}

\* readLoop reads next message from wire
ReadLoopStep ==
    /\ Len(wireQueue) > 0
    /\ LET msg == Head(wireQueue) IN
       /\ wireQueue' = Tail(wireQueue)
       /\ IF msg.kind = "req"
          THEN /\ requestQueue' = Append(requestQueue, msg.id)
               /\ IF UseFix
                  THEN pendingMap' = [pendingMap EXCEPT ![msg.id] = "queued"]
                  ELSE UNCHANGED pendingMap
               /\ UNCHANGED <<clientCanceled, canceledInQueue>>
          ELSE \* $/cancelRequest: bypasses requestQueue, checks pendingClientRequests immediately
               /\ clientCanceled' = clientCanceled \cup {msg.id}
               /\ IF pendingMap[msg.id] = "active"
                  THEN /\ pendingMap' = [pendingMap EXCEPT ![msg.id] = "canceled"]
                       /\ UNCHANGED canceledInQueue
                  ELSE IF UseFix /\ pendingMap[msg.id] = "queued"
                  THEN /\ pendingMap' = [pendingMap EXCEPT ![msg.id] = "queued_canceled"]
                       /\ canceledInQueue' = canceledInQueue \cup {msg.id}
                  ELSE UNCHANGED <<pendingMap, canceledInQueue>>
               /\ UNCHANGED requestQueue
    /\ UNCHANGED <<dispatchPC, dispatchReq, ranUncanceled, respondedCancel>>

\* dispatchLoop pops next request from requestQueue
DispatchPop ==
    /\ dispatchPC = "idle"
    /\ Len(requestQueue) > 0
    /\ LET r == Head(requestQueue) IN
       /\ requestQueue' = Tail(requestQueue)
       /\ IF UseFix /\ pendingMap[r] = "queued_canceled"
          THEN \* Already canceled while queued: delete entry, send RequestCancelled, skip handler!
               /\ pendingMap' = [pendingMap EXCEPT ![r] = "absent"]
               /\ respondedCancel' = respondedCancel \cup {r}
               /\ UNCHANGED <<dispatchPC, dispatchReq, ranUncanceled>>
          ELSE /\ pendingMap' = [pendingMap EXCEPT ![r] = "active"]
               /\ dispatchReq' = r
               /\ dispatchPC' = "busy"
               /\ ranUncanceled' = IF r \in clientCanceled THEN ranUncanceled \cup {r} ELSE ranUncanceled
               /\ UNCHANGED respondedCancel
    /\ UNCHANGED <<wireQueue, clientCanceled, canceledInQueue>>

\* dispatchLoop finishes handling current request and removes it from pendingClientRequests
DispatchFinish ==
    /\ dispatchPC = "busy"
    /\ LET r == dispatchReq IN
       /\ respondedCancel' = IF pendingMap[r] = "canceled" THEN respondedCancel \cup {r} ELSE respondedCancel
       /\ pendingMap' = [pendingMap EXCEPT ![r] = "absent"]
       /\ dispatchReq' = 0
       /\ dispatchPC' = "idle"
    /\ UNCHANGED <<wireQueue, requestQueue, clientCanceled, canceledInQueue, ranUncanceled>>

AllDone ==
    /\ Len(wireQueue) = 0
    /\ Len(requestQueue) = 0
    /\ dispatchPC = "idle"
    /\ UNCHANGED vars

Next ==
    \/ ReadLoopStep
    \/ DispatchPop
    \/ DispatchFinish
    \/ AllDone

\* Safety 1: a request whose $/cancelRequest was already processed by readLoop
\* must NOT later start executing with an uncanceled context.
NoDroppedCancellation == ranUncanceled = {}

\* Safety 2: unknown cancel IDs (99) are never stored in pendingClientRequests,
\* and at quiescence pendingClientRequests is completely empty (no leaks).
NoLeakedPendingEntries ==
    /\ pendingMap[99] = "absent"
    /\ ((Len(wireQueue) = 0 /\ Len(requestQueue) = 0 /\ dispatchPC = "idle") =>
        \A r \in AllIDs : pendingMap[r] = "absent")

\* Safety 3: every request canceled while queued responds with RequestCancelled at quiescence.
CanceledRequestRespondsCancelled ==
    (Len(wireQueue) = 0 /\ Len(requestQueue) = 0 /\ dispatchPC = "idle") => (canceledInQueue \subseteq respondedCancel)

=============================================================================
