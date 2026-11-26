------------------------- MODULE FSWatchLifecycle -------------------------
EXTENDS Integers, FiniteSets

\* Faithful model of tsc/internal/fswatch/watcher.go:
\*   - WatchDirectories (lines 469-585):
\*       getOrCreateDirWatch (acquires & releases w.mu) ->
\*       dw.addCallback (acquires & releases dw.mu) ->
\*       impl.watchAddMany (acquires & releases b.mu)
\*   - watch.Close (lines 629-643):
\*       dw.unwatch (acquires & releases dw.mu, returns last = len(callbacks)==0) ->
\*       if last: impl.watchRemove(dw) (acquires & releases b.mu) ->
\*       if last: dw.unref(w) -> locks/unlocks dw.mu checking empty ->
\*                if empty: w.removeDirWatch(dw) (locks w.mu, deletes w.dirWatches[key],
\*                          calls dw.destroyDebounce() setting dw.debounce = nil)
\*
\* We model 2 handles (h1 starts live on dw1; h2 concurrently opens on the same dir
\* while h1 concurrently closes) with up to 2 dirWatch instances (DW = {1, 2}).

CONSTANTS
    DWs \* e.g. {1, 2}

VARIABLES
    \* w.dirWatches[dir]: 0 means absent, else dw \in DWs
    regDW,
    \* next fresh dirWatch id to allocate
    nextDW,
    \* Per-dirWatch state:
    dwCallbacks,    \* [DWs -> SUBSET {"h1", "h2"}]
    dwDebounce,     \* [DWs -> BOOLEAN] (TRUE while dw.debounce != nil and in debounce.callbacks)
    osSubscribed,   \* [DWs -> BOOLEAN] (TRUE while dw is in watcherBase.subscriptions)
    \* Handle 1 (closer) state:
    h1PC,           \* "live" | "unwatched" | "os_removed" | "unref_empty" | "closed"
    h1DW,           \* DW owned by h1
    \* Handle 2 (opener) state:
    h2PC,           \* "idle" | "got_dw" | "added_cb" | "live"
    h2DW            \* 0 or DW acquired by h2

vars == <<regDW, nextDW, dwCallbacks, dwDebounce, osSubscribed, h1PC, h1DW, h2PC, h2DW>>

Init ==
    /\ regDW = 1
    /\ nextDW = 2
    /\ dwCallbacks = [d \in DWs |-> IF d = 1 THEN {"h1"} ELSE {}]
    /\ dwDebounce = [d \in DWs |-> (d = 1)]
    /\ osSubscribed = [d \in DWs |-> (d = 1)]
    /\ h1PC = "live"
    /\ h1DW = 1
    /\ h2PC = "idle"
    /\ h2DW = 0

\* --- Handle 1: watch.Close() (watcher.go:629-643) ---

\* Line 636: last := s.dw.unwatch(s.id)
H1Unwatch ==
    /\ h1PC = "live"
    /\ LET rem == dwCallbacks[h1DW] \ {"h1"} IN
       /\ dwCallbacks' = [dwCallbacks EXCEPT ![h1DW] = rem]
       /\ h1PC' = IF rem = {} THEN "unwatched" ELSE "closed"
    /\ UNCHANGED <<regDW, nextDW, dwDebounce, osSubscribed, h1DW, h2PC, h2DW>>

\* Line 638: if last { s.impl.watchRemove(s.dw) }
H1WatchRemove ==
    /\ h1PC = "unwatched"
    /\ osSubscribed' = [osSubscribed EXCEPT ![h1DW] = FALSE]
    /\ h1PC' = "os_removed"
    /\ UNCHANGED <<regDW, nextDW, dwCallbacks, dwDebounce, h1DW, h2PC, h2DW>>

\* Line 639 -> 1170-1174: dw.unref(w) checks len(dw.callbacks) == 0 under dw.mu, then releases dw.mu
H1UnrefCheck ==
    /\ h1PC = "os_removed"
    /\ h1PC' = IF dwCallbacks[h1DW] = {} THEN "unref_empty" ELSE "closed"
    /\ UNCHANGED <<regDW, nextDW, dwCallbacks, dwDebounce, osSubscribed, h1DW, h2PC, h2DW>>

\* Line 1175 -> 458-466: w.removeDirWatch(dw) acquires w.mu, deletes if regDW == dw, calls dw.destroyDebounce()
H1RemoveDirWatch ==
    /\ h1PC = "unref_empty"
    /\ IF regDW = h1DW THEN
         /\ regDW' = 0
         /\ dwDebounce' = [dwDebounce EXCEPT ![h1DW] = FALSE]
       ELSE
         /\ UNCHANGED <<regDW, dwDebounce>>
    /\ h1PC' = "closed"
    /\ UNCHANGED <<nextDW, dwCallbacks, osSubscribed, h1DW, h2PC, h2DW>>

\* --- Handle 2: WatchDirectories() (watcher.go:539-578) ---

\* Line 539: dw, err := w.getOrCreateDirWatch(dir, ...) (under w.mu, then releases w.mu)
H2GetOrCreate ==
    /\ h2PC = "idle"
    /\ IF regDW /= 0 THEN
         /\ h2DW' = regDW
         /\ UNCHANGED <<regDW, nextDW, dwDebounce>>
       ELSE
         /\ nextDW \in DWs
         /\ regDW' = nextDW
         /\ h2DW' = nextDW
         /\ dwDebounce' = [dwDebounce EXCEPT ![nextDW] = TRUE]
         /\ nextDW' = nextDW + 1
    /\ h2PC' = "got_dw"
    /\ UNCHANGED <<dwCallbacks, osSubscribed, h1PC, h1DW>>

\* Line 544: id, _ := dw.addCallback(...) (under dw.mu)
H2AddCallback ==
    /\ h2PC = "got_dw"
    /\ dwCallbacks' = [dwCallbacks EXCEPT ![h2DW] = @ \cup {"h2"}]
    /\ h2PC' = "added_cb"
    /\ UNCHANGED <<regDW, nextDW, dwDebounce, osSubscribed, h1PC, h1DW, h2DW>>

\* Line 558: impl.watchAddMany(uniqueDirWatches) (under b.mu)
H2WatchAdd ==
    /\ h2PC = "added_cb"
    /\ osSubscribed' = [osSubscribed EXCEPT ![h2DW] = TRUE]
    /\ h2PC' = "live"
    /\ UNCHANGED <<regDW, nextDW, dwCallbacks, dwDebounce, h1PC, h1DW, h2DW>>

DoneStutter ==
    /\ h1PC = "closed"
    /\ h2PC = "live"
    /\ UNCHANGED vars

Next ==
    \/ H1Unwatch
    \/ H1WatchRemove
    \/ H1UnrefCheck
    \/ H1RemoveDirWatch
    \/ H2GetOrCreate
    \/ H2AddCallback
    \/ H2WatchAdd
    \/ DoneStutter

\* --- Safety Invariants ---

\* Once H2 returns a live Watch (and H1 has finished closing), H2's dirWatch MUST still
\* have an active debouncer, an active OS subscription, and a live registry entry.

LiveWatchHasDebounce ==
    (h2PC = "live" /\ h1PC = "closed") => dwDebounce[h2DW] = TRUE

LiveWatchHasOSSubscription ==
    (h2PC = "live" /\ h1PC = "closed") => osSubscribed[h2DW] = TRUE

LiveWatchInRegistry ==
    (h2PC = "live" /\ h1PC = "closed") => regDW = h2DW

=============================================================================
