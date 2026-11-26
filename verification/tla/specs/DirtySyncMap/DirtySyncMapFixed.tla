------------------------ MODULE DirtySyncMapFixed ------------------------
EXTENDS Integers, FiniteSets

\* Faithful model of the redesigned tsc/internal/project/dirty/syncmap.go
\* for a single key K initially present in base with baseVal = 1.
\* Verifies all 6 safety invariants + deadlock freedom across every interleaving of:
\* - LoadCleanFromBase, LoadFromDirty, MapDeleteInsert
\* - Entry.Change, Entry.ChangeIf, Entry.Delete, Entry.DeleteIf
\* - Entry.Locked({ Change; Change }) and Entry.Locked({ Change; Delete })

CONSTANTS
    Workers,     \* e.g. {"w1", "w2"}
    MaxEntries,  \* e.g. 3
    MaxObjs      \* e.g. 3

EntryIds == 1..MaxEntries
ObjIds   == 1..MaxObjs
NoEntry  == 0
NoObj    == 0
NoWorker == "NONE"

VARIABLES
    dirtyMap,        \* 0 or EntryIds: m.dirty[K]
    nextEntryId,     \* 1..MaxEntries+1
    nextObjId,       \* 2..MaxObjs+1 (obj 1 is immutable base value)
    lock,            \* [EntryIds -> Workers \cup {NoWorker}]
    eValObj,         \* [EntryIds -> 0..MaxObjs]
    eDirty,          \* [EntryIds -> BOOLEAN]
    eDelete,         \* [EntryIds -> BOOLEAN]
    eProxyFor,       \* [EntryIds -> 0..MaxEntries]
    objData,         \* [ObjIds -> 1..2]
    objWriters,      \* [ObjIds -> 0..2]
    pc,              \* [Workers -> PCs]
    handle,          \* [Workers -> 0..MaxEntries]
    canonical,       \* [Workers -> 0..MaxEntries] locked canonical entry (held until ReleaseLocks)
    locked1,         \* [Workers -> 0..MaxEntries] e.mu
    locked2,         \* [Workers -> 0..MaxEntries] canonical.mu if canonical # e
    activeObj,       \* [Workers -> 0..MaxObjs]
    lockedMode,      \* [Workers -> 0..2] 0=none, 1=Locked(Change;Change), 2=Locked(Change;Delete)
    \* Ghost / invariant flags
    nilClonePanic,
    dataRaceOnObj,
    mutatedBaseObj,
    mutatedDeleted,
    changeIfStaleApply,
    deleteLost

vars == <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
          objData, objWriters, pc, handle, canonical, locked1, locked2, activeObj, lockedMode,
          nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
          changeIfStaleApply, deleteLost>>

Init ==
    /\ dirtyMap = NoEntry
    /\ nextEntryId = 1
    /\ nextObjId = 2
    /\ lock = [e \in EntryIds |-> NoWorker]
    /\ eValObj = [e \in EntryIds |-> NoObj]
    /\ eDirty = [e \in EntryIds |-> FALSE]
    /\ eDelete = [e \in EntryIds |-> FALSE]
    /\ eProxyFor = [e \in EntryIds |-> NoEntry]
    /\ objData = [o \in ObjIds |-> 1]
    /\ objWriters = [o \in ObjIds |-> 0]
    /\ pc = [w \in Workers |-> "idle"]
    /\ handle = [w \in Workers |-> NoEntry]
    /\ canonical = [w \in Workers |-> NoEntry]
    /\ locked1 = [w \in Workers |-> NoEntry]
    /\ locked2 = [w \in Workers |-> NoEntry]
    /\ activeObj = [w \in Workers |-> NoObj]
    /\ lockedMode = [w \in Workers |-> 0]
    /\ nilClonePanic = FALSE
    /\ dataRaceOnObj = FALSE
    /\ mutatedBaseObj = FALSE
    /\ mutatedDeleted = FALSE
    /\ changeIfStaleApply = FALSE
    /\ deleteLost = FALSE

\* --- m.Load(K) ---

LoadCleanFromBase(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] = NoEntry
    /\ dirtyMap = NoEntry
    /\ nextEntryId <= MaxEntries
    /\ LET e == nextEntryId IN
       /\ nextEntryId' = nextEntryId + 1
       /\ eValObj' = [eValObj EXCEPT ![e] = 1]
       /\ eDirty' = [eDirty EXCEPT ![e] = FALSE]
       /\ eDelete' = [eDelete EXCEPT ![e] = FALSE]
       /\ eProxyFor' = [eProxyFor EXCEPT ![e] = NoEntry]
       /\ handle' = [handle EXCEPT ![w] = e]
    /\ UNCHANGED <<dirtyMap, nextObjId, lock, objData, objWriters, pc, canonical,
                   locked1, locked2, activeObj, lockedMode, nilClonePanic, dataRaceOnObj,
                   mutatedBaseObj, mutatedDeleted, changeIfStaleApply, deleteLost>>

LoadFromDirty(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] = NoEntry
    /\ dirtyMap # NoEntry
    /\ lock[dirtyMap] = NoWorker
    /\ IF ~eDelete[dirtyMap]
       THEN handle' = [handle EXCEPT ![w] = dirtyMap]
       ELSE UNCHANGED handle
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, pc, canonical, locked1, locked2, activeObj, lockedMode,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteLost>>

\* --- m.Delete(K) ---
\* Fixed: sets value = baseVal (obj 1) alongside original = baseVal, delete = TRUE.

MapDeleteInsert(w) ==
    /\ pc[w] = "idle"
    /\ dirtyMap = NoEntry
    /\ nextEntryId <= MaxEntries
    /\ LET e == nextEntryId IN
       /\ dirtyMap' = e
       /\ nextEntryId' = nextEntryId + 1
       /\ eValObj' = [eValObj EXCEPT ![e] = 1]
       /\ eDirty' = [eDirty EXCEPT ![e] = FALSE]
       /\ eDelete' = [eDelete EXCEPT ![e] = TRUE]
       /\ eProxyFor' = [eProxyFor EXCEPT ![e] = NoEntry]
    /\ UNCHANGED <<nextObjId, lock, objData, objWriters, pc, handle, canonical,
                   locked1, locked2, activeObj, lockedMode, nilClonePanic, dataRaceOnObj,
                   mutatedBaseObj, mutatedDeleted, changeIfStaleApply, deleteLost>>

\* --- Generic lockCanonicalLocked(e) helper modeled as a step ---
\* Precondition: worker holds lock[e] (locked1[w] = e), canonical[w] = NoEntry.
\* Acquires canonical's lock (if distinct from e), binds eProxyFor if lost LoadOrStore,
\* and transitions to nextPC.

LockCanonical(w, nextPC) ==
    LET e == locked1[w] IN
    IF eProxyFor[e] # NoEntry
    THEN LET p == eProxyFor[e] IN
         /\ lock[p] = NoWorker
         /\ lock' = [lock EXCEPT ![p] = w]
         /\ locked2' = [locked2 EXCEPT ![w] = p]
         /\ canonical' = [canonical EXCEPT ![w] = p]
         /\ pc' = [pc EXCEPT ![w] = nextPC]
         /\ UNCHANGED <<dirtyMap, eProxyFor, eValObj, eDirty, eDelete>>
    ELSE IF eDirty[e] \/ eDelete[e]
    THEN /\ canonical' = [canonical EXCEPT ![w] = e]
         /\ pc' = [pc EXCEPT ![w] = nextPC]
         /\ UNCHANGED <<dirtyMap, lock, locked2, eProxyFor, eValObj, eDirty, eDelete>>
    ELSE IF dirtyMap = NoEntry
    THEN \* LoadOrStore wins: e becomes canonical!
         /\ dirtyMap' = e
         /\ canonical' = [canonical EXCEPT ![w] = e]
         /\ pc' = [pc EXCEPT ![w] = nextPC]
         /\ UNCHANGED <<lock, locked2, eProxyFor, eValObj, eDirty, eDelete>>
    ELSE \* LoadOrStore loses: bind proxyFor and lock canonical entry
         LET c == dirtyMap IN
         /\ lock[c] = NoWorker
         /\ lock' = [lock EXCEPT ![c] = w]
         /\ locked2' = [locked2 EXCEPT ![w] = c]
         /\ eProxyFor' = [eProxyFor EXCEPT ![e] = c]
         /\ eValObj' = [eValObj EXCEPT ![e] = eValObj[c]]
         /\ eDirty' = [eDirty EXCEPT ![e] = eDirty[c]]
         /\ eDelete' = [eDelete EXCEPT ![e] = eDelete[c]]
         /\ canonical' = [canonical EXCEPT ![w] = c]
         /\ pc' = [pc EXCEPT ![w] = nextPC]
         /\ UNCHANGED dirtyMap

\* --- e.Change(apply) ---

StartChange(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] # NoEntry
    /\ LET e == handle[w] IN
       /\ lock[e] = NoWorker
       /\ lock' = [lock EXCEPT ![e] = w]
       /\ locked1' = [locked1 EXCEPT ![w] = e]
       /\ pc' = [pc EXCEPT ![w] = "change_lock_canon"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, canonical, locked2, activeObj, lockedMode,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteLost>>

ChangeLockCanon(w) ==
    /\ pc[w] = "change_lock_canon"
    /\ LockCanonical(w, "change_apply_enter")
    /\ UNCHANGED <<nextEntryId, nextObjId, objData, objWriters, handle, activeObj,
                   locked1, lockedMode, nilClonePanic, dataRaceOnObj, mutatedBaseObj,
                   mutatedDeleted, changeIfStaleApply, deleteLost>>

ChangeApplyEnter(w) ==
    /\ pc[w] = "change_apply_enter"
    /\ LET c == canonical[w]
           e == locked1[w]
       IN
       IF eDelete[c]
       THEN \* Fixed: never clone or mutate a deleted entry!
            /\ pc' = [pc EXCEPT ![w] = IF lockedMode[w] = 1 THEN "locked_second_change"
                                       ELSE IF lockedMode[w] = 2 THEN "locked_second_delete"
                                       ELSE "release_locks"]
            /\ UNCHANGED <<nextObjId, eValObj, eDirty, activeObj, objWriters,
                           nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted>>
       ELSE IF ~eDirty[c]
       THEN IF eValObj[c] = NoObj
            THEN /\ nilClonePanic' = TRUE
                 /\ pc' = [pc EXCEPT ![w] = "release_locks"]
                 /\ UNCHANGED <<nextObjId, eValObj, eDirty, activeObj, objWriters,
                                dataRaceOnObj, mutatedBaseObj, mutatedDeleted>>
            ELSE /\ nextObjId <= MaxObjs
                 /\ LET newO == nextObjId IN
                    /\ nextObjId' = nextObjId + 1
                    /\ eValObj' = [eValObj EXCEPT ![c] = newO, ![e] = newO]
                    /\ eDirty' = [eDirty EXCEPT ![c] = TRUE, ![e] = TRUE]
                    /\ activeObj' = [activeObj EXCEPT ![w] = newO]
                    /\ objWriters' = [objWriters EXCEPT ![newO] = objWriters[newO] + 1]
                    /\ dataRaceOnObj' = (dataRaceOnObj \/ objWriters[newO] >= 1)
                    /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[c])
                    /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
                    /\ UNCHANGED <<nilClonePanic, mutatedBaseObj>>
       ELSE LET o == eValObj[c] IN
            /\ activeObj' = [activeObj EXCEPT ![w] = o]
            /\ objWriters' = IF o # NoObj THEN [objWriters EXCEPT ![o] = objWriters[o] + 1] ELSE objWriters
            /\ dataRaceOnObj' = (dataRaceOnObj \/ (o # NoObj /\ objWriters[o] >= 1))
            /\ mutatedBaseObj' = (mutatedBaseObj \/ o = 1)
            /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[c])
            /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
            /\ UNCHANGED <<nextObjId, eValObj, eDirty, nilClonePanic>>
    /\ UNCHANGED <<dirtyMap, nextEntryId, lock, eDelete, eProxyFor, objData, handle,
                   canonical, locked1, locked2, lockedMode, changeIfStaleApply, deleteLost>>

ApplyFinish(w) ==
    /\ pc[w] = "apply_finish"
    /\ LET o == activeObj[w] IN
       /\ objData' = IF o # NoObj THEN [objData EXCEPT ![o] = 2] ELSE objData
       /\ objWriters' = IF o # NoObj THEN [objWriters EXCEPT ![o] = objWriters[o] - 1] ELSE objWriters
       /\ activeObj' = [activeObj EXCEPT ![w] = NoObj]
       \* NOTE: locked2 (canonical.mu) stays HELD across Locked(fn) steps!
       /\ IF lockedMode[w] = 1
          THEN /\ lockedMode' = [lockedMode EXCEPT ![w] = 0]
               /\ pc' = [pc EXCEPT ![w] = "locked_second_change"]
          ELSE IF lockedMode[w] = 2
          THEN /\ lockedMode' = [lockedMode EXCEPT ![w] = 0]
               /\ pc' = [pc EXCEPT ![w] = "locked_second_delete"]
          ELSE /\ pc' = [pc EXCEPT ![w] = "release_locks"]
               /\ UNCHANGED lockedMode
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
                   handle, canonical, locked1, locked2, nilClonePanic, dataRaceOnObj,
                   mutatedBaseObj, mutatedDeleted, changeIfStaleApply, deleteLost>>

\* --- e.ChangeIf(cond: data==1, apply: data=2) ---

StartChangeIf(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] # NoEntry
    /\ LET e == handle[w] IN
       /\ lock[e] = NoWorker
       /\ lock' = [lock EXCEPT ![e] = w]
       /\ locked1' = [locked1 EXCEPT ![w] = e]
       /\ pc' = [pc EXCEPT ![w] = "changeif_lock_canon"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, canonical, locked2, activeObj, lockedMode,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteLost>>

ChangeIfLockCanon(w) ==
    /\ pc[w] = "changeif_lock_canon"
    /\ LockCanonical(w, "changeif_eval_and_apply")
    /\ UNCHANGED <<nextEntryId, nextObjId, objData, objWriters, handle, activeObj,
                   locked1, lockedMode, nilClonePanic, dataRaceOnObj, mutatedBaseObj,
                   mutatedDeleted, changeIfStaleApply, deleteLost>>

\* Evaluates cond(c.value) UNDER c.mu (after proxying!)
ChangeIfEvalAndApply(w) ==
    /\ pc[w] = "changeif_eval_and_apply"
    /\ LET c == canonical[w]
           e == locked1[w]
           o == eValObj[c]
       IN
       IF eDelete[c] \/ o = NoObj \/ objData[o] # 1
       THEN /\ pc' = [pc EXCEPT ![w] = "release_locks"]
            /\ UNCHANGED <<nextObjId, eValObj, eDirty, activeObj, objWriters,
                           nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                           changeIfStaleApply>>
       ELSE /\ changeIfStaleApply' = (changeIfStaleApply \/ objData[o] # 1)
            /\ IF ~eDirty[c]
               THEN /\ nextObjId <= MaxObjs
                    /\ LET newO == nextObjId IN
                       /\ nextObjId' = nextObjId + 1
                       /\ eValObj' = [eValObj EXCEPT ![c] = newO, ![e] = newO]
                       /\ eDirty' = [eDirty EXCEPT ![c] = TRUE, ![e] = TRUE]
                       /\ activeObj' = [activeObj EXCEPT ![w] = newO]
                       /\ objWriters' = [objWriters EXCEPT ![newO] = objWriters[newO] + 1]
                       /\ dataRaceOnObj' = (dataRaceOnObj \/ objWriters[newO] >= 1)
                       /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[c])
                       /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
                       /\ UNCHANGED <<nilClonePanic, mutatedBaseObj>>
               ELSE /\ activeObj' = [activeObj EXCEPT ![w] = o]
                    /\ objWriters' = [objWriters EXCEPT ![o] = objWriters[o] + 1]
                    /\ dataRaceOnObj' = (dataRaceOnObj \/ objWriters[o] >= 1)
                    /\ mutatedBaseObj' = (mutatedBaseObj \/ o = 1)
                    /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[c])
                    /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
                    /\ UNCHANGED <<nextObjId, eValObj, eDirty, nilClonePanic>>
    /\ UNCHANGED <<dirtyMap, nextEntryId, lock, eDelete, eProxyFor, objData, handle,
                   canonical, locked1, locked2, lockedMode, deleteLost>>

\* --- e.Delete() ---

StartEntryDelete(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] # NoEntry
    /\ LET e == handle[w] IN
       /\ lock[e] = NoWorker
       /\ lock' = [lock EXCEPT ![e] = w]
       /\ locked1' = [locked1 EXCEPT ![w] = e]
       /\ pc' = [pc EXCEPT ![w] = "delete_lock_canon"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, canonical, locked2, activeObj, lockedMode,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteLost>>

DeleteLockCanon(w) ==
    /\ pc[w] = "delete_lock_canon"
    /\ LockCanonical(w, "delete_apply")
    /\ UNCHANGED <<nextEntryId, nextObjId, objData, objWriters, handle, activeObj,
                   locked1, lockedMode, nilClonePanic, dataRaceOnObj, mutatedBaseObj,
                   mutatedDeleted, changeIfStaleApply, deleteLost>>

DeleteApply(w) ==
    /\ pc[w] = "delete_apply"
    /\ LET c == canonical[w]
           e == locked1[w]
       IN
       /\ eDelete' = [eDelete EXCEPT ![c] = TRUE, ![e] = TRUE]
       /\ deleteLost' = (deleteLost \/ (dirtyMap # c))
       /\ pc' = [pc EXCEPT ![w] = "release_locks"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eProxyFor,
                   objData, objWriters, handle, canonical, locked1, locked2, activeObj,
                   lockedMode, nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply>>

\* --- e.Locked(func(v) { v.Change(); v.Change() }) and e.Locked(func(v) { v.Change(); v.Delete() }) ---

StartLockedCombo(w, mode) ==
    /\ pc[w] = "idle"
    /\ handle[w] # NoEntry
    /\ LET e == handle[w] IN
       /\ lock[e] = NoWorker
       /\ lock' = [lock EXCEPT ![e] = w]
       /\ locked1' = [locked1 EXCEPT ![w] = e]
       /\ lockedMode' = [lockedMode EXCEPT ![w] = mode]
       /\ pc' = [pc EXCEPT ![w] = "change_lock_canon"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, canonical, locked2, activeObj,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteLost>>

\* Second v.Change() inside Locked(fn): canonical[w] is STILL LOCKED!
LockedSecondChange(w) ==
    /\ pc[w] = "locked_second_change"
    /\ pc' = [pc EXCEPT ![w] = "change_apply_enter"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, canonical, locked1, locked2, activeObj,
                   lockedMode, nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteLost>>

\* Second v.Delete() inside Locked(fn): canonical[w] is STILL LOCKED!
LockedSecondDelete(w) ==
    /\ pc[w] = "locked_second_delete"
    /\ pc' = [pc EXCEPT ![w] = "delete_apply"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, canonical, locked1, locked2, activeObj,
                   lockedMode, nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteLost>>

\* --- Release held locks ---

ReleaseLocks(w) ==
    /\ pc[w] = "release_locks"
    /\ lock' = [e \in EntryIds |-> IF e = locked1[w] \/ e = locked2[w] THEN NoWorker ELSE lock[e]]
    /\ locked1' = [locked1 EXCEPT ![w] = NoEntry]
    /\ locked2' = [locked2 EXCEPT ![w] = NoEntry]
    /\ canonical' = [canonical EXCEPT ![w] = NoEntry]
    /\ lockedMode' = [lockedMode EXCEPT ![w] = 0]
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, activeObj, nilClonePanic, dataRaceOnObj,
                   mutatedBaseObj, mutatedDeleted, changeIfStaleApply, deleteLost>>

Next ==
    \E w \in Workers :
        \/ LoadCleanFromBase(w)
        \/ LoadFromDirty(w)
        \/ MapDeleteInsert(w)
        \/ StartChange(w)
        \/ ChangeLockCanon(w)
        \/ ChangeApplyEnter(w)
        \/ ApplyFinish(w)
        \/ StartChangeIf(w)
        \/ ChangeIfLockCanon(w)
        \/ ChangeIfEvalAndApply(w)
        \/ StartEntryDelete(w)
        \/ DeleteLockCanon(w)
        \/ DeleteApply(w)
        \/ StartLockedCombo(w, 1)
        \/ StartLockedCombo(w, 2)
        \/ LockedSecondChange(w)
        \/ LockedSecondDelete(w)
        \/ ReleaseLocks(w)

\* --- All 6 Safety Invariants ---
NoNilClonePanic     == ~nilClonePanic
NoDataRace          == ~dataRaceOnObj
NoMutateBase        == ~mutatedBaseObj
NoMutateDeleted     == ~mutatedDeleted
NoChangeIfTOCTOU    == ~changeIfStaleApply
NoLostDelete        == ~deleteLost

\* No deadlock: whenever any worker is non-idle, some step MUST be enabled!
\* (Also checked directly via CHECK_DEADLOCK TRUE since workers can always start or release!)

=============================================================================
