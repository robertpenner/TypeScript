---------------------- MODULE BuildOrchestratorWatch ----------------------
EXTENDS Integers, Sequences, FiniteSets

\* Faithful model of tsc/internal/execute/build/orchestrator.go + buildtask.go:
\*   - Graph construction: GenerateGraph / GenerateGraphReusingOldTasks
\*     (createBuildTasks resets task.upStream = nil, NEVER resets task.downStream;
\*      setupBuildTask appends downStream to task.downStream on every graph rebuild,
\*      and creates fresh task.built/task.done channels.)
\*   - Watch cycle: DoCycle -> checkTasksForEventChanges -> buildOrCleanOrder
\*     (checkTasksForEventChanges skips `if task.resolved == nil { continue }` BEFORE
\*      recreating task.built and task.done at lines 723-724; buildOrCleanProject
\*      then calls close(t.done) and close(t.built) on every task in order.)
\*
\* Projects:
\*   "A" = upstream valid project (resolved = TRUE)
\*   "B" = downstream valid project depending on "A" (resolved = TRUE)
\*   "M" = sibling project with missing tsconfig (resolved = FALSE)
\*
\* We model 2 watch cycles:
\*   Cycle 1: initial build runs all tasks -> closes done & built channels.
\*   Cycle 2: nondeterministically either:
\*     (a) Source file in B changes (needsUpdate = TRUE, needsConfigUpdate = FALSE), or
\*     (b) Config file of B changes (needsUpdate = TRUE, needsConfigUpdate = TRUE ->
\*         GenerateGraphReusingOldTasks reuses A and replaces B with new task instance).

CONSTANTS
    MaxCycles \* e.g. 2

VARIABLES
    cycle,
    pc,             \* "init_graph" | "build" | "idle" | "check_events" | "regen_graph" | "done"
    \* Task version/generation ids (incremented when a new BuildTask is allocated)
    nextGen,
    taskGen,        \* [{"A", "B", "M"} -> Nat] current live BuildTask id per project
    taskResolved,   \* [{"A", "B", "M"} -> BOOLEAN]
    \* Channel open/closed state for each current task: "open" | "closed"
    doneChan,       \* [{"A", "B", "M"} -> {"open", "closed"}]
    builtChan,      \* [{"A", "B", "M"} -> {"open", "closed"}]
    \* Recorded task.downStream sequence of BuildTask gen ids on project "A"
    aDownStream,    \* Seq(Nat)
    \* Dirty flags and cycle flags
    dirty,          \* SUBSET {"A", "B", "M"}
    needsConfig,    \* BOOLEAN
    needsUpdate,    \* BOOLEAN
    \* Error latch for double-close panic on done/built channel
    doubleClosePanic

vars == <<cycle, pc, nextGen, taskGen, taskResolved, doneChan, builtChan,
          aDownStream, dirty, needsConfig, needsUpdate, doubleClosePanic>>

Projects == {"A", "B", "M"}

Init ==
    /\ cycle = 1
    /\ pc = "init_graph"
    /\ nextGen = 4
    /\ taskGen = [p \in Projects |-> CASE p = "A" -> 1 [] p = "B" -> 2 [] p = "M" -> 3]
    /\ taskResolved = [p \in Projects |-> (p /= "M")]
    /\ doneChan = [p \in Projects |-> "open"]
    /\ builtChan = [p \in Projects |-> "open"]
    /\ aDownStream = <<>>
    /\ dirty = {}
    /\ needsConfig = FALSE
    /\ needsUpdate = FALSE
    /\ doubleClosePanic = FALSE

\* Initial GenerateGraph + setupBuildTask (orchestrator.go:256-278):
\* Creates open built/done channels and appends B's taskGen to A.downStream.
InitGraph ==
    /\ pc = "init_graph"
    /\ doneChan' = [p \in Projects |-> "open"]
    /\ builtChan' = [p \in Projects |-> "open"]
    /\ aDownStream' = Append(aDownStream, taskGen["B"])
    /\ pc' = "build"
    /\ UNCHANGED <<cycle, nextGen, taskGen, taskResolved, dirty, needsConfig, needsUpdate, doubleClosePanic>>

\* buildOrCleanOrder + buildOrCleanProject (orchestrator.go:1005-1058, buildtask.go:113):
\* Runs buildProject on every task in o.order -> defer close(t.done), then close(t.built).
\* Closing an already-closed channel panics in Go!
RunBuild ==
    /\ pc = "build"
    /\ IF \E p \in Projects : doneChan[p] = "closed" \/ builtChan[p] = "closed" THEN
         /\ doubleClosePanic' = TRUE
         /\ pc' = "done"
         /\ UNCHANGED <<doneChan, builtChan>>
       ELSE
         /\ doneChan' = [p \in Projects |-> "closed"]
         /\ builtChan' = [p \in Projects |-> "closed"]
         /\ pc' = IF cycle < MaxCycles THEN "idle" ELSE "done"
         /\ UNCHANGED doubleClosePanic
    /\ UNCHANGED <<cycle, nextGen, taskGen, taskResolved, aDownStream, dirty, needsConfig, needsUpdate>>

\* Watch event arrives: source file in B changes (not a config file)
EventSourceChangeB ==
    /\ pc = "idle"
    /\ cycle' = cycle + 1
    /\ dirty' = {}
    /\ needsConfig' = FALSE
    /\ needsUpdate' = TRUE
    /\ pc' = "check_events"
    /\ UNCHANGED <<nextGen, taskGen, taskResolved, doneChan, builtChan, aDownStream, doubleClosePanic>>

\* Watch event arrives: B's tsconfig.json changes
EventConfigChangeB ==
    /\ pc = "idle"
    /\ cycle' = cycle + 1
    /\ dirty' = {"B"}
    /\ needsConfig' = TRUE
    /\ needsUpdate' = TRUE
    /\ pc' = "check_events"
    /\ UNCHANGED <<nextGen, taskGen, taskResolved, doneChan, builtChan, aDownStream, doubleClosePanic>>

\* checkTasksForEventChanges (orchestrator.go:595-732):
\* For each task in o.order:
\*   - if config changed: mark dirty, continue (relies on GenerateGraphReusingOldTasks)
\*   - if task.resolved == nil: continue (BUG: SKIPS recreating task.built / task.done!)
\*   - otherwise: task.built = make(chan struct{}), task.done = make(chan struct{})
CheckEvents ==
    /\ pc = "check_events"
    /\ IF needsConfig THEN
         /\ pc' = "regen_graph"
         /\ UNCHANGED <<doneChan, builtChan>>
       ELSE
         \* Only tasks with taskResolved[p] = TRUE get fresh channels!
         /\ doneChan' = [p \in Projects |-> IF taskResolved[p] THEN "open" ELSE doneChan[p]]
         /\ builtChan' = [p \in Projects |-> IF taskResolved[p] THEN "open" ELSE builtChan[p]]
         /\ pc' = "build"
    /\ UNCHANGED <<cycle, nextGen, taskGen, taskResolved, aDownStream, dirty, needsConfig, needsUpdate, doubleClosePanic>>

\* GenerateGraphReusingOldTasks (orchestrator.go:190-290):
\*   - createBuildTasks: reuses non-dirty tasks (A, M), allocates new task for dirty B.
\*     Resets task.upStream = nil, DOES NOT reset task.downStream!
\*   - setupBuildTask: recreates built/done for all tasks, appends current B's taskGen to A.downStream!
RegenGraph ==
    /\ pc = "regen_graph"
    /\ LET newB == IF "B" \in dirty THEN nextGen ELSE taskGen["B"] IN
       /\ taskGen' = [taskGen EXCEPT !["B"] = newB]
       /\ nextGen' = IF "B" \in dirty THEN nextGen + 1 ELSE nextGen
       /\ doneChan' = [p \in Projects |-> "open"]
       /\ builtChan' = [p \in Projects |-> "open"]
       /\ aDownStream' = Append(aDownStream, newB)
       /\ dirty' = {}
       /\ needsConfig' = FALSE
       /\ pc' = "build"
    /\ UNCHANGED <<cycle, taskResolved, needsUpdate, doubleClosePanic>>

DoneStutter ==
    /\ pc = "done"
    /\ UNCHANGED vars

Next ==
    \/ InitGraph
    \/ RunBuild
    \/ EventSourceChangeB
    \/ EventConfigChangeB
    \/ CheckEvents
    \/ RegenGraph
    \/ DoneStutter

\* --- Safety Invariants ---

NoChannelDoubleClose == ~doubleClosePanic

\* A's downStream slice should contain only live task generation(s), with no stale replaced tasks or duplicates.
DownstreamNoStaleOrDuplicates ==
    /\ \A i \in 1..Len(aDownStream) : aDownStream[i] = taskGen["B"]
    /\ Len(aDownStream) <= 1

=============================================================================
