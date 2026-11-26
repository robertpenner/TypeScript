--------------------------- MODULE DirtySyncMap ---------------------------
EXTENDS Integers, FiniteSets

\* Faithful synchronization model of tsc/internal/project/dirty/syncmap.go
\* for a single key K initially present in base with baseVal = 1.

CONSTANTS
    Workers,     \* e.g. {"w1", "w2"}
    MaxEntries,  \* Bound on SyncMapEntry allocations, e.g. 4
    MaxObjs      \* Bound on Clone() value allocations, e.g. 4

EntryIds == 1..MaxEntries
ObjIds   == 1..MaxObjs
NoEntry  == 0
NoObj    == 0
NoWorker == "NONE"

VARIABLES
    dirtyMap,        \* 0 or EntryIds: m.dirty[K]
    nextEntryId,     \* 1..MaxEntries+1
    nextObjId,       \* 2..MaxObjs+1 (obj 1 is immutable base value)
    \* Per-entry fields
    lock,            \* [EntryIds -> Workers \cup {NoWorker}]
    eValObj,         \* [EntryIds -> 0..MaxObjs] (0 = nil pointer!)
    eDirty,          \* [EntryIds -> BOOLEAN]
    eDelete,         \* [EntryIds -> BOOLEAN]
    eProxyFor,       \* [EntryIds -> 0..MaxEntries]
    \* Per-value-object fields (obj 1 is base[K], immutable!)
    objData,         \* [ObjIds -> 1..3] (initial 1; cond checks data = 1; apply sets 2 or increments)
    objWriters,      \* [ObjIds -> 0..2] number of workers currently inside apply(obj)
    \* Per-worker state
    pc,              \* [Workers -> PCs]
    handle,          \* [Workers -> 0..MaxEntries] worker's loaded SyncMapEntry
    target,          \* [Workers -> 0..MaxEntries] current entry being operated on (follows proxyFor)
    locked1,         \* [Workers -> 0..MaxEntries] first held mutex (e.mu)
    locked2,         \* [Workers -> 0..MaxEntries] second held mutex (entry.mu from LoadOrStore)
    activeObj,       \* [Workers -> 0..MaxObjs] value obj currently being mutated in apply()
    lockedStep,      \* [Workers -> 0..2] step inside Locked(fn): 1 = first Change, 2 = second Change/Delete
    \* Ghost / invariant violation flags
    nilClonePanic,       \* TRUE if changeLocked called Clone() on nil (eValObj = 0)
    dataRaceOnObj,       \* TRUE if two workers concurrently execute apply() on the same obj
    mutatedBaseObj,      \* TRUE if apply() ran on base obj (1)
    mutatedDeleted,      \* TRUE if apply() ran on an entry with eDelete = TRUE
    changeIfStaleApply,  \* TRUE if ChangeIf ran apply() when current objData # 1 (cond was FALSE!)
    deleteIfStaleDelete, \* TRUE if DeleteIf deleted when current objData # 1 (cond was FALSE!)
    deleteLost,          \* TRUE if a Delete() completed but dirtyMap does NOT have eDelete = TRUE
    hasDeletedOnce       \* TRUE once any Delete operation has completed

vars == <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
          objData, objWriters, pc, handle, target, locked1, locked2, activeObj, lockedStep,
          nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
          changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

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
    /\ target = [w \in Workers |-> NoEntry]
    /\ locked1 = [w \in Workers |-> NoEntry]
    /\ locked2 = [w \in Workers |-> NoEntry]
    /\ activeObj = [w \in Workers |-> NoObj]
    /\ lockedStep = [w \in Workers |-> 0]
    /\ nilClonePanic = FALSE
    /\ dataRaceOnObj = FALSE
    /\ mutatedBaseObj = FALSE
    /\ mutatedDeleted = FALSE
    /\ changeIfStaleApply = FALSE
    /\ deleteIfStaleDelete = FALSE
    /\ deleteLost = FALSE
    /\ hasDeletedOnce = FALSE

\* --- m.Load(K) ---

\* Load from base when dirtyMap = 0: allocates a fresh clean SyncMapEntry pointing to base obj 1
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
    /\ UNCHANGED <<dirtyMap, nextObjId, lock, objData, objWriters, pc, target,
                   locked1, locked2, activeObj, lockedStep, nilClonePanic, dataRaceOnObj,
                   mutatedBaseObj, mutatedDeleted, changeIfStaleApply, deleteIfStaleDelete,
                   deleteLost, hasDeletedOnce>>

\* Load when dirtyMap # 0: locks dirtyMap, returns it if not deleted
LoadFromDirty(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] = NoEntry
    /\ dirtyMap # NoEntry
    /\ lock[dirtyMap] = NoWorker
    /\ IF ~eDelete[dirtyMap]
       THEN handle' = [handle EXCEPT ![w] = dirtyMap]
       ELSE UNCHANGED handle
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, pc, target, locked1, locked2, activeObj, lockedStep,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

\* --- m.Delete(K) ---
\* Lines 253-263: LoadOrStore(&SyncMapEntry{original: base[k], delete: true}) -- NOTE: value=0 (nil!), dirty=FALSE!

MapDeleteInsert(w) ==
    /\ pc[w] = "idle"
    /\ dirtyMap = NoEntry
    /\ nextEntryId <= MaxEntries
    /\ LET e == nextEntryId IN
       /\ dirtyMap' = e
       /\ nextEntryId' = nextEntryId + 1
       /\ eValObj' = [eValObj EXCEPT ![e] = NoObj]
       /\ eDirty' = [eDirty EXCEPT ![e] = FALSE]
       /\ eDelete' = [eDelete EXCEPT ![e] = TRUE]
       /\ eProxyFor' = [eProxyFor EXCEPT ![e] = NoEntry]
       /\ hasDeletedOnce' = TRUE
    /\ UNCHANGED <<nextObjId, lock, objData, objWriters, pc, handle, target,
                   locked1, locked2, activeObj, lockedStep, nilClonePanic, dataRaceOnObj,
                   mutatedBaseObj, mutatedDeleted, changeIfStaleApply, deleteIfStaleDelete,
                   deleteLost>>

\* --- e.Change(apply) ---

StartChange(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] # NoEntry
    /\ LET e == handle[w] IN
       /\ lock[e] = NoWorker
       /\ lock' = [lock EXCEPT ![e] = w]
       /\ locked1' = [locked1 EXCEPT ![w] = e]
       /\ target' = [target EXCEPT ![w] = e]
       /\ pc' = [pc EXCEPT ![w] = "change_check_proxy"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, locked2, activeObj, lockedStep,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

\* Follow proxyFor if set (holds e.mu and acquires proxyFor.mu)
ChangeCheckProxy(w) ==
    /\ pc[w] = "change_check_proxy"
    /\ LET e == target[w] IN
       IF eProxyFor[e] # NoEntry
       THEN /\ LET p == eProxyFor[e] IN
               /\ lock[p] = NoWorker
               /\ lock' = [lock EXCEPT ![p] = w]
               /\ locked2' = [locked2 EXCEPT ![w] = p]
               /\ target' = [target EXCEPT ![w] = p]
               /\ pc' = [pc EXCEPT ![w] = "change_locked"]
       ELSE /\ pc' = [pc EXCEPT ![w] = "change_locked"]
            /\ UNCHANGED <<lock, locked2, target>>
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, locked1, activeObj, lockedStep,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

\* changeLocked(apply): lines 102-122
ChangeLockedEnter(w) ==
    /\ pc[w] = "change_locked"
    /\ LET e == target[w] IN
       IF eDirty[e]
       THEN \* Fast path: apply(e.value) directly (NO lock on proxyFor!)
            /\ LET o == eValObj[e] IN
               /\ activeObj' = [activeObj EXCEPT ![w] = o]
               /\ objWriters' = IF o # NoObj THEN [objWriters EXCEPT ![o] = objWriters[o] + 1] ELSE objWriters
               /\ dataRaceOnObj' = (dataRaceOnObj \/ (o # NoObj /\ objWriters[o] >= 1))
               /\ mutatedBaseObj' = (mutatedBaseObj \/ o = 1)
               /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[e])
               /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
            /\ UNCHANGED <<dirtyMap, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
                           locked2, nilClonePanic>>
       ELSE IF dirtyMap = NoEntry
       THEN \* LoadOrStore wins! loaded = FALSE
            /\ nextObjId <= MaxObjs
            /\ LET newO == nextObjId IN
               /\ dirtyMap' = e
               /\ IF eValObj[e] = NoObj
                  THEN /\ nilClonePanic' = TRUE
                       /\ pc' = [pc EXCEPT ![w] = "release_locks"]
                       /\ UNCHANGED <<nextObjId, eValObj, eDirty, activeObj, objWriters,
                                      dataRaceOnObj, mutatedBaseObj, mutatedDeleted>>
                  ELSE /\ nextObjId' = nextObjId + 1
                       /\ eValObj' = [eValObj EXCEPT ![e] = newO]
                       /\ eDirty' = [eDirty EXCEPT ![e] = TRUE]
                       /\ activeObj' = [activeObj EXCEPT ![w] = newO]
                       /\ objWriters' = [objWriters EXCEPT ![newO] = objWriters[newO] + 1]
                       /\ dataRaceOnObj' = (dataRaceOnObj \/ objWriters[newO] >= 1)
                       /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[e])
                       /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
                       /\ UNCHANGED <<nilClonePanic, mutatedBaseObj>>
            /\ UNCHANGED <<lock, eDelete, eProxyFor, locked2>>
       ELSE \* LoadOrStore loses! loaded = TRUE -> entry = dirtyMap, lock entry.mu
            /\ LET entry == dirtyMap IN
               /\ lock[entry] = NoWorker
               /\ lock' = [lock EXCEPT ![entry] = w]
               /\ locked2' = [locked2 EXCEPT ![w] = entry]
               /\ IF ~eDirty[entry]
                  THEN IF eValObj[entry] = NoObj
                       THEN \* entry.value.Clone() on nil pointer!
                            /\ nilClonePanic' = TRUE
                            /\ pc' = [pc EXCEPT ![w] = "release_locks"]
                            /\ UNCHANGED <<nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                                           activeObj, objWriters, dataRaceOnObj,
                                           mutatedBaseObj, mutatedDeleted>>
                       ELSE /\ nextObjId <= MaxObjs
                            /\ LET newO == nextObjId IN
                               /\ nextObjId' = nextObjId + 1
                               /\ eValObj' = [eValObj EXCEPT ![entry] = newO, ![e] = newO]
                               /\ eDirty' = [eDirty EXCEPT ![entry] = TRUE, ![e] = TRUE]
                               /\ eProxyFor' = [eProxyFor EXCEPT ![e] = entry]
                               /\ eDelete' = [eDelete EXCEPT ![e] = eDelete[entry]]
                               /\ activeObj' = [activeObj EXCEPT ![w] = newO]
                               /\ objWriters' = [objWriters EXCEPT ![newO] = objWriters[newO] + 1]
                               /\ dataRaceOnObj' = (dataRaceOnObj \/ objWriters[newO] >= 1)
                               /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[entry])
                               /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
                               /\ UNCHANGED <<nilClonePanic, mutatedBaseObj>>
                  ELSE \* entry is already dirty
                       /\ LET o == eValObj[entry] IN
                          /\ eProxyFor' = [eProxyFor EXCEPT ![e] = entry]
                          /\ eValObj' = [eValObj EXCEPT ![e] = o]
                          /\ eDirty' = [eDirty EXCEPT ![e] = TRUE]
                          /\ eDelete' = [eDelete EXCEPT ![e] = eDelete[entry]]
                          /\ activeObj' = [activeObj EXCEPT ![w] = o]
                          /\ objWriters' = IF o # NoObj THEN [objWriters EXCEPT ![o] = objWriters[o] + 1] ELSE objWriters
                          /\ dataRaceOnObj' = (dataRaceOnObj \/ (o # NoObj /\ objWriters[o] >= 1))
                          /\ mutatedBaseObj' = (mutatedBaseObj \/ o = 1)
                          /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[entry])
                          /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
                          /\ UNCHANGED <<nextObjId, nilClonePanic>>
            /\ UNCHANGED dirtyMap
    /\ UNCHANGED <<nextEntryId, objData, handle, target, locked1, lockedStep,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

ApplyFinish(w) ==
    /\ pc[w] = "apply_finish"
    /\ LET o == activeObj[w] IN
       /\ objData' = IF o # NoObj THEN [objData EXCEPT ![o] = 2] ELSE objData
       /\ objWriters' = IF o # NoObj THEN [objWriters EXCEPT ![o] = objWriters[o] - 1] ELSE objWriters
       /\ activeObj' = [activeObj EXCEPT ![w] = NoObj]
       /\ IF lockedStep[w] = 1
          THEN \* Inside Locked(fn): unlock locked2 (from changeLocked defer) and run second op!
               /\ lock' = IF locked2[w] # NoEntry THEN [lock EXCEPT ![locked2[w]] = NoWorker] ELSE lock
               /\ locked2' = [locked2 EXCEPT ![w] = NoEntry]
               /\ lockedStep' = [lockedStep EXCEPT ![w] = 2]
               /\ pc' = [pc EXCEPT ![w] = "locked_second_op"]
          ELSE /\ pc' = [pc EXCEPT ![w] = "release_locks"]
               /\ UNCHANGED <<lock, locked2, lockedStep>>
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   handle, target, locked1, nilClonePanic, dataRaceOnObj, mutatedBaseObj,
                   mutatedDeleted, changeIfStaleApply, deleteIfStaleDelete, deleteLost,
                   hasDeletedOnce>>

\* --- e.ChangeIf(cond: data==1, apply: data=2) ---

StartChangeIf(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] # NoEntry
    /\ LET e == handle[w] IN
       /\ lock[e] = NoWorker
       /\ lock' = [lock EXCEPT ![e] = w]
       /\ locked1' = [locked1 EXCEPT ![w] = e]
       /\ target' = [target EXCEPT ![w] = e]
       /\ pc' = [pc EXCEPT ![w] = "changeif_check"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, locked2, activeObj, lockedStep,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

ChangeIfCheck(w) ==
    /\ pc[w] = "changeif_check"
    /\ LET e == target[w] IN
       IF eProxyFor[e] # NoEntry
       THEN /\ LET p == eProxyFor[e] IN
               /\ lock[p] = NoWorker
               /\ lock' = [lock EXCEPT ![p] = w]
               /\ locked2' = [locked2 EXCEPT ![w] = p]
               /\ target' = [target EXCEPT ![w] = p]
               /\ pc' = [pc EXCEPT ![w] = "changeif_eval_cond"]
       ELSE /\ pc' = [pc EXCEPT ![w] = "changeif_eval_cond"]
            /\ UNCHANGED <<lock, locked2, target>>
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, locked1, activeObj, lockedStep,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

\* Evaluates cond(e.value): data == 1. If true, calls changeLocked (WITHOUT re-checking cond on proxy!).
ChangeIfEvalCond(w) ==
    /\ pc[w] = "changeif_eval_cond"
    /\ LET e == target[w]
           o == eValObj[e]
       IN
       IF o # NoObj /\ objData[o] = 1
       THEN \* cond(e.value) is TRUE! Now proceed to changeLocked, and remember to verify cond!
            /\ pc' = [pc EXCEPT ![w] = "changeif_enter_locked"]
       ELSE /\ pc' = [pc EXCEPT ![w] = "release_locks"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, target, locked1, locked2, activeObj, lockedStep,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

ChangeIfEnterLocked(w) ==
    /\ pc[w] = "changeif_enter_locked"
    /\ LET e == target[w] IN
       IF eDirty[e]
       THEN \* Already dirty: cond was checked on e.value under lock[e], so still holds
            /\ LET o == eValObj[e] IN
               /\ activeObj' = [activeObj EXCEPT ![w] = o]
               /\ objWriters' = IF o # NoObj THEN [objWriters EXCEPT ![o] = objWriters[o] + 1] ELSE objWriters
               /\ dataRaceOnObj' = (dataRaceOnObj \/ (o # NoObj /\ objWriters[o] >= 1))
               /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[e])
               /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
            /\ UNCHANGED <<dirtyMap, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
                           locked2, nilClonePanic, changeIfStaleApply>>
       ELSE IF dirtyMap = NoEntry
       THEN /\ nextObjId <= MaxObjs
            /\ LET newO == nextObjId IN
               /\ dirtyMap' = e
               /\ nextObjId' = nextObjId + 1
               /\ eValObj' = [eValObj EXCEPT ![e] = newO]
               /\ eDirty' = [eDirty EXCEPT ![e] = TRUE]
               /\ activeObj' = [activeObj EXCEPT ![w] = newO]
               /\ objWriters' = [objWriters EXCEPT ![newO] = objWriters[newO] + 1]
               /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
            /\ UNCHANGED <<lock, eDelete, eProxyFor, locked2, nilClonePanic, dataRaceOnObj,
                           mutatedDeleted, changeIfStaleApply>>
       ELSE \* Lost LoadOrStore race! Proxies to dirtyMap and runs apply WITHOUT re-checking cond!
            /\ LET entry == dirtyMap IN
               /\ lock[entry] = NoWorker
               /\ lock' = [lock EXCEPT ![entry] = w]
               /\ locked2' = [locked2 EXCEPT ![w] = entry]
               /\ IF ~eDirty[entry] /\ eValObj[entry] = NoObj
                  THEN /\ nilClonePanic' = TRUE
                       /\ pc' = [pc EXCEPT ![w] = "release_locks"]
                       /\ UNCHANGED <<nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                                      activeObj, objWriters, dataRaceOnObj, mutatedDeleted,
                                      changeIfStaleApply>>
                  ELSE /\ LET o == IF eDirty[entry] THEN eValObj[entry] ELSE nextObjId IN
                          /\ (~eDirty[entry] => nextObjId <= MaxObjs)
                          /\ nextObjId' = IF eDirty[entry] THEN nextObjId ELSE nextObjId + 1
                          /\ eValObj' = [eValObj EXCEPT ![entry] = o, ![e] = o]
                          /\ eDirty' = [eDirty EXCEPT ![entry] = TRUE, ![e] = TRUE]
                          /\ eProxyFor' = [eProxyFor EXCEPT ![e] = entry]
                          /\ eDelete' = [eDelete EXCEPT ![e] = eDelete[entry]]
                          /\ changeIfStaleApply' = (changeIfStaleApply \/ (o # NoObj /\ objData[o] # 1))
                          /\ mutatedDeleted' = (mutatedDeleted \/ eDelete[entry])
                          /\ activeObj' = [activeObj EXCEPT ![w] = o]
                          /\ objWriters' = [objWriters EXCEPT ![o] = objWriters[o] + 1]
                          /\ dataRaceOnObj' = (dataRaceOnObj \/ objWriters[o] >= 1)
                          /\ pc' = [pc EXCEPT ![w] = "apply_finish"]
                          /\ UNCHANGED nilClonePanic
            /\ UNCHANGED dirtyMap
    /\ UNCHANGED <<nextEntryId, objData, handle, target, locked1, lockedStep,
                   mutatedBaseObj, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

\* --- e.Delete() (lines 136-156) ---

StartEntryDelete(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] # NoEntry
    /\ LET e == handle[w] IN
       /\ lock[e] = NoWorker
       /\ lock' = [lock EXCEPT ![e] = w]
       /\ locked1' = [locked1 EXCEPT ![w] = e]
       /\ target' = [target EXCEPT ![w] = e]
       /\ pc' = [pc EXCEPT ![w] = "entry_delete_body"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, locked2, activeObj, lockedStep,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

EntryDeleteBody(w) ==
    /\ pc[w] = "entry_delete_body"
    /\ LET e == target[w] IN
       IF eProxyFor[e] # NoEntry
       THEN /\ LET p == eProxyFor[e] IN
               /\ lock[p] = NoWorker
               /\ lock' = [lock EXCEPT ![p] = w]
               /\ locked2' = [locked2 EXCEPT ![w] = p]
               /\ target' = [target EXCEPT ![w] = p]
               /\ pc' = [pc EXCEPT ![w] = "entry_delete_body"]
            /\ UNCHANGED <<dirtyMap, eDelete, deleteLost, hasDeletedOnce>>
       ELSE IF eDirty[e]
       THEN /\ eDelete' = [eDelete EXCEPT ![e] = TRUE]
            /\ hasDeletedOnce' = TRUE
            /\ deleteLost' = (deleteLost \/ (dirtyMap # NoEntry /\ dirtyMap # e /\ ~eDelete[dirtyMap]))
            /\ pc' = [pc EXCEPT ![w] = "release_locks"]
            /\ UNCHANGED <<dirtyMap, lock, locked2, target>>
       ELSE IF dirtyMap = NoEntry
       THEN \* LoadOrStore wins
            /\ dirtyMap' = e
            /\ eDelete' = [eDelete EXCEPT ![e] = TRUE]
            /\ hasDeletedOnce' = TRUE
            /\ pc' = [pc EXCEPT ![w] = "release_locks"]
            /\ UNCHANGED <<lock, locked2, target, deleteLost>>
       ELSE \* LoadOrStore loses! Lines 149-152: locks entry.mu, sets e.delete = true (NOT entry.delete!)
            /\ LET entry == dirtyMap IN
               /\ lock[entry] = NoWorker
               /\ lock' = [lock EXCEPT ![entry] = w]
               /\ locked2' = [locked2 EXCEPT ![w] = entry]
               /\ eDelete' = [eDelete EXCEPT ![e] = TRUE]  \* EXACT Go bug on line 151!
               /\ hasDeletedOnce' = TRUE
               /\ deleteLost' = (deleteLost \/ ~eDelete[entry])
               /\ pc' = [pc EXCEPT ![w] = "release_locks"]
            /\ UNCHANGED <<dirtyMap, target>>
    /\ UNCHANGED <<nextEntryId, nextObjId, eValObj, eDirty, eProxyFor, objData, objWriters,
                   handle, locked1, activeObj, lockedStep, nilClonePanic, dataRaceOnObj,
                   mutatedBaseObj, mutatedDeleted, changeIfStaleApply, deleteIfStaleDelete>>

\* --- e.Locked(func(v) { v.Change(...); v.Change(...) }) ---

StartLockedDoubleChange(w) ==
    /\ pc[w] = "idle"
    /\ handle[w] # NoEntry
    /\ LET e == handle[w] IN
       /\ lock[e] = NoWorker
       /\ lock' = [lock EXCEPT ![e] = w]
       /\ locked1' = [locked1 EXCEPT ![w] = e]
       /\ target' = [target EXCEPT ![w] = e]
       /\ lockedStep' = [lockedStep EXCEPT ![w] = 1]
       /\ pc' = [pc EXCEPT ![w] = "change_check_proxy"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, locked2, activeObj,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

\* Second v.Change(...) or v.Delete() inside the same Locked(fn): calls e.changeLocked directly
\* WITHOUT re-checking e.proxyFor!
LockedSecondChange(w) ==
    /\ pc[w] = "locked_second_op"
    /\ lockedStep' = [lockedStep EXCEPT ![w] = 0]
    /\ pc' = [pc EXCEPT ![w] = "change_locked"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, target, locked1, locked2, activeObj,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete, deleteLost, hasDeletedOnce>>

LockedSecondDelete(w) ==
    /\ pc[w] = "locked_second_op"
    /\ LET e == target[w] IN
       /\ lockedStep' = [lockedStep EXCEPT ![w] = 0]
       /\ IF eDirty[e]
          THEN \* deleteLocked() fast path: sets e.delete = true WITHOUT locking/updating proxyFor!
               /\ eDelete' = [eDelete EXCEPT ![e] = TRUE]
               /\ hasDeletedOnce' = TRUE
               /\ deleteLost' = (deleteLost \/ (dirtyMap # NoEntry /\ dirtyMap # e /\ ~eDelete[dirtyMap]))
               /\ pc' = [pc EXCEPT ![w] = "release_locks"]
          ELSE \* (already dirty after first change, so this branch not taken)
               /\ pc' = [pc EXCEPT ![w] = "release_locks"]
               /\ UNCHANGED <<eDelete, hasDeletedOnce, deleteLost>>
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, lock, eValObj, eDirty, eProxyFor,
                   objData, objWriters, handle, target, locked1, locked2, activeObj,
                   nilClonePanic, dataRaceOnObj, mutatedBaseObj, mutatedDeleted,
                   changeIfStaleApply, deleteIfStaleDelete>>

\* --- Release held locks and return to idle ---

ReleaseLocks(w) ==
    /\ pc[w] = "release_locks"
    /\ lock' = [e \in EntryIds |-> IF e = locked1[w] \/ e = locked2[w] THEN NoWorker ELSE lock[e]]
    /\ locked1' = [locked1 EXCEPT ![w] = NoEntry]
    /\ locked2' = [locked2 EXCEPT ![w] = NoEntry]
    /\ target' = [target EXCEPT ![w] = NoEntry]
    /\ lockedStep' = [lockedStep EXCEPT ![w] = 0]
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<dirtyMap, nextEntryId, nextObjId, eValObj, eDirty, eDelete, eProxyFor,
                   objData, objWriters, handle, activeObj, nilClonePanic, dataRaceOnObj,
                   mutatedBaseObj, mutatedDeleted, changeIfStaleApply, deleteIfStaleDelete,
                   deleteLost, hasDeletedOnce>>

Next ==
    \E w \in Workers :
        \/ LoadCleanFromBase(w)
        \/ LoadFromDirty(w)
        \/ MapDeleteInsert(w)
        \/ StartChange(w)
        \/ ChangeCheckProxy(w)
        \/ ChangeLockedEnter(w)
        \/ ApplyFinish(w)
        \/ StartChangeIf(w)
        \/ ChangeIfCheck(w)
        \/ ChangeIfEvalCond(w)
        \/ ChangeIfEnterLocked(w)
        \/ StartEntryDelete(w)
        \/ EntryDeleteBody(w)
        \/ StartLockedDoubleChange(w)
        \/ LockedSecondChange(w)
        \/ LockedSecondDelete(w)
        \/ ReleaseLocks(w)

\* --- Invariants ---
NoNilClonePanic     == ~nilClonePanic
NoDataRace          == ~dataRaceOnObj
NoMutateBase        == ~mutatedBaseObj
NoMutateDeleted     == ~mutatedDeleted
NoChangeIfTOCTOU    == ~changeIfStaleApply
NoLostDelete        == ~deleteLost

=============================================================================
