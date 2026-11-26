------------------------- MODULE AutoImportRegistry -------------------------
(*
 * Models two distinct state-machine defects in tsc/internal/ls/autoimport/registry.go
 * and its Session adoption path in tsc/internal/project/session.go:
 *
 * 1. CancelCleanCommit (registry.go:1240-1315, session.go:1311-1351):
 *    buildProjectBucket checks ctx.Err() at entry (line 1247) and guards each
 *    parallel file worker with `if ctx.Err() == nil` (line 1280), but after
 *    wg.Wait() it OMITS `result.err = ctx.Err()` (unlike buildNodeModulesBucket
 *    at line 1712 and updateNodeModulesBucket at line 1832). Consequently, a
 *    mid-extraction cancellation builds a truncated bucket with clean BucketState
 *    (Dirty() == false) and result.err == nil. updateIndexes installs it, and
 *    Session.GetLanguageServiceWithAutoImports (session.go:1320) enqueues
 *    adoptSnapshotChange without checking ctx.Err(), permanently committing the
 *    truncated clean bucket into s.snapshot so future requests never rebuild it.
 *
 * 2. EntrypointClobber (registry.go:1066-1075, 1692-1701, 1789-1823; specifiers.go:38):
 *    Registry.entrypoints is a single registry-wide map keyed only by ResolvedPath,
 *    shared across all node_modules buckets. When two node_modules buckets (B1, B2)
 *    both index a symlinked workspace package resolving to the same realpath P,
 *    and B2 later drops that package (while B1 remains clean and untouched),
 *    rebuilding B2 adds P to removedEntrypointPaths and executes
 *    b.entrypoints.Delete(P) without checking whether B1 still owns P. B1 remains
 *    clean with exports referencing P, but Registry.entrypoints[P] is gone.
 *)

EXTENDS FiniteSets

CONSTANTS
    Mode \* "CancelCleanCommit" or "EntrypointClobber"

ProjectFiles == {"f1", "f2"}
Buckets == {"B1", "B2"}
SharedPath == "shared_pkg_realpath"

VARIABLES
    \* --- CancelCleanCommit state ---
    reqCtxCancelled,    \* BOOLEAN: LSP request context cancelled mid-extraction
    buildPhase,         \* "idle" | "extracting" | "built" | "done"
    extractedFiles,     \* SUBSET ProjectFiles
    builtErr,           \* BOOLEAN (models result.err != nil)
    clonedIndexedFiles, \* SUBSET ProjectFiles (in newSnapshot)
    clonedDirty,        \* BOOLEAN (in newSnapshot)
    sessionIndexedFiles,\* SUBSET ProjectFiles (in s.snapshot)
    sessionDirty,       \* BOOLEAN (in s.snapshot)
    adoptPending,       \* BOOLEAN (adoptSnapshotChange queued on backgroundQueue)

    \* --- EntrypointClobber state ---
    bucketOwnsShared,   \* [Buckets -> BOOLEAN]: whether bucket's live PackageFiles include SharedPath
    bucketDirty,        \* [Buckets -> BOOLEAN]
    entrypointsHasShared,\* BOOLEAN: SharedPath \in DOMAIN registry.entrypoints
    updatePhase         \* "initial" | "b2_dropped" | "rebuilt"

vars == <<reqCtxCancelled, buildPhase, extractedFiles, builtErr,
          clonedIndexedFiles, clonedDirty, sessionIndexedFiles, sessionDirty, adoptPending,
          bucketOwnsShared, bucketDirty, entrypointsHasShared, updatePhase>>

TypeOK ==
    /\ reqCtxCancelled \in BOOLEAN
    /\ buildPhase \in {"idle", "extracting", "built", "done"}
    /\ extractedFiles \subseteq ProjectFiles
    /\ builtErr \in BOOLEAN
    /\ clonedIndexedFiles \subseteq ProjectFiles
    /\ clonedDirty \in BOOLEAN
    /\ sessionIndexedFiles \subseteq ProjectFiles
    /\ sessionDirty \in BOOLEAN
    /\ adoptPending \in BOOLEAN
    /\ bucketOwnsShared \in [Buckets -> BOOLEAN]
    /\ bucketDirty \in [Buckets -> BOOLEAN]
    /\ entrypointsHasShared \in BOOLEAN
    /\ updatePhase \in {"initial", "b2_dropped", "rebuilt"}

Init ==
    /\ reqCtxCancelled = FALSE
    /\ buildPhase = "idle"
    /\ extractedFiles = {}
    /\ builtErr = FALSE
    /\ clonedIndexedFiles = {}
    /\ clonedDirty = TRUE
    /\ sessionIndexedFiles = {}
    /\ sessionDirty = TRUE
    /\ adoptPending = FALSE
    /\ bucketOwnsShared = [b \in Buckets |-> TRUE]
    /\ bucketDirty = [b \in Buckets |-> FALSE]
    /\ entrypointsHasShared = TRUE
    /\ updatePhase = "initial"

\* ============================================================================
\* Mode 1: CancelCleanCommit (buildProjectBucket + GetLanguageServiceWithAutoImports)
\* ============================================================================

\* Entry check passes because ctx is not yet cancelled (registry.go:1247).
StartProjectBucketBuild ==
    /\ Mode = "CancelCleanCommit"
    /\ buildPhase = "idle"
    /\ reqCtxCancelled = FALSE
    /\ buildPhase' = "extracting"
    /\ UNCHANGED <<reqCtxCancelled, extractedFiles, builtErr,
                   clonedIndexedFiles, clonedDirty, sessionIndexedFiles, sessionDirty, adoptPending,
                   bucketOwnsShared, bucketDirty, entrypointsHasShared, updatePhase>>

\* Worker goroutine extracts file f when ctx.Err() == nil (registry.go:1280).
ExtractFile(f) ==
    /\ Mode = "CancelCleanCommit"
    /\ buildPhase = "extracting"
    /\ reqCtxCancelled = FALSE
    /\ f \notin extractedFiles
    /\ extractedFiles' = extractedFiles \cup {f}
    /\ UNCHANGED <<reqCtxCancelled, buildPhase, builtErr,
                   clonedIndexedFiles, clonedDirty, sessionIndexedFiles, sessionDirty, adoptPending,
                   bucketOwnsShared, bucketDirty, entrypointsHasShared, updatePhase>>

\* Client cancels the LSP request context while extraction is in progress.
CancelRequestCtx ==
    /\ Mode = "CancelCleanCommit"
    /\ buildPhase = "extracting"
    /\ reqCtxCancelled = FALSE
    /\ reqCtxCancelled' = TRUE
    /\ UNCHANGED <<buildPhase, extractedFiles, builtErr,
                   clonedIndexedFiles, clonedDirty, sessionIndexedFiles, sessionDirty, adoptPending,
                   bucketOwnsShared, bucketDirty, entrypointsHasShared, updatePhase>>

\* wg.Wait() completes (remaining workers skipped because ctx.Err() != nil).
\* BUG (registry.go:1294-1315): buildProjectBucket NEVER sets result.err = ctx.Err()!
\* So builtErr remains FALSE and result.bucket.state is clean (clonedDirty' = FALSE).
FinishProjectBucketBuild ==
    /\ Mode = "CancelCleanCommit"
    /\ buildPhase = "extracting"
    /\ (extractedFiles = ProjectFiles \/ reqCtxCancelled = TRUE)
    /\ builtErr' = FALSE  \* Missing `result.err = ctx.Err()`!
    /\ clonedIndexedFiles' = extractedFiles
    /\ clonedDirty' = FALSE
    /\ buildPhase' = "built"
    /\ UNCHANGED <<reqCtxCancelled, extractedFiles, sessionIndexedFiles, sessionDirty, adoptPending,
                   bucketOwnsShared, bucketDirty, entrypointsHasShared, updatePhase>>

\* GetLanguageServiceWithAutoImports enqueues adoptSnapshotChange WITHOUT checking ctx.Err()
\* (session.go:1320; contrast warmAutoImportCache at session.go:2143).
EnqueueAdoptWithoutCtxCheck ==
    /\ Mode = "CancelCleanCommit"
    /\ buildPhase = "built"
    /\ adoptPending' = TRUE
    /\ buildPhase' = "done"
    /\ UNCHANGED <<reqCtxCancelled, extractedFiles, builtErr,
                   clonedIndexedFiles, clonedDirty, sessionIndexedFiles, sessionDirty,
                   bucketOwnsShared, bucketDirty, entrypointsHasShared, updatePhase>>

\* backgroundQueue executes adoptSnapshotChange (session.go:1336-1342):
\* promotes newSnapshot to s.snapshot.
AdoptSnapshot ==
    /\ Mode = "CancelCleanCommit"
    /\ adoptPending = TRUE
    /\ sessionIndexedFiles' = clonedIndexedFiles
    /\ sessionDirty' = clonedDirty
    /\ adoptPending' = FALSE
    /\ UNCHANGED <<reqCtxCancelled, buildPhase, extractedFiles, builtErr,
                   clonedIndexedFiles, clonedDirty,
                   bucketOwnsShared, bucketDirty, entrypointsHasShared, updatePhase>>

\* ============================================================================
\* Mode 2: EntrypointClobber (registry.go:1066-1075, 1692-1701)
\* ============================================================================

\* Package.json / node_modules change in B2 marks B2 dirty (B2 no longer has SharedPath);
\* B1 still depends on SharedPath and stays clean.
DropSharedDepInB2 ==
    /\ Mode = "EntrypointClobber"
    /\ updatePhase = "initial"
    /\ bucketDirty' = [bucketDirty EXCEPT !["B2"] = TRUE]
    /\ updatePhase' = "b2_dropped"
    /\ UNCHANGED <<reqCtxCancelled, buildPhase, extractedFiles, builtErr,
                   clonedIndexedFiles, clonedDirty, sessionIndexedFiles, sessionDirty, adoptPending,
                   bucketOwnsShared, entrypointsHasShared>>

\* updateIndexes rebuilds dirty bucket B2:
\* - buildNodeModulesBucket puts SharedPath into B2's removedEntrypointPaths
\*   because SharedPath was in old B2.PackageFiles and in b.base.entrypoints (registry.go:1697).
\* - updateIndexes runs b.entrypoints.Delete(SharedPath) unconditionally (registry.go:1069)
\*   without checking whether untouched bucket B1 still owns SharedPath!
RebuildB2AndApplyEntrypoints ==
    /\ Mode = "EntrypointClobber"
    /\ updatePhase = "b2_dropped"
    /\ bucketDirty["B2"] = TRUE
    /\ bucketOwnsShared' = [bucketOwnsShared EXCEPT !["B2"] = FALSE]
    /\ bucketDirty' = [bucketDirty EXCEPT !["B2"] = FALSE]
    /\ entrypointsHasShared' = FALSE \* BUG: unconditional Delete(SharedPath) clobbers B1!
    /\ updatePhase' = "rebuilt"
    /\ UNCHANGED <<reqCtxCancelled, buildPhase, extractedFiles, builtErr,
                   clonedIndexedFiles, clonedDirty, sessionIndexedFiles, sessionDirty, adoptPending>>

Next ==
    \/ StartProjectBucketBuild
    \/ \E f \in ProjectFiles : ExtractFile(f)
    \/ CancelRequestCtx
    \/ FinishProjectBucketBuild
    \/ EnqueueAdoptWithoutCtxCheck
    \/ AdoptSnapshot
    \/ DropSharedDepInB2
    \/ RebuildB2AndApplyEntrypoints

Spec == Init /\ [][Next]_vars

\* INVARIANT 1 (CancelCleanCommit):
\* If the session's canonical snapshot marks its project auto-import bucket clean
\* (IsPreparedForImportingFile == true), it must contain exports for ALL project files.
CleanSessionBucketIsComplete ==
    (sessionDirty = FALSE) => (sessionIndexedFiles = ProjectFiles)

\* INVARIANT 2 (EntrypointClobber):
\* If any live node_modules bucket still owns exports for SharedPath, the shared
\* Registry.entrypoints map must retain an entry for SharedPath.
LiveBucketExportsHaveEntrypoints ==
    (\E b \in Buckets : bucketOwnsShared[b] = TRUE) => (entrypointsHasShared = TRUE)

=============================================================================
