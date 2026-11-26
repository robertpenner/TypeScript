------------------------- MODULE FSWatchDebounce -------------------------
EXTENDS Integers, FiniteSets

\* Faithful model of tsc/internal/fswatch/debounce.go (lines 51-147):
\* add(key, cb), trigger(), loop() -> latchWait() -> notifyIfReady() -> fireCallbacks() -> latchReset() -> invoke cbs.

CONSTANTS
    Keys \* e.g. {"k1", "k2"}

VARIABLES
    registered,      \* SUBSET Keys: d.callbacks
    triggered,       \* SUBSET Keys: keys whose event has been triggered (needs callback invocation)
    delivered,       \* SUBSET Keys: keys whose callback ran AFTER its trigger
    \* Latch state
    notified,        \* BOOLEAN: d.notified
    \* Loop goroutine state
    loopPC,          \* "latch_wait" | "snapshotting" | "resetting_latch" | "running_cbs"
    snapCbs          \* SUBSET Keys: local cbs slice snapshotted in fireCallbacks()

vars == <<registered, triggered, delivered, notified, loopPC, snapCbs>>

Init ==
    /\ registered = {"k1"}
    /\ triggered = {}
    /\ delivered = {}
    /\ notified = FALSE
    /\ loopPC = "latch_wait"
    /\ snapCbs = {}

\* Register a new callback key (d.add(k, cb))
AddCallback(k) ==
    /\ k \notin registered
    /\ registered' = registered \cup {k}
    /\ UNCHANGED <<triggered, delivered, notified, loopPC, snapCbs>>

\* Event arrives for a registered key: calls d.trigger()
TriggerKey(k) ==
    /\ k \in registered
    /\ k \notin triggered
    /\ triggered' = triggered \cup {k}
    /\ notified' = TRUE
    /\ UNCHANGED <<registered, delivered, loopPC, snapCbs>>

\* d.latchWait() passes when notified == TRUE
LoopWake ==
    /\ loopPC = "latch_wait"
    /\ notified = TRUE
    /\ loopPC' = "snapshotting"
    /\ UNCHANGED <<registered, triggered, delivered, notified, snapCbs>>

\* fireCallbacks() lines 105-111: lock d.mu, snapshot d.callbacks, unlock d.mu
LoopSnapshot ==
    /\ loopPC = "snapshotting"
    /\ snapCbs' = registered
    /\ loopPC' = "resetting_latch"
    /\ UNCHANGED <<registered, triggered, delivered, notified>>

\* fireCallbacks() line 113: d.latchReset() -> notified = false
LoopLatchReset ==
    /\ loopPC = "resetting_latch"
    /\ notified' = FALSE
    /\ loopPC' = "running_cbs"
    /\ UNCHANGED <<registered, triggered, delivered, snapCbs>>

\* fireCallbacks() lines 115-117: invoke snapshotted callbacks
LoopRunCallbacks ==
    /\ loopPC = "running_cbs"
    /\ delivered' = delivered \cup (snapCbs \cap triggered)
    /\ snapCbs' = {}
    /\ loopPC' = "latch_wait"
    /\ UNCHANGED <<registered, triggered, notified>>

Next ==
    \/ \E k \in Keys : AddCallback(k) \/ TriggerKey(k)
    \/ LoopWake
    \/ LoopSnapshot
    \/ LoopLatchReset
    \/ LoopRunCallbacks

\* Safety at quiescence: if loop is asleep on latch_wait and notified is FALSE,
\* NO triggered key may remain undelivered!
NoLostTrigger ==
    (loopPC = "latch_wait" /\ ~notified) => (triggered \subseteq delivered)

=============================================================================
