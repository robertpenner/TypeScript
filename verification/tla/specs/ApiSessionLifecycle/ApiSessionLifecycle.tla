------------------------ MODULE ApiSessionLifecycle ------------------------
(***************************************************************************)
(* Formal model of api.Session.Close() racing with concurrent IPC handlers *)
(* in tsc/internal/api/session.go (strictly disjoint from Tier 1 #9        *)
(* ApiSessionSnapshot, which modeled only s.snapshots):                    *)
(*                                                                         *)
(*  1. handleGetCurrentLanguageServerSnapshot (lines 1893-1928) vs         *)
(*     Close() -> releaseLanguageServerRefs() (lines 5789-5844):           *)
(*     Close() runs inside s.closeOnce.Do(...) and clears openProjects,    *)
(*     openFiles, and createdPrograms under s.languageServerUpdateMu with  *)
(*     no closed flag. A concurrent handler acquiring the lock afterward   *)
(*     calls s.projectSession.APIUpdate(...) and leaks open projects/files *)
(*     /programs permanently into the live shared LSP project.Session.     *)
(*                                                                         *)
(*  2. registerSourceFileLease() (lines 2339-2345) vs                      *)
(*     Close() -> releaseSourceFileLeases() (lines 2419-2430):             *)
(*     Close() drains s.sourceFileLeases under s.sourceFileLeasesMu with   *)
(*     no closed flag. A concurrent create/retain handler acquiring a      *)
(*     *project.SourceFileLease and registering it afterward permanently   *)
(*     pins the *ast.SourceFile refcount in the shared parseCache.         *)
(*                                                                         *)
(*  3. paginateBatchResponses() (lines 1384-1394) vs                       *)
(*     Close() -> s.batchResponsePages.Clear() (line 5808):                *)
(*     No closed flag prevents a concurrent batch handler from storing     *)
(*     pages into s.batchResponsePages after Close() clears it.            *)
(***************************************************************************)

EXTENDS Naturals

CONSTANTS
    FixGuard,        \* FALSE = current session.go; TRUE = closed flag checked under locks
    EnableLsp,       \* TRUE to model handleGetCurrentLanguageServerSnapshot
    EnableLease,     \* TRUE to model registerSourceFileLease
    EnableBatch      \* TRUE to model paginateBatchResponses

VARIABLES
    closePC,            \* "idle" | "rel_lsp" | "rel_leases" | "clear_batch" | "done"
    closedFlag,         \* explicit closed flag (only used when FixGuard = TRUE)
    lspPC,              \* "idle" | "running" | "done"
    leasePC,            \* "idle" | "acquired" | "done"
    batchPC,            \* "idle" | "done"
    lspServerRefs,      \* open projects/files/programs pinned in shared live project.Session
    localOpenProjects,  \* s.openProjects entries tracked on this api.Session
    parseCacheRefs,     \* *ast.SourceFile lease refcount pinned in shared parseCache
    sessionLeases,      \* entries stored in s.sourceFileLeases
    batchPages          \* entries stored in s.batchResponsePages

vars == <<closePC, closedFlag, lspPC, leasePC, batchPC,
          lspServerRefs, localOpenProjects, parseCacheRefs,
          sessionLeases, batchPages>>

TypeOK ==
    /\ closePC \in {"idle", "rel_lsp", "rel_leases", "clear_batch", "done"}
    /\ closedFlag \in BOOLEAN
    /\ lspPC \in {"idle", "running", "done"}
    /\ leasePC \in {"idle", "acquired", "done"}
    /\ batchPC \in {"idle", "done"}
    /\ lspServerRefs \in 0..2
    /\ localOpenProjects \in 0..2
    /\ parseCacheRefs \in 0..2
    /\ sessionLeases \in 0..2
    /\ batchPages \in 0..2

Init ==
    /\ closePC = "idle"
    /\ closedFlag = FALSE
    /\ lspPC = IF EnableLsp THEN "idle" ELSE "done"
    /\ leasePC = IF EnableLease THEN "idle" ELSE "done"
    /\ batchPC = IF EnableBatch THEN "idle" ELSE "done"
    /\ lspServerRefs = 0
    /\ localOpenProjects = 0
    /\ parseCacheRefs = 0
    /\ sessionLeases = 0
    /\ batchPages = 0

\* --- Session.Close() steps inside s.closeOnce.Do(...) ---

CloseStart ==
    /\ closePC = "idle"
    /\ closePC' = "rel_lsp"
    /\ closedFlag' = IF FixGuard THEN TRUE ELSE closedFlag
    /\ UNCHANGED <<lspPC, leasePC, batchPC,
                   lspServerRefs, localOpenProjects, parseCacheRefs,
                   sessionLeases, batchPages>>

\* releaseLanguageServerRefs(): acquires languageServerUpdateMu, closes tracked refs on projectSession
CloseReleaseLspRefs ==
    /\ closePC = "rel_lsp"
    /\ lspServerRefs' = lspServerRefs - localOpenProjects
    /\ localOpenProjects' = 0
    /\ closePC' = "rel_leases"
    /\ UNCHANGED <<closedFlag, lspPC, leasePC, batchPC,
                   parseCacheRefs, sessionLeases, batchPages>>

\* releaseSourceFileLeases(): acquires sourceFileLeasesMu, releases all leases in sourceFileLeases
CloseReleaseLeases ==
    /\ closePC = "rel_leases"
    /\ parseCacheRefs' = parseCacheRefs - sessionLeases
    /\ sessionLeases' = 0
    /\ closePC' = "clear_batch"
    /\ UNCHANGED <<closedFlag, lspPC, leasePC, batchPC,
                   lspServerRefs, localOpenProjects, batchPages>>

\* s.batchResponsePages.Clear()
CloseClearBatch ==
    /\ closePC = "clear_batch"
    /\ batchPages' = 0
    /\ closePC' = "done"
    /\ UNCHANGED <<closedFlag, lspPC, leasePC, batchPC,
                   lspServerRefs, localOpenProjects, parseCacheRefs,
                   sessionLeases>>

\* --- Concurrent IPC handler 1: handleGetCurrentLanguageServerSnapshot ---

LspHandlerBegin ==
    /\ lspPC = "idle"
    /\ lspPC' = "running"
    /\ UNCHANGED <<closePC, closedFlag, leasePC, batchPC,
                   lspServerRefs, localOpenProjects, parseCacheRefs,
                   sessionLeases, batchPages>>

\* Acquires languageServerUpdateMu, calls projectSession.APIUpdate, commits openProjects
LspHandlerApply ==
    /\ lspPC = "running"
    /\ IF FixGuard /\ closedFlag THEN
           \* Fixed: check closed under languageServerUpdateMu before calling APIUpdate
           /\ UNCHANGED <<lspServerRefs, localOpenProjects>>
       ELSE
           /\ lspServerRefs' = lspServerRefs + 1
           /\ localOpenProjects' = localOpenProjects + 1
    /\ lspPC' = "done"
    /\ UNCHANGED <<closePC, closedFlag, leasePC, batchPC,
                   parseCacheRefs, sessionLeases, batchPages>>

\* --- Concurrent IPC handler 2: handleCreateSourceFile / registerSourceFileLease ---

\* Acquires *project.SourceFileLease from snapshotHost / parseCache before taking sourceFileLeasesMu
LeaseHandlerAcquire ==
    /\ leasePC = "idle"
    /\ parseCacheRefs' = parseCacheRefs + 1
    /\ leasePC' = "acquired"
    /\ UNCHANGED <<closePC, closedFlag, lspPC, batchPC,
                   lspServerRefs, localOpenProjects, sessionLeases, batchPages>>

\* registerSourceFileLease(): acquires sourceFileLeasesMu and stores lease
LeaseHandlerRegister ==
    /\ leasePC = "acquired"
    /\ IF FixGuard /\ closedFlag THEN
           \* Fixed: session already closed under sourceFileLeasesMu -> release lease immediately
           /\ parseCacheRefs' = parseCacheRefs - 1
           /\ UNCHANGED sessionLeases
       ELSE
           /\ sessionLeases' = sessionLeases + 1
           /\ UNCHANGED parseCacheRefs
    /\ leasePC' = "done"
    /\ UNCHANGED <<closePC, closedFlag, lspPC, batchPC,
                   lspServerRefs, localOpenProjects, batchPages>>

\* --- Concurrent IPC handler 3: handleBatchRequests -> paginateBatchResponses ---

BatchHandlerStore ==
    /\ batchPC = "idle"
    /\ IF FixGuard /\ closedFlag THEN
           /\ UNCHANGED batchPages
       ELSE
           /\ batchPages' = batchPages + 1
    /\ batchPC' = "done"
    /\ UNCHANGED <<closePC, closedFlag, lspPC, leasePC,
                   lspServerRefs, localOpenProjects, parseCacheRefs,
                   sessionLeases>>

Done ==
    /\ closePC = "done"
    /\ lspPC = "done"
    /\ leasePC = "done"
    /\ batchPC = "done"
    /\ UNCHANGED vars

Next ==
    \/ CloseStart
    \/ CloseReleaseLspRefs
    \/ CloseReleaseLeases
    \/ CloseClearBatch
    \/ LspHandlerBegin
    \/ LspHandlerApply
    \/ LeaseHandlerAcquire
    \/ LeaseHandlerRegister
    \/ BatchHandlerStore
    \/ Done

Spec == Init /\ [][Next]_vars

\* --- Safety invariants ---

NoPostCloseLspRefLeak ==
    (closePC = "done" /\ lspPC = "done") =>
        (lspServerRefs = 0 /\ localOpenProjects = 0)

NoPostCloseLeaseLeak ==
    (closePC = "done" /\ leasePC = "done") =>
        (parseCacheRefs = 0 /\ sessionLeases = 0)

NoPostCloseBatchPageLeak ==
    (closePC = "done" /\ batchPC = "done") =>
        (batchPages = 0)

AllSafe ==
    /\ NoPostCloseLspRefLeak
    /\ NoPostCloseLeaseLeak
    /\ NoPostCloseBatchPageLeak

=============================================================================
