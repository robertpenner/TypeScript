---- MODULE LspServerLifecycle ----
EXTENDS Naturals

(*
 * Models LSP Server initialization, request dispatch, and shutdown lifecycle in:
 *   tsc/internal/lsp/server.go:949-969 (readLoop)
 *   tsc/internal/lsp/server.go:1007-1057 (dispatchLoop)
 *   tsc/internal/lsp/server.go:1381-1495 (handler registrars)
 *   tsc/internal/lsp/server.go:1555-1887 (handleInitialize/handleInitialized/handleShutdown)
 *   tsc/internal/project/session.go:1084-1145, 1711-1734 (Session.getSnapshot / Close)
 *
 * Three defects modeled from the exact code paths:
 *   1. Pre-initialized nil-session panic (InvNoPreInitNilSessionPanic):
 *      After `initialize` sets `initializeParams != nil`, readLoop enqueues all
 *      subsequent requests. Document handlers registered via
 *      registerLanguageServiceDocumentRequestHandler / WithAutoImports /
 *      MultiProjectReference omit the `if s.session == nil` guard and call
 *      `s.session.GetLanguageService(...)` directly on dispatchLoop (outside
 *      the async `defer s.recover`).
 *   2. Post-shutdown / concurrent-shutdown nil-snapshot panic (InvNoPostShutdownNilSnapshotPanic):
 *      handleShutdown calls s.session.Close() (setting s.session.snapshot = nil)
 *      without setting a shutdown flag to reject subsequent requests with
 *      InvalidRequest, and without cancelling/draining in-flight async request
 *      goroutines that call back into s.session (GetProjectsForFile /
 *      WithSnapshotLoadingProjectTree / GetLanguageServiceWithAutoImports).
 *   3. Duplicate `initialized` close-of-closed-channel panic (InvNoDuplicateInitializedPanic):
 *      handleInitialized unconditionally calls close(s.initComplete) and
 *      overwrites s.session without checking whether initialization already ran.
 *)

VARIABLES
    initParamsSet,       \* s.initializeParams != nil
    sessionState,        \* "nil" | "open" | "closed" (snapshot == nil when closed)
    initCompleteClosed,  \* close(s.initComplete) has executed
    asyncInFlight,       \* Number of in-flight async request goroutines spawned by dispatchLoop
    preInitPanic,        \* Sticky: document handler dereferenced nil s.session
    postShutdownPanic,   \* Sticky: handler or async worker dereferenced nil s.session.snapshot
    dupInitPanic         \* Sticky: handleInitialized closed already-closed s.initComplete

vars == <<initParamsSet, sessionState, initCompleteClosed, asyncInFlight,
          preInitPanic, postShutdownPanic, dupInitPanic>>

TypeOK ==
    /\ initParamsSet \in BOOLEAN
    /\ sessionState \in {"nil", "open", "closed"}
    /\ initCompleteClosed \in BOOLEAN
    /\ asyncInFlight \in 0..1
    /\ preInitPanic \in BOOLEAN
    /\ postShutdownPanic \in BOOLEAN
    /\ dupInitPanic \in BOOLEAN

Init ==
    /\ initParamsSet = FALSE
    /\ sessionState = "nil"
    /\ initCompleteClosed = FALSE
    /\ asyncInFlight = 0
    /\ preInitPanic = FALSE
    /\ postShutdownPanic = FALSE
    /\ dupInitPanic = FALSE

\* readLoop synchronously handles `initialize` (server.go:949-969)
HandleInitialize ==
    /\ ~initParamsSet
    /\ initParamsSet' = TRUE
    /\ UNCHANGED <<sessionState, initCompleteClosed, asyncInFlight,
                   preInitPanic, postShutdownPanic, dupInitPanic>>

\* dispatchLoop runs `handleInitialized` (server.go:1752-1878)
\* Creates s.session = project.NewSession(...) and executes close(s.initComplete)
HandleInitialized ==
    /\ initParamsSet
    /\ IF initCompleteClosed
       THEN /\ dupInitPanic' = TRUE
            /\ sessionState' = "open"
            /\ UNCHANGED <<initParamsSet, initCompleteClosed, asyncInFlight,
                           preInitPanic, postShutdownPanic>>
       ELSE /\ sessionState' = "open"
            /\ initCompleteClosed' = TRUE
            /\ UNCHANGED <<initParamsSet, asyncInFlight,
                           preInitPanic, postShutdownPanic, dupInitPanic>>

\* dispatchLoop runs a document request (e.g. textDocument/hover, references, completion)
\* Missing `s.session == nil` guard and missing post-shutdown InvalidRequest guard
DispatchDocumentRequest ==
    /\ initParamsSet
    /\ asyncInFlight = 0
    /\ IF sessionState = "nil"
       THEN /\ preInitPanic' = TRUE
            /\ UNCHANGED <<initParamsSet, sessionState, initCompleteClosed, asyncInFlight,
                           postShutdownPanic, dupInitPanic>>
       ELSE IF sessionState = "closed"
       THEN /\ postShutdownPanic' = TRUE
            /\ UNCHANGED <<initParamsSet, sessionState, initCompleteClosed, asyncInFlight,
                           preInitPanic, dupInitPanic>>
       ELSE /\ asyncInFlight' = 1
            /\ UNCHANGED <<initParamsSet, sessionState, initCompleteClosed,
                           preInitPanic, postShutdownPanic, dupInitPanic>>

\* In-flight async goroutine calls back into s.session (e.g. GetProjectsForFile /
\* GetLanguageServiceWithAutoImports) or finishes normally
AsyncWorkerAccessSession ==
    /\ asyncInFlight = 1
    /\ asyncInFlight' = 0
    /\ IF sessionState = "closed"
       THEN postShutdownPanic' = TRUE
       ELSE UNCHANGED postShutdownPanic
    /\ UNCHANGED <<initParamsSet, sessionState, initCompleteClosed, preInitPanic, dupInitPanic>>

\* dispatchLoop runs `handleShutdown` (server.go:1881-1887):
\* Calls s.session.Close() immediately without waiting for asyncInFlight or rejecting future requests
HandleShutdown ==
    /\ initParamsSet
    /\ sessionState = "open"
    /\ sessionState' = "closed"
    /\ UNCHANGED <<initParamsSet, initCompleteClosed, asyncInFlight,
                   preInitPanic, postShutdownPanic, dupInitPanic>>

Next ==
    \/ HandleInitialize
    \/ HandleInitialized
    \/ DispatchDocumentRequest
    \/ AsyncWorkerAccessSession
    \/ HandleShutdown

Spec == Init /\ [][Next]_vars

InvNoPreInitNilSessionPanic      == ~preInitPanic
InvNoPostShutdownNilSnapshotPanic == ~postShutdownPanic
InvNoDuplicateInitializedPanic   == ~dupInitPanic
====
