---------------------- MODULE ExtendedConfigDeadlock ----------------------
EXTENDS Integers, Sequences, FiniteSets

\* Faithful model of ExtendedConfigCache (tsc/internal/execute/tsc/extendedconfigcache.go
\* AND tsc/internal/project/ownercache.go + project/extendedconfigcache.go)
\* combined with tsoptions.ParseExtendedConfig's single-goroutine resolutionStack check
\* (tsc/internal/tsoptions/tsconfigparsing.go).
\*
\* Two config files A and B form a cycle: A extends B, B extends A.
\* Worker 1 parses A (starting with stack = <<>>); Worker 2 parses B (starting with stack = <<>>).

CONSTANTS
    Workers \* e.g. {"w1", "w2"}

Files == {"A", "B"}
NoWorker == "NONE"

Extends(f) == IF f = "A" THEN "B" ELSE "A"

VARIABLES
    \* Per-file cache entry state (collections.SyncMap + per-entry sync.Mutex)
    inMap,   \* [Files -> BOOLEAN]
    lock,    \* [Files -> Workers \cup {NoWorker}]
    parsed,  \* [Files -> BOOLEAN]
    \* Per-worker state
    pc,      \* [Workers -> "init" | "need_child" | "done"]
    root,    \* [Workers -> Files] (w1 starts at A, w2 starts at B)
    stack,   \* [Workers -> SUBSET Files] (resolutionStack passed to ParseExtendedConfig)
    holding  \* [Workers -> SUBSET Files] (locks currently held by worker)

vars == <<inMap, lock, parsed, pc, root, stack, holding>>

Init ==
    /\ inMap = [f \in Files |-> FALSE]
    /\ lock = [f \in Files |-> NoWorker]
    /\ parsed = [f \in Files |-> FALSE]
    /\ pc = [w \in Workers |-> "init"]
    /\ root = [w \in Workers |-> IF w = "w1" THEN "A" ELSE "B"]
    /\ stack = [w \in Workers |-> {}]
    /\ holding = [w \in Workers |-> {}]

\* Step 1: Worker calls GetExtendedConfig(root[w], stack={}) -> locks entry[root[w]].mu
LockRoot(w) ==
    /\ pc[w] = "init"
    /\ LET f == root[w] IN
       /\ lock[f] = NoWorker
       /\ inMap' = [inMap EXCEPT ![f] = TRUE]
       /\ IF parsed[f]
          THEN \* Cache hit: unlock immediately and done
               /\ pc' = [pc EXCEPT ![w] = "done"]
               /\ UNCHANGED <<lock, stack, holding>>
          ELSE \* Cache miss: hold lock[f], enter ParseExtendedConfig(f, stack \cup {f})
               /\ lock' = [lock EXCEPT ![f] = w]
               /\ stack' = [stack EXCEPT ![w] = stack[w] \cup {f}]
               /\ holding' = [holding EXCEPT ![w] = holding[w] \cup {f}]
               /\ pc' = [pc EXCEPT ![w] = "need_child"]
    /\ UNCHANGED <<parsed, root>>

\* Step 2: Inside ParseExtendedConfig(f), resolves child = Extends(f).
\* Checks !slices.Contains(resolutionStack, child) -> TRUE because child \notin {f}!
\* Calls cache.GetExtendedConfig(child) -> tries to acquire lock[child].mu WHILE STILL HOLDING lock[f].mu!
ResolveChild(w) ==
    /\ pc[w] = "need_child"
    /\ LET f == root[w]
           child == Extends(f)
       IN
       IF child \in stack[w]
       THEN \* Cycle caught by single-goroutine stack check -> bypass cache, finish
            /\ parsed' = [parsed EXCEPT ![f] = TRUE]
            /\ lock' = [lock EXCEPT ![f] = NoWorker]
            /\ holding' = [holding EXCEPT ![w] = holding[w] \ {f}]
            /\ pc' = [pc EXCEPT ![w] = "done"]
            /\ UNCHANGED <<inMap, stack>>
       ELSE \* Not in this goroutine's stack -> calls cache.GetExtendedConfig(child)!
            /\ lock[child] = NoWorker
            /\ inMap' = [inMap EXCEPT ![child] = TRUE]
            \* Once lock[child] is acquired, child's recursion sees f \in stack \cup {child},
            \* breaks cycle, finishes child, unlocks child, finishes f, unlocks f!
            /\ parsed' = [parsed EXCEPT ![child] = TRUE, ![f] = TRUE]
            /\ lock' = [lock EXCEPT ![f] = NoWorker]
            /\ holding' = [holding EXCEPT ![w] = {}]
            /\ pc' = [pc EXCEPT ![w] = "done"]
            /\ UNCHANGED stack
    /\ UNCHANGED root

\* Allow stuttering only when ALL workers are done (so real AB-BA deadlock is caught by TLC!)
AllDone ==
    /\ \A w \in Workers : pc[w] = "done"
    /\ UNCHANGED vars

Next ==
    \/ \E w \in Workers : LockRoot(w) \/ ResolveChild(w)
    \/ AllDone

=============================================================================
