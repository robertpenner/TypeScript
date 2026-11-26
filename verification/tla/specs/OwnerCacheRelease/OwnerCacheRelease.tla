------------------------- MODULE OwnerCacheRelease -------------------------
(*
 * Models tsc/internal/project/ownercache.go:42-112 and
 * tsc/internal/project/snapshot.go:728-735, 797-804.
 *
 * Snapshot.dispose iterates every config in ConfigFileRegistry.configs and
 * calls extendedConfigCache.Release(extFile, s.id) for each ExtendedSourceFile.
 * When >=2 configs in a snapshot extend the same base tsconfig K, S1.dispose
 * calls Release(K, S1) twice.
 *
 * OwnerCache.Release loads entry from c.entries, locks entry.mu, deletes owner,
 * and if len(entry.owners) == 0 calls c.entries.Delete(identity) blindly
 * (not CompareAndDelete and without checking whether owner was in entry.owners).
 *
 * Interleaving:
 *   1. E1 starts with owners {S1, S2}.
 *   2. S1's 1st Release(K, S1) removes S1 from E1 (owners = {S2}).
 *   3. S1's 2nd Release(K, S1) loads E1 and pauses before E1.mu.Lock().
 *   4. S2.dispose calls Release(K, S2), empties E1, and deletes K from c.entries.
 *   5. S3 calls LoadAndAcquire(K, S3), inserting live entry E2 (owners = {S3}).
 *   6. S1's 2nd Release locks E1, sees len(E1.owners) == 0, and calls
 *      c.entries.Delete(K), evicting live E2.
 *   7. S3.Clone() calls AddOwner(K, S4) -> panic("OwnerCache.AddOwner: entry not found").
 *)
EXTENDS Naturals, FiniteSets

VARIABLES
    mapEntry,      \* 0 = absent, 1 = E1, 2 = E2
    nextEntry,     \* next entry id to allocate
    entryOwners,   \* [1..2 -> SUBSET {1, 2, 3, 4}]
    s1pc,          \* "rel1_load", "rel1_lock", "rel2_load", "rel2_lock", "done"
    s1Loaded,      \* entry id loaded by S1 before locking
    s2pc,          \* "rel_load", "rel_lock", "done"
    s2Loaded,      \* entry id loaded by S2 before locking
    s3pc           \* "idle", "add_owner", "done", "panicked"

vars == <<mapEntry, nextEntry, entryOwners, s1pc, s1Loaded, s2pc, s2Loaded, s3pc>>

Init ==
    /\ mapEntry = 1
    /\ nextEntry = 2
    /\ entryOwners = [e \in 1..2 |-> IF e = 1 THEN {1, 2} ELSE {}]
    /\ s1pc = "rel1_load"
    /\ s1Loaded = 0
    /\ s2pc = "rel_load"
    /\ s2Loaded = 0
    /\ s3pc = "idle"

\* S1.dispose: 1st config extending K calls Release(K, 1)
S1Rel1Load ==
    /\ s1pc = "rel1_load"
    /\ IF mapEntry = 0
       THEN /\ s1pc' = "rel2_load"
            /\ s1Loaded' = 0
       ELSE /\ s1pc' = "rel1_lock"
            /\ s1Loaded' = mapEntry
    /\ UNCHANGED <<mapEntry, nextEntry, entryOwners, s2pc, s2Loaded, s3pc>>

S1Rel1LockAndDelete ==
    /\ s1pc = "rel1_lock"
    /\ LET newOwners == entryOwners[s1Loaded] \ {1}
       IN /\ entryOwners' = [entryOwners EXCEPT ![s1Loaded] = newOwners]
          /\ mapEntry' = IF newOwners = {} THEN 0 ELSE mapEntry
    /\ s1pc' = "rel2_load"
    /\ s1Loaded' = 0
    /\ UNCHANGED <<nextEntry, s2pc, s2Loaded, s3pc>>

\* S1.dispose: 2nd config extending K calls Release(K, 1)
S1Rel2Load ==
    /\ s1pc = "rel2_load"
    /\ IF mapEntry = 0
       THEN /\ s1pc' = "done"
            /\ s1Loaded' = 0
       ELSE /\ s1pc' = "rel2_lock"
            /\ s1Loaded' = mapEntry
    /\ UNCHANGED <<mapEntry, nextEntry, entryOwners, s2pc, s2Loaded, s3pc>>

S1Rel2LockAndDelete ==
    /\ s1pc = "rel2_lock"
    /\ LET newOwners == entryOwners[s1Loaded] \ {1}
       IN /\ entryOwners' = [entryOwners EXCEPT ![s1Loaded] = newOwners]
          \* Bug: unconditional c.entries.Delete(identity) regardless of mapEntry
          /\ mapEntry' = IF newOwners = {} THEN 0 ELSE mapEntry
    /\ s1pc' = "done"
    /\ s1Loaded' = 0
    /\ UNCHANGED <<nextEntry, s2pc, s2Loaded, s3pc>>

\* S2.dispose: Release(K, 2)
S2RelLoad ==
    /\ s2pc = "rel_load"
    /\ IF mapEntry = 0
       THEN /\ s2pc' = "done"
            /\ s2Loaded' = 0
       ELSE /\ s2pc' = "rel_lock"
            /\ s2Loaded' = mapEntry
    /\ UNCHANGED <<mapEntry, nextEntry, entryOwners, s1pc, s1Loaded, s3pc>>

S2RelLockAndDelete ==
    /\ s2pc = "rel_lock"
    /\ LET newOwners == entryOwners[s2Loaded] \ {2}
       IN /\ entryOwners' = [entryOwners EXCEPT ![s2Loaded] = newOwners]
          /\ mapEntry' = IF newOwners = {} THEN 0 ELSE mapEntry
    /\ s2pc' = "done"
    /\ s2Loaded' = 0
    /\ UNCHANGED <<nextEntry, s1pc, s1Loaded, s3pc>>

\* S3: LoadAndAcquire(K, 3) when K is absent from c.entries
S3LoadAndAcquire ==
    /\ s3pc = "idle"
    /\ mapEntry = 0
    /\ nextEntry = 2
    /\ mapEntry' = 2
    /\ nextEntry' = 3
    /\ entryOwners' = [entryOwners EXCEPT ![2] = {3}]
    /\ s3pc' = "add_owner"
    /\ UNCHANGED <<s1pc, s1Loaded, s2pc, s2Loaded>>

\* S3.Clone() -> S4 calls AddOwner(K, 4) while S3 is live
S3CloneAddOwner ==
    /\ s3pc = "add_owner"
    /\ IF mapEntry = 0 \/ entryOwners[mapEntry] = {}
       THEN /\ s3pc' = "panicked"
            /\ UNCHANGED entryOwners
       ELSE /\ entryOwners' = [entryOwners EXCEPT ![mapEntry] = @ \cup {4}]
            /\ s3pc' = "done"
    /\ UNCHANGED <<mapEntry, nextEntry, s1pc, s1Loaded, s2pc, s2Loaded>>

Terminated ==
    /\ s1pc = "done"
    /\ s2pc = "done"
    /\ s3pc \in {"done", "panicked"}

Stutter == Terminated /\ UNCHANGED vars

Next ==
    \/ S1Rel1Load
    \/ S1Rel1LockAndDelete
    \/ S1Rel2Load
    \/ S1Rel2LockAndDelete
    \/ S2RelLoad
    \/ S2RelLockAndDelete
    \/ S3LoadAndAcquire
    \/ S3CloneAddOwner
    \/ Stutter

Spec == Init /\ [][Next]_vars

InvNoAddOwnerPanic == s3pc # "panicked"
=============================================================================
