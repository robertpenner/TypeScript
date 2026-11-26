---------------------------- MODULE SymbolCache ----------------------------
(***************************************************************************)
(* Formal specification of the parallel type-checker symbol cache and      *)
(* epoch-based invalidation protocol.                                      *)
(*                                                                         *)
(* Isolates version coherence, stale write-back (ABA) races, stale cache   *)
(* reads, and cross-symbol torn snapshots across concurrent worker         *)
(* goroutines and workspace file edits.                                    *)
(***************************************************************************)

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Checkers,       \* Set of concurrent type-checker worker IDs (model values for symmetry)
    Symbols,        \* Set of symbols in the workspace (e.g. {"s1", "s2"})
    MaxVer,         \* Maximum source version per symbol
    UseEpochGuard   \* BOOLEAN: FALSE = buggy unguarded protocol, TRUE = epoch-guarded protocol

ASSUME
    /\ IsFiniteSet(Checkers) /\ Checkers # {}
    /\ IsFiniteSet(Symbols)  /\ Symbols  # {}
    /\ MaxVer \in Nat /\ MaxVer >= 2
    /\ UseEpochGuard \in BOOLEAN

\* Sentinel values for empty cache entries and unset symbol references
\* Note: EMPTY uses the same record shape as populated cache entries so that
\* TLC can safely compare cache[s] = EMPTY and check TypeOK without type errors.
EMPTY == [ver |-> 0, ep |-> 0]
NONE  == "NONE"

\* Maximum reachable workspace epoch: starts at 1, increments once per FileEdit
MaxEpoch == 1 + Cardinality(Symbols) * (MaxVer - 1)

\* Symmetry set over worker identities (used via SYMMETRY Symmetry in .cfg)
Symmetry == Permutations(Checkers)

VARIABLES
    sourceVer,      \* [Symbols -> 1..MaxVer]: authoritative source version of each symbol
    epoch,          \* 1..MaxEpoch: monotonically increasing global workspace epoch
    cache,          \* [Symbols -> {EMPTY} \cup [ver: 1..MaxVer, ep: 1..MaxEpoch]]
    wState          \* Per-worker state record (pc, sym, snapEp, observed, dep, depVer, depEp)

vars == <<sourceVer, epoch, cache, wState>>

-----------------------------------------------------------------------------
(* Type Invariant *)

CacheEntry == [ver : 1..MaxVer, ep : 1..MaxEpoch]

WorkerRecord ==
    [pc       : {"Idle", "Computing", "Done"},
     sym      : Symbols \cup {NONE},
     snapEp   : 0..MaxEpoch,
     observed : 0..MaxVer,
     dep      : Symbols \cup {NONE},
     depVer   : 0..MaxVer,
     depEp    : 0..MaxEpoch]

TypeOK ==
    /\ sourceVer \in [Symbols -> 1..MaxVer]
    /\ epoch \in 1..MaxEpoch
    /\ cache \in [Symbols -> {EMPTY} \cup CacheEntry]
    /\ wState \in [Checkers -> WorkerRecord]

-----------------------------------------------------------------------------
(* Initial State *)

Init ==
    /\ sourceVer = [s \in Symbols |-> 1]
    /\ epoch = 1
    /\ cache = [s \in Symbols |-> EMPTY]
    /\ wState = [w \in Checkers |->
                    [pc       |-> "Idle",
                     sym      |-> NONE,
                     snapEp   |-> 0,
                     observed |-> 0,
                     dep      |-> NONE,
                     depVer   |-> 0,
                     depEp    |-> 0]]

-----------------------------------------------------------------------------
(* Actions *)

\* StartLookup(w, s):
\*   Idle worker w looks up symbol s in the shared cache.
\*   - Cache hit: transitions immediately to Done with the cached version.
\*     Under UseEpochGuard = TRUE, only entries matching the current epoch
\*     are valid hits (stale-epoch entries trigger recomputation).
\*   - Cache miss: captures the current workspace epoch and source version
\*     and transitions to Computing.
StartLookup(w, s) ==
    /\ wState[w].pc = "Idle"
    /\ IF cache[s] # EMPTY /\ (~UseEpochGuard \/ cache[s].ep = epoch)
       THEN wState' = [wState EXCEPT ![w] =
                          [pc       |-> "Done",
                           sym      |-> s,
                           snapEp   |-> epoch,
                           observed |-> cache[s].ver,
                           dep      |-> NONE,
                           depVer   |-> 0,
                           depEp    |-> 0]]
       ELSE wState' = [wState EXCEPT ![w] =
                          [pc       |-> "Computing",
                           sym      |-> s,
                           snapEp   |-> epoch,
                           observed |-> sourceVer[s],
                           dep      |-> NONE,
                           depVer   |-> 0,
                           depEp    |-> 0]]
    /\ UNCHANGED <<sourceVer, epoch, cache>>

\* ReadDependency(w, dep):
\*   Computing worker w resolving wState[w].sym fetches a dependent symbol dep
\*   from the shared cache.
\*   - UseEpochGuard = FALSE: reads any populated cache entry without checking
\*     epoch coherence, exposing cross-epoch torn snapshots.
\*   - UseEpochGuard = TRUE: validates that the workspace epoch has not advanced
\*     and that the cached dependency originates from the same snapshot epoch.
ReadDependency(w, dep) ==
    /\ wState[w].pc = "Computing"
    /\ wState[w].dep = NONE
    /\ dep # wState[w].sym
    /\ cache[dep] # EMPTY
    /\ UseEpochGuard => (wState[w].snapEp = epoch /\ cache[dep].ep = wState[w].snapEp)
    /\ wState' = [wState EXCEPT ![w].dep    = dep,
                                ![w].depVer = cache[dep].ver,
                                ![w].depEp  = cache[dep].ep]
    /\ UNCHANGED <<sourceVer, epoch, cache>>

\* PublishResult(w):
\*   Computing worker w finishes type-checking and attempts to publish its result.
\*   - UseEpochGuard = FALSE: unconditionally writes back to the shared cache
\*     (models unguarded store / ABA stale write-back after concurrent FileEdit).
\*   - UseEpochGuard = TRUE: guarded CAS commit that writes to the shared cache
\*     only if snapEp = epoch; otherwise discards the stale write-back cleanly.
PublishResult(w) ==
    /\ wState[w].pc = "Computing"
    /\ IF ~UseEpochGuard \/ wState[w].snapEp = epoch
       THEN cache' = [cache EXCEPT ![wState[w].sym] =
                         [ver |-> wState[w].observed,
                          ep  |-> wState[w].snapEp]]
       ELSE UNCHANGED cache
    /\ wState' = [wState EXCEPT ![w].pc = "Done"]
    /\ UNCHANGED <<sourceVer, epoch>>

\* FileEdit(s):
\*   External workspace edit increments symbol s's source version, advances
\*   the global workspace epoch, and clears the invalidated cache entry.
FileEdit(s) ==
    /\ sourceVer[s] < MaxVer
    /\ sourceVer' = [sourceVer EXCEPT ![s] = @ + 1]
    /\ epoch' = epoch + 1
    /\ cache' = [cache EXCEPT ![s] = EMPTY]
    /\ UNCHANGED wState

\* ResetWorker(w):
\*   Returns a Done worker to Idle to model cyclical worker reuse.
ResetWorker(w) ==
    /\ wState[w].pc = "Done"
    /\ wState' = [wState EXCEPT ![w] =
                     [pc       |-> "Idle",
                      sym      |-> NONE,
                      snapEp   |-> 0,
                      observed |-> 0,
                      dep      |-> NONE,
                      depVer   |-> 0,
                      depEp    |-> 0]]
    /\ UNCHANGED <<sourceVer, epoch, cache>>

-----------------------------------------------------------------------------
(* Next-State Relation and Temporal Specification *)

Next ==
    \/ \E w \in Checkers, s \in Symbols : StartLookup(w, s)
    \/ \E w \in Checkers, dep \in Symbols : ReadDependency(w, dep)
    \/ \E w \in Checkers : PublishResult(w)
    \/ \E s \in Symbols : FileEdit(s)
    \/ \E w \in Checkers : ResetWorker(w)

\* Weak fairness on Next plus per-worker weak fairness on PublishResult(w)
\* (models Go's preemptive scheduler so an idle/cycling worker cannot starve
\* a computing worker indefinitely).
Fairness ==
    /\ WF_vars(Next)
    /\ \A w \in Checkers : WF_vars(PublishResult(w))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Safety Invariants *)

\* 1. NoStaleCacheEntry:
\*    The shared cache never stores a version older than (or differing from) sourceVer[s].
NoStaleCacheEntry ==
    \A s \in Symbols :
        cache[s] # EMPTY => cache[s].ver = sourceVer[s]

\* 2. NoStaleRead:
\*    A worker completing a check at the current workspace epoch never observes
\*    stale cached data.
NoStaleRead ==
    \A w \in Checkers :
        (wState[w].pc = "Done" /\ wState[w].snapEp = epoch) =>
            wState[w].observed = sourceVer[wState[w].sym]

\* 3. NoTornSnapshot:
\*    If a worker reads both its target symbol and a dependent symbol, both
\*    observed values must originate from the same epoch (and match the source
\*    version when still at the current epoch).
NoTornSnapshot ==
    \A w \in Checkers :
        wState[w].dep # NONE =>
            /\ wState[w].depEp = wState[w].snapEp
            /\ (wState[w].snapEp = epoch => wState[w].depVer = sourceVer[wState[w].dep])

-----------------------------------------------------------------------------
(* Liveness Property *)

\* WorkersMakeProgress:
\*    Under fairness, every computing worker eventually terminates cleanly.
WorkersMakeProgress ==
    \A w \in Checkers :
        (wState[w].pc = "Computing") ~> (wState[w].pc = "Done")

=============================================================================
