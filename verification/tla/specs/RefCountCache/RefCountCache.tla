-------------------------- MODULE RefCountCache --------------------------
EXTENDS Integers, FiniteSets

CONSTANTS
    Workers,           \* Set of worker IDs, e.g. {"w1", "w2", "w3"}
    MaxEntries,        \* Bound on distinct entry allocations, e.g. 4
    DisableDeletion,   \* BOOLEAN: RefCountCacheOptions.DisableDeletion
    AllowConcurrentRef \* BOOLEAN: whether Ref() can race another worker's Deref()

EntryIds == 1..MaxEntries
NoEntry == 0
NoWorker == "NONE"

VARIABLES
    mapEntry,          \* Current entry in c.entries[key]: 0 or EntryIds
    nextEntryId,       \* Next fresh entry ID to allocate (1..MaxEntries+1)
    lock,              \* [EntryIds -> Workers \cup {NoWorker}]
    refCount,          \* [EntryIds -> Int]
    val,               \* [EntryIds -> 0..MaxEntries] (0 = zero value, >0 = parsed value)
    pc,                \* [Workers -> PCs]
    op,                \* [Workers -> {"none", "Acquire", "AcquireExisting", "AcquireOrError", "Ref", "Deref"}]
    curEntry,          \* [Workers -> 0..MaxEntries]
    savedEntry,        \* [Workers -> 0..MaxEntries] (old entry locked by Ref during resurrection)
    loaded,            \* [Workers -> BOOLEAN]
    heldCount,         \* [Workers -> 0..2] logical refs currently owned by worker
    heldVal,           \* [Workers -> 0..MaxEntries] value observed by worker on last acquire
    \* Ghost / bug-detection flags
    returnedZeroVal,   \* TRUE if an Acquire/AcquireExisting/AcquireOrError returned 0 without error
    overwroteLiveVal,  \* TRUE if Ref resurrection overwrote an existing live entry's distinct value
    deletedWrongEntry, \* TRUE if Delete(key) removed a different live entry from c.entries
    derefMissedMap,    \* TRUE if a legitimate holder's Deref found no entry in c.entries
    refPanicked        \* TRUE if Ref panicked with "cache entry not found"

vars == <<mapEntry, nextEntryId, lock, refCount, val, pc, op, curEntry, savedEntry,
          loaded, heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
          deletedWrongEntry, derefMissedMap, refPanicked>>

RECURSIVE SumHeld(_)
SumHeld(S) ==
    IF S = {} THEN 0
    ELSE LET w == CHOOSE x \in S : TRUE
         IN heldCount[w] + SumHeld(S \ {w})

TotalHeld == SumHeld(Workers)

Init ==
    /\ mapEntry = NoEntry
    /\ nextEntryId = 1
    /\ lock = [e \in EntryIds |-> NoWorker]
    /\ refCount = [e \in EntryIds |-> 0]
    /\ val = [e \in EntryIds |-> 0]
    /\ pc = [w \in Workers |-> "idle"]
    /\ op = [w \in Workers |-> "none"]
    /\ curEntry = [w \in Workers |-> NoEntry]
    /\ savedEntry = [w \in Workers |-> NoEntry]
    /\ loaded = [w \in Workers |-> FALSE]
    /\ heldCount = [w \in Workers |-> 0]
    /\ heldVal = [w \in Workers |-> 0]
    /\ returnedZeroVal = FALSE
    /\ overwroteLiveVal = FALSE
    /\ deletedWrongEntry = FALSE
    /\ derefMissedMap = FALSE
    /\ refPanicked = FALSE

\* --- Operation invocations ---

StartAcquire(w) ==
    /\ pc[w] = "idle"
    /\ heldCount[w] < 2
    /\ nextEntryId <= MaxEntries
    /\ op' = [op EXCEPT ![w] = "Acquire"]
    /\ pc' = [pc EXCEPT ![w] = "los_try"]
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, refCount, val, curEntry, savedEntry,
                   loaded, heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

StartAcquireOrError(w) ==
    /\ pc[w] = "idle"
    /\ heldCount[w] < 2
    /\ nextEntryId <= MaxEntries
    /\ op' = [op EXCEPT ![w] = "AcquireOrError"]
    /\ pc' = [pc EXCEPT ![w] = "los_try"]
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, refCount, val, curEntry, savedEntry,
                   loaded, heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

StartAcquireExisting(w) ==
    /\ pc[w] = "idle"
    /\ heldCount[w] < 2
    /\ op' = [op EXCEPT ![w] = "AcquireExisting"]
    /\ pc' = [pc EXCEPT ![w] = "ae_load"]
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, refCount, val, curEntry, savedEntry,
                   loaded, heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

StartDeref(w) ==
    /\ pc[w] = "idle"
    /\ heldCount[w] > 0
    /\ op' = [op EXCEPT ![w] = "Deref"]
    /\ pc' = [pc EXCEPT ![w] = "deref_load"]
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, refCount, val, curEntry, savedEntry,
                   loaded, heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

StartRef(w) ==
    /\ pc[w] = "idle"
    /\ heldCount[w] < 2
    /\ IF AllowConcurrentRef
       THEN \E u \in Workers : heldCount[u] > 0
       ELSE heldCount[w] > 0
    /\ op' = [op EXCEPT ![w] = "Ref"]
    /\ pc' = [pc EXCEPT ![w] = "ref_load"]
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, refCount, val, curEntry, savedEntry,
                   loaded, heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

\* --- loadOrStoreNewLockedEntry(key) ---

LosNextPC(w) ==
    CASE op[w] = "Acquire"        -> "acq_finish"
      [] op[w] = "AcquireOrError" -> "aoe_body"
      [] op[w] = "Ref"            -> "ref_resurrect_finish"

LosTryStore(w) ==
    /\ pc[w] = "los_try"
    /\ mapEntry = NoEntry
    /\ nextEntryId <= MaxEntries
    /\ LET e == nextEntryId IN
       /\ mapEntry' = e
       /\ nextEntryId' = nextEntryId + 1
       /\ lock' = [lock EXCEPT ![e] = w]
       /\ refCount' = [refCount EXCEPT ![e] = 1]
       /\ val' = [val EXCEPT ![e] = 0]
       /\ curEntry' = [curEntry EXCEPT ![w] = e]
       /\ loaded' = [loaded EXCEPT ![w] = FALSE]
       /\ pc' = [pc EXCEPT ![w] = LosNextPC(w)]
    /\ UNCHANGED <<op, savedEntry, heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

LosTryLoadExisting(w) ==
    /\ pc[w] = "los_try"
    /\ mapEntry # NoEntry
    /\ curEntry' = [curEntry EXCEPT ![w] = mapEntry]
    /\ loaded' = [loaded EXCEPT ![w] = TRUE]
    /\ pc' = [pc EXCEPT ![w] = "los_lock_existing"]
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, refCount, val, op, savedEntry,
                   heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

LosLockExisting(w) ==
    /\ pc[w] = "los_lock_existing"
    /\ LET e == curEntry[w] IN
       /\ lock[e] = NoWorker
       /\ IF refCount[e] <= 0 /\ ~DisableDeletion
          THEN \* Deleted while acquiring lock: unlock and retry
               /\ pc' = [pc EXCEPT ![w] = "los_try"]
               /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
               /\ UNCHANGED <<lock, refCount>>
          ELSE /\ lock' = [lock EXCEPT ![e] = w]
               /\ refCount' = [refCount EXCEPT ![e] = refCount[e] + 1]
               /\ pc' = [pc EXCEPT ![w] = LosNextPC(w)]
               /\ UNCHANGED curEntry
    /\ UNCHANGED <<mapEntry, nextEntryId, val, op, savedEntry, loaded,
                   heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

\* --- Acquire finish ---

AcquireFinish(w) ==
    /\ pc[w] = "acq_finish"
    /\ LET e == curEntry[w]
           newVal == IF ~loaded[w] THEN e ELSE val[e]
       IN
       /\ val' = IF ~loaded[w] THEN [val EXCEPT ![e] = e] ELSE val
       /\ lock' = [lock EXCEPT ![e] = NoWorker]
       /\ heldCount' = [heldCount EXCEPT ![w] = heldCount[w] + 1]
       /\ heldVal' = [heldVal EXCEPT ![w] = newVal]
       /\ returnedZeroVal' = (returnedZeroVal \/ newVal = 0)
       /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
       /\ op' = [op EXCEPT ![w] = "none"]
       /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<mapEntry, nextEntryId, refCount, savedEntry, loaded,
                   overwroteLiveVal, deletedWrongEntry, derefMissedMap, refPanicked>>

\* --- AcquireOrError body ---

AcquireOrErrorLoaded(w) ==
    /\ pc[w] = "aoe_body"
    /\ loaded[w] = TRUE
    /\ LET e == curEntry[w]
           v == val[e]
       IN
       /\ lock' = [lock EXCEPT ![e] = NoWorker]
       /\ heldCount' = [heldCount EXCEPT ![w] = heldCount[w] + 1]
       /\ heldVal' = [heldVal EXCEPT ![w] = v]
       /\ returnedZeroVal' = (returnedZeroVal \/ v = 0)
       /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
       /\ op' = [op EXCEPT ![w] = "none"]
       /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<mapEntry, nextEntryId, refCount, val, savedEntry, loaded,
                   overwroteLiveVal, deletedWrongEntry, derefMissedMap, refPanicked>>

AcquireOrErrorProduceOk(w) ==
    /\ pc[w] = "aoe_body"
    /\ loaded[w] = FALSE
    /\ LET e == curEntry[w] IN
       /\ val' = [val EXCEPT ![e] = e]
       /\ lock' = [lock EXCEPT ![e] = NoWorker]
       /\ heldCount' = [heldCount EXCEPT ![w] = heldCount[w] + 1]
       /\ heldVal' = [heldVal EXCEPT ![w] = e]
       /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
       /\ op' = [op EXCEPT ![w] = "none"]
       /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<mapEntry, nextEntryId, refCount, savedEntry, loaded,
                   returnedZeroVal, overwroteLiveVal, deletedWrongEntry,
                   derefMissedMap, refPanicked>>

AcquireOrErrorProduceErr(w) ==
    /\ pc[w] = "aoe_body"
    /\ loaded[w] = FALSE
    /\ LET e == curEntry[w] IN
       /\ refCount' = [refCount EXCEPT ![e] = 0]
       /\ deletedWrongEntry' = (deletedWrongEntry \/ (mapEntry # NoEntry /\ mapEntry # e))
       /\ mapEntry' = NoEntry
       /\ lock' = [lock EXCEPT ![e] = NoWorker]
       /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
       /\ op' = [op EXCEPT ![w] = "none"]
       /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<nextEntryId, val, savedEntry, loaded, heldCount, heldVal,
                   returnedZeroVal, overwroteLiveVal, derefMissedMap, refPanicked>>

\* --- AcquireExisting ---

AcquireExistingLoad(w) ==
    /\ pc[w] = "ae_load"
    /\ IF mapEntry = NoEntry
       THEN /\ op' = [op EXCEPT ![w] = "none"]
            /\ pc' = [pc EXCEPT ![w] = "idle"]
            /\ UNCHANGED curEntry
       ELSE /\ curEntry' = [curEntry EXCEPT ![w] = mapEntry]
            /\ pc' = [pc EXCEPT ![w] = "ae_lock"]
            /\ UNCHANGED op
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, refCount, val, savedEntry, loaded,
                   heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

AcquireExistingLock(w) ==
    /\ pc[w] = "ae_lock"
    /\ LET e == curEntry[w] IN
       /\ lock[e] = NoWorker
       /\ IF refCount[e] <= 0 /\ ~DisableDeletion
          THEN /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
               /\ op' = [op EXCEPT ![w] = "none"]
               /\ pc' = [pc EXCEPT ![w] = "idle"]
               /\ UNCHANGED <<refCount, heldCount, heldVal, returnedZeroVal>>
          ELSE /\ refCount' = [refCount EXCEPT ![e] = refCount[e] + 1]
               /\ heldCount' = [heldCount EXCEPT ![w] = heldCount[w] + 1]
               /\ heldVal' = [heldVal EXCEPT ![w] = val[e]]
               /\ returnedZeroVal' = (returnedZeroVal \/ val[e] = 0)
               /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
               /\ op' = [op EXCEPT ![w] = "none"]
               /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, val, savedEntry, loaded,
                   overwroteLiveVal, deletedWrongEntry, derefMissedMap, refPanicked>>

\* --- Deref ---

DerefLoad(w) ==
    /\ pc[w] = "deref_load"
    /\ IF mapEntry = NoEntry
       THEN /\ derefMissedMap' = TRUE
            /\ heldCount' = [heldCount EXCEPT ![w] = heldCount[w] - 1]
            /\ op' = [op EXCEPT ![w] = "none"]
            /\ pc' = [pc EXCEPT ![w] = "idle"]
            /\ UNCHANGED curEntry
       ELSE /\ curEntry' = [curEntry EXCEPT ![w] = mapEntry]
            /\ pc' = [pc EXCEPT ![w] = "deref_lock"]
            /\ UNCHANGED <<derefMissedMap, heldCount, op>>
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, refCount, val, savedEntry, loaded,
                   heldVal, returnedZeroVal, overwroteLiveVal, deletedWrongEntry,
                   refPanicked>>

DerefLock(w) ==
    /\ pc[w] = "deref_lock"
    /\ LET e == curEntry[w]
           newRC == refCount[e] - 1
       IN
       /\ lock[e] = NoWorker
       /\ refCount' = [refCount EXCEPT ![e] = newRC]
       /\ IF newRC <= 0 /\ ~DisableDeletion
          THEN /\ deletedWrongEntry' = (deletedWrongEntry \/ (mapEntry # NoEntry /\ mapEntry # e))
               /\ mapEntry' = NoEntry
          ELSE /\ UNCHANGED <<deletedWrongEntry, mapEntry>>
       /\ heldCount' = [heldCount EXCEPT ![w] = heldCount[w] - 1]
       /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
       /\ op' = [op EXCEPT ![w] = "none"]
       /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<nextEntryId, lock, val, savedEntry, loaded, heldVal,
                   returnedZeroVal, overwroteLiveVal, derefMissedMap, refPanicked>>

\* --- Ref ---

RefLoad(w) ==
    /\ pc[w] = "ref_load"
    /\ IF mapEntry = NoEntry
       THEN /\ refPanicked' = TRUE
            /\ op' = [op EXCEPT ![w] = "none"]
            /\ pc' = [pc EXCEPT ![w] = "idle"]
            /\ UNCHANGED curEntry
       ELSE /\ curEntry' = [curEntry EXCEPT ![w] = mapEntry]
            /\ pc' = [pc EXCEPT ![w] = "ref_lock"]
            /\ UNCHANGED <<refPanicked, op>>
    /\ UNCHANGED <<mapEntry, nextEntryId, lock, refCount, val, savedEntry, loaded,
                   heldCount, heldVal, returnedZeroVal, overwroteLiveVal,
                   deletedWrongEntry, derefMissedMap>>

RefLock(w) ==
    /\ pc[w] = "ref_lock"
    /\ LET e == curEntry[w] IN
       /\ lock[e] = NoWorker
       /\ IF refCount[e] <= 0 /\ ~DisableDeletion
          THEN \* Holds lock[e] and calls loadOrStoreNewLockedEntry(identity)
               /\ lock' = [lock EXCEPT ![e] = w]
               /\ savedEntry' = [savedEntry EXCEPT ![w] = e]
               /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
               /\ pc' = [pc EXCEPT ![w] = "los_try"]
               /\ UNCHANGED <<refCount, heldCount, op>>
          ELSE /\ refCount' = [refCount EXCEPT ![e] = refCount[e] + 1]
               /\ heldCount' = [heldCount EXCEPT ![w] = heldCount[w] + 1]
               /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
               /\ op' = [op EXCEPT ![w] = "none"]
               /\ pc' = [pc EXCEPT ![w] = "idle"]
               /\ UNCHANGED <<lock, savedEntry>>
    /\ UNCHANGED <<mapEntry, nextEntryId, val, loaded, heldVal, returnedZeroVal,
                   overwroteLiveVal, deletedWrongEntry, derefMissedMap, refPanicked>>

RefResurrectFinish(w) ==
    /\ pc[w] = "ref_resurrect_finish"
    /\ LET oldE == savedEntry[w]
           newE == curEntry[w]
       IN
       /\ overwroteLiveVal' = (overwroteLiveVal \/ (loaded[w] /\ val[newE] # 0 /\ val[newE] # val[oldE]))
       /\ val' = [val EXCEPT ![newE] = val[oldE]]
       /\ lock' = [lock EXCEPT ![newE] = NoWorker, ![oldE] = NoWorker]
       /\ heldCount' = [heldCount EXCEPT ![w] = heldCount[w] + 1]
       /\ savedEntry' = [savedEntry EXCEPT ![w] = NoEntry]
       /\ curEntry' = [curEntry EXCEPT ![w] = NoEntry]
       /\ op' = [op EXCEPT ![w] = "none"]
       /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<mapEntry, nextEntryId, refCount, loaded, heldVal, returnedZeroVal,
                   deletedWrongEntry, derefMissedMap, refPanicked>>

Next ==
    \E w \in Workers :
        \/ StartAcquire(w)
        \/ StartAcquireOrError(w)
        \/ StartAcquireExisting(w)
        \/ StartDeref(w)
        \/ StartRef(w)
        \/ LosTryStore(w)
        \/ LosTryLoadExisting(w)
        \/ LosLockExisting(w)
        \/ AcquireFinish(w)
        \/ AcquireOrErrorLoaded(w)
        \/ AcquireOrErrorProduceOk(w)
        \/ AcquireOrErrorProduceErr(w)
        \/ AcquireExistingLoad(w)
        \/ AcquireExistingLock(w)
        \/ DerefLoad(w)
        \/ DerefLock(w)
        \/ RefLoad(w)
        \/ RefLock(w)
        \/ RefResurrectFinish(w)

\* --- Invariants ---

NoZeroValReturned == ~returnedZeroVal
NoLiveValueOverwrite == ~overwroteLiveVal
NoWrongEntryDeleted == ~deletedWrongEntry
NoDerefMiss == ~derefMissedMap
NoRefPanic == ~refPanicked

QuiescentConsistency ==
    (\A w \in Workers : pc[w] = "idle") =>
        /\ (TotalHeld > 0 => mapEntry # NoEntry /\ refCount[mapEntry] = TotalHeld /\ val[mapEntry] # 0)
        /\ ((TotalHeld = 0 /\ ~DisableDeletion) => mapEntry = NoEntry)

AllInvariants ==
    /\ NoZeroValReturned
    /\ NoLiveValueOverwrite
    /\ NoWrongEntryDeleted
    /\ NoDerefMiss
    /\ QuiescentConsistency

=============================================================================
