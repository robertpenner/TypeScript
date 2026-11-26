---------------------- MODULE CompilerFilesParserDepth ----------------------
(***************************************************************************)
(* Formal model of filesParser.start() in                                  *)
(* tsc/internal/compiler/filesparser.go (lines 303-365).                   *)
(*                                                                         *)
(* Inside data.mu.Lock(), lines 339-352 execute:                           *)
(*   currentDepth := core.IfElse(task.increaseDepth, depth+1, depth)       *)
(*   lowered := currentDepth < data.lowestDepth                            *)
(*   if lowered {                                                          *)
(*       data.lowestDepth = currentDepth                                   *)
(*       startSubtasks = true                                              *)
(*       data.startedSubTasks = true                                       *)
(*   }                                                                     *)
(*   if task.elideOnDepth && currentDepth > w.maxDepth {                   *)
(*       return                                                            *)
(*   }                                                                     *)
(*                                                                         *)
(* Because data.lowestDepth and data.startedSubTasks are mutated BEFORE    *)
(* the elideOnDepth early return, an elided task (e.g., a JS import from   *)
(* node_modules at depth > maxNodeModuleJsDepth) poisons shared state:     *)
(*                                                                         *)
(*  1. DropsSubtasks: If an elided task at depth 1 arrives before a        *)
(*     non-elided task at depth >= 1 (e.g., /// <reference path="..."/>),  *)
(*     the elided task sets data.lowestDepth = 1 and returns without       *)
(*     loading. The non-elided task then sees lowered == false, loads the  *)
(*     file (task.loaded = true), and skips w.start(..., subTasks, ...),   *)
(*     silently dropping every transitive import of the loaded file.       *)
(*                                                                         *)
(*  2. PoisonsRestart: If a non-elided task loads at depth 2, then an      *)
(*     elided task at depth 1 arrives before a non-elided task at depth 1, *)
(*     the elided task lowers data.lowestDepth to 1 and returns without    *)
(*     restarting subtasks. The later non-elided task at depth 1 sees      *)
(*     lowered == (1 < 1) == false and never restarts subtasks at depth 1  *)
(*     (re-breaking the invariant that upstream PR #64632 tried to fix).   *)
(***************************************************************************)

EXTENDS Naturals

CONSTANTS
    FixElideOrder,   \* FALSE = current filesparser.go; TRUE = elide check before mutating lowestDepth
    MaxDepth,        \* default maxNodeModuleJsDepth = 0
    Scenario         \* "DropsSubtasks" | "PoisonsRestart"

InfDepth == 99

Tasks ==
    IF Scenario = "DropsSubtasks"
    THEN {"t_elided", "t_keep"}
    ELSE {"t_deep", "t_elided", "t_shallow"}

TaskDepth(t) ==
    CASE t = "t_elided"  -> 1
      [] t = "t_keep"    -> 1
      [] t = "t_deep"    -> 2
      [] t = "t_shallow" -> 1

TaskElide(t) ==
    (t = "t_elided")

MinNonElidedDepth == 1

VARIABLES
    pc,                     \* [Tasks -> {"init", "queued", "done"}]
    dataExists,             \* TRUE after first LoadOrStore creates parseTaskData
    lowestDepth,            \* data.lowestDepth (starts at math.MaxInt = InfDepth)
    dataStartedSubTasks,    \* data.startedSubTasks
    taskLoaded,             \* taskByFileName.loaded
    taskStartedSubTasks,    \* taskByFileName.startedSubTasks
    subtasksStartedAtDepth  \* lowest depth at which w.start(..., subTasks, ...) actually ran

vars == <<pc, dataExists, lowestDepth, dataStartedSubTasks,
          taskLoaded, taskStartedSubTasks, subtasksStartedAtDepth>>

TypeOK ==
    /\ pc \in [Tasks -> {"init", "queued", "done"}]
    /\ dataExists \in BOOLEAN
    /\ lowestDepth \in {0, 1, 2, InfDepth}
    /\ dataStartedSubTasks \in BOOLEAN
    /\ taskLoaded \in BOOLEAN
    /\ taskStartedSubTasks \in BOOLEAN
    /\ subtasksStartedAtDepth \in {0, 1, 2, InfDepth}

Init ==
    /\ pc = [t \in Tasks |-> "init"]
    /\ dataExists = FALSE
    /\ lowestDepth = InfDepth
    /\ dataStartedSubTasks = FALSE
    /\ taskLoaded = FALSE
    /\ taskStartedSubTasks = FALSE
    /\ subtasksStartedAtDepth = InfDepth

\* Step 1: LoadOrStore in w.taskDataByPath and Queue worker closure
QueueTask(t) ==
    /\ pc[t] = "init"
    /\ dataExists' = TRUE
    /\ pc' = [pc EXCEPT ![t] = "queued"]
    /\ UNCHANGED <<lowestDepth, dataStartedSubTasks, taskLoaded,
                   taskStartedSubTasks, subtasksStartedAtDepth>>

\* Step 2: Worker executes closure under data.mu.Lock()
RunTask(t) ==
    /\ pc[t] = "queued"
    /\ LET d     == TaskDepth(t)
           elide == TaskElide(t)
       IN
       IF FixElideOrder /\ elide /\ d > MaxDepth THEN
           \* Fixed: elide BEFORE mutating data.lowestDepth or data.startedSubTasks
           /\ pc' = [pc EXCEPT ![t] = "done"]
           /\ UNCHANGED <<dataExists, lowestDepth, dataStartedSubTasks,
                          taskLoaded, taskStartedSubTasks, subtasksStartedAtDepth>>
       ELSE
           LET lowered == d < lowestDepth
               newLowest == IF lowered THEN d ELSE lowestDepth
               startSubtasks == lowered
               newDataStarted == IF lowered THEN TRUE ELSE dataStartedSubTasks
           IN
           IF (~FixElideOrder) /\ elide /\ d > MaxDepth THEN
               \* Buggy: already mutated lowestDepth & dataStartedSubTasks, now return early
               /\ lowestDepth' = newLowest
               /\ dataStartedSubTasks' = newDataStarted
               /\ pc' = [pc EXCEPT ![t] = "done"]
               /\ UNCHANGED <<dataExists, taskLoaded, taskStartedSubTasks,
                              subtasksStartedAtDepth>>
           ELSE
               \* Non-elided (or within MaxDepth): load file and conditionally start subtasks
               LET doStart == startSubtasks /\ (lowered \/ ~taskStartedSubTasks)
               IN
               /\ lowestDepth' = newLowest
               /\ dataStartedSubTasks' = newDataStarted
               /\ taskLoaded' = TRUE
               /\ taskStartedSubTasks' = IF doStart THEN TRUE ELSE taskStartedSubTasks
               /\ subtasksStartedAtDepth' =
                      IF doStart /\ newLowest < subtasksStartedAtDepth
                      THEN newLowest
                      ELSE subtasksStartedAtDepth
               /\ pc' = [pc EXCEPT ![t] = "done"]
               /\ UNCHANGED dataExists

AllDone == \A t \in Tasks : pc[t] = "done"

Done ==
    /\ AllDone
    /\ UNCHANGED vars

Next ==
    \/ \E t \in Tasks : QueueTask(t) \/ RunTask(t)
    \/ Done

Spec == Init /\ [][Next]_vars

\* --- Safety invariants ---

\* Every loaded file must have had its subtasks started (no silent drop of transitive imports)
LoadedFileStartsSubtasks ==
    (AllDone /\ taskLoaded) =>
        (taskStartedSubTasks /\ subtasksStartedAtDepth < InfDepth)

\* Subtasks must have been started at the true minimum non-elided depth
LowestNonElidedDepthReached ==
    (AllDone /\ taskLoaded) =>
        (subtasksStartedAtDepth = MinNonElidedDepth /\ lowestDepth = MinNonElidedDepth)

AllSafe ==
    /\ LoadedFileStartsSubtasks
    /\ LowestNonElidedDepthReached

=============================================================================
