--------------------------- MODULE CheckerPool ---------------------------
EXTENDS Integers, FiniteSets

\* Faithful synchronization model of tsc/internal/project/checkerpool.go
\* MaxCheckers = 3 (slot 0 = diagnostics, slots 1..2 = query)

CONSTANTS
    Workers,     \* e.g. {"w1", "w2", "w3"}
    Reqs,        \* e.g. {"r1", "r2"}
    Files        \* e.g. {"f1", "f2"}

Slots == {0, 1, 2}
QuerySlots == {1, 2}
NoWorker == "NONE"
NoReq == "NOREQ"
NoFile == "NOFILE"
NoSlot == -1
NoChecker == 0

VARIABLES
    mu,                 \* NoWorker or Workers or "TIMER" or "CTX"
    discarded,          \* BOOLEAN
    checkers,           \* [Slots -> 0..MaxCheckersCreated] (checker ID, 0 = nil)
    nextCheckerId,      \* monotonic checker ID
    heldBy,             \* [Slots -> Reqs \cup {"<anon>", ""}]
    checkerCanceled,    \* [Slots -> BOOLEAN] whether checker in slot was canceled during use
    fileAssoc,          \* [Files -> Slots \cup {NoSlot}]
    reqAssoc,           \* [Reqs -> Slots \cup {NoSlot}]
    lastReleased,       \* [Slots -> 0..MaxTime] (0 = zero time)
    now,                \* discrete clock 1..MaxTime
    timerScheduled,     \* BOOLEAN (cleanupTimer != nil)
    timerArmed,         \* BOOLEAN (timer will fire)
    timerInFlight,      \* BOOLEAN (a timer callback goroutine has fired and is waiting for mu)
    ctxDone,            \* [Reqs -> BOOLEAN]
    ctxCleanupPending,  \* [Reqs -> 0..2] pending context.AfterFunc callbacks
    diagSem,            \* 0..1 tokens held
    querySem,           \* 0..2 tokens held
    \* Per-worker state
    pc,                 \* [Workers -> PCs]
    wKind,              \* [Workers -> {"none", "diag", "query"}]
    wReq,               \* [Workers -> Reqs \cup {NoReq}]
    wFile,              \* [Workers -> Files \cup {NoFile}]
    wSlot,              \* [Workers -> Slots \cup {NoSlot}]
    wCheckerId,         \* [Workers -> 0..10]
    \* Ghost / bug detection flags
    doubleUseChecker,   \* TRUE if two workers concurrently hold the same slot or same checker ID
    noSlotPanic,        \* TRUE if findOrCreateQueryCheckerLocked panics
    disposeMismatch,    \* TRUE if debug.Assert(p.checkers[index] == c) fails
    timerLeakAfterDiscard, \* TRUE if timer becomes armed AFTER Discard() completed
    semUnderflow,       \* TRUE if semaphore count goes negative
    reusedCanceled      \* TRUE if a worker acquires a canceled checker

MaxTime == 2
IdleTimeout == 1
MaxCheckerIds == 3

vars == <<mu, discarded, checkers, nextCheckerId, heldBy, checkerCanceled, fileAssoc, reqAssoc,
          lastReleased, now, timerScheduled, timerArmed, timerInFlight, ctxDone,
          ctxCleanupPending, diagSem, querySem, pc, wKind, wReq, wFile, wSlot, wCheckerId,
          doubleUseChecker, noSlotPanic, disposeMismatch, timerLeakAfterDiscard,
          semUnderflow, reusedCanceled>>

HoldTag(r) == IF r = NoReq THEN "<anon>" ELSE r

Init ==
    /\ mu = NoWorker
    /\ discarded = FALSE
    /\ checkers = [s \in Slots |-> NoChecker]
    /\ nextCheckerId = 1
    /\ heldBy = [s \in Slots |-> ""]
    /\ checkerCanceled = [s \in Slots |-> FALSE]
    /\ fileAssoc = [f \in Files |-> NoSlot]
    /\ reqAssoc = [r \in Reqs |-> NoSlot]
    /\ lastReleased = [s \in Slots |-> 0]
    /\ now = 1
    /\ timerScheduled = FALSE
    /\ timerArmed = FALSE
    /\ timerInFlight = FALSE
    /\ ctxDone = [r \in Reqs |-> FALSE]
    /\ ctxCleanupPending = [r \in Reqs |-> 0]
    /\ diagSem = 0
    /\ querySem = 0
    /\ pc = [w \in Workers |-> "idle"]
    /\ wKind = [w \in Workers |-> "none"]
    /\ wReq = [w \in Workers |-> NoReq]
    /\ wFile = [w \in Workers |-> NoFile]
    /\ wSlot = [w \in Workers |-> NoSlot]
    /\ wCheckerId = [w \in Workers |-> NoChecker]
    /\ doubleUseChecker = FALSE
    /\ noSlotPanic = FALSE
    /\ disposeMismatch = FALSE
    /\ timerLeakAfterDiscard = FALSE
    /\ semUnderflow = FALSE
    /\ reusedCanceled = FALSE

\* Helper: scheduleCleanupLocked effect on timerScheduled/timerArmed
HasIdleChecker(chks, held, lrel) ==
    \E s \in Slots : chks[s] # NoChecker /\ held[s] = "" /\ lrel[s] # 0

\* --- Worker calls GetChecker ---

StartGetDiag(w, r) ==
    /\ pc[w] = "idle"
    /\ diagSem < 1
    /\ diagSem' = diagSem + 1
    /\ wKind' = [wKind EXCEPT ![w] = "diag"]
    /\ wReq' = [wReq EXCEPT ![w] = r]
    /\ wFile' = [wFile EXCEPT ![w] = NoFile]
    /\ pc' = [pc EXCEPT ![w] = IF r = NoReq THEN "acquire_normal" ELSE "try_reacquire"]
    /\ UNCHANGED <<mu, discarded, checkers, nextCheckerId, heldBy, checkerCanceled, fileAssoc,
                   reqAssoc, lastReleased, now, timerScheduled, timerArmed, timerInFlight,
                   ctxDone, ctxCleanupPending, querySem, wSlot, wCheckerId, doubleUseChecker,
                   noSlotPanic, disposeMismatch, timerLeakAfterDiscard, semUnderflow, reusedCanceled>>

StartGetQuery(w, r, f) ==
    /\ pc[w] = "idle"
    /\ querySem < 2
    /\ querySem' = querySem + 1
    /\ wKind' = [wKind EXCEPT ![w] = "query"]
    /\ wReq' = [wReq EXCEPT ![w] = r]
    /\ wFile' = [wFile EXCEPT ![w] = f]
    /\ pc' = [pc EXCEPT ![w] = IF r = NoReq THEN "acquire_normal" ELSE "try_reacquire"]
    /\ UNCHANGED <<mu, discarded, checkers, nextCheckerId, heldBy, checkerCanceled, fileAssoc,
                   reqAssoc, lastReleased, now, timerScheduled, timerArmed, timerInFlight,
                   ctxDone, ctxCleanupPending, diagSem, wSlot, wCheckerId, doubleUseChecker,
                   noSlotPanic, disposeMismatch, timerLeakAfterDiscard, semUnderflow, reusedCanceled>>

\* tryReacquireForRequest (acquires & releases p.mu atomically)
TryReacquire(w) ==
    /\ pc[w] = "try_reacquire"
    /\ mu = NoWorker
    /\ LET r == wReq[w]
           isDiag == (wKind[w] = "diag")
           idx == reqAssoc[r]
       IN
       IF idx = NoSlot
       THEN /\ pc' = [pc EXCEPT ![w] = "acquire_normal"]
            /\ UNCHANGED <<reqAssoc, heldBy, wSlot, wCheckerId, doubleUseChecker, reusedCanceled>>
       ELSE IF (isDiag /\ idx # 0) \/ (~isDiag /\ idx = 0)
       THEN /\ reqAssoc' = [reqAssoc EXCEPT ![r] = NoSlot]
            /\ pc' = [pc EXCEPT ![w] = "acquire_normal"]
            /\ UNCHANGED <<heldBy, wSlot, wCheckerId, doubleUseChecker, reusedCanceled>>
       ELSE IF checkers[idx] = NoChecker
       THEN /\ reqAssoc' = [reqAssoc EXCEPT ![r] = NoSlot]
            /\ pc' = [pc EXCEPT ![w] = "acquire_normal"]
            /\ UNCHANGED <<heldBy, wSlot, wCheckerId, doubleUseChecker, reusedCanceled>>
       ELSE IF heldBy[idx] = ""
       THEN /\ heldBy' = [heldBy EXCEPT ![idx] = r]
            /\ wSlot' = [wSlot EXCEPT ![w] = idx]
            /\ wCheckerId' = [wCheckerId EXCEPT ![w] = checkers[idx]]
            /\ doubleUseChecker' = (doubleUseChecker \/ (\E u \in Workers : u # w /\ pc[u] = "holding" /\ wSlot[u] = idx))
            /\ reusedCanceled' = (reusedCanceled \/ checkerCanceled[idx])
            /\ pc' = [pc EXCEPT ![w] = "holding"]
            /\ UNCHANGED reqAssoc
       ELSE /\ pc' = [pc EXCEPT ![w] = "acquire_normal"]
            /\ UNCHANGED <<reqAssoc, heldBy, wSlot, wCheckerId, doubleUseChecker, reusedCanceled>>
    /\ UNCHANGED <<mu, discarded, checkers, nextCheckerId, checkerCanceled, fileAssoc,
                   lastReleased, now, timerScheduled, timerArmed, timerInFlight, ctxDone,
                   ctxCleanupPending, diagSem, querySem, wKind, wReq, wFile, noSlotPanic,
                   disposeMismatch, timerLeakAfterDiscard, semUnderflow>>

\* Normal acquisition under p.mu (diagnostics)
AcquireDiagNormal(w) ==
    /\ pc[w] = "acquire_normal"
    /\ wKind[w] = "diag"
    /\ mu = NoWorker
    /\ (checkers[0] = NoChecker => nextCheckerId <= MaxCheckerIds)
    /\ LET r == wReq[w]
           cid == IF checkers[0] = NoChecker THEN nextCheckerId ELSE checkers[0]
           newNext == IF checkers[0] = NoChecker THEN nextCheckerId + 1 ELSE nextCheckerId
           needReg == (r # NoReq /\ reqAssoc[r] = NoSlot)
       IN
       /\ checkers' = [checkers EXCEPT ![0] = cid]
       /\ nextCheckerId' = newNext
       /\ heldBy' = [heldBy EXCEPT ![0] = HoldTag(r)]
       /\ reqAssoc' = IF needReg THEN [reqAssoc EXCEPT ![r] = 0] ELSE reqAssoc
       /\ ctxCleanupPending' = IF needReg /\ ctxDone[r] /\ ctxCleanupPending[r] < 2
                               THEN [ctxCleanupPending EXCEPT ![r] = ctxCleanupPending[r] + 1]
                               ELSE ctxCleanupPending
       /\ wSlot' = [wSlot EXCEPT ![w] = 0]
       /\ wCheckerId' = [wCheckerId EXCEPT ![w] = cid]
       /\ doubleUseChecker' = (doubleUseChecker \/ (\E u \in Workers : u # w /\ pc[u] = "holding" /\ wSlot[u] = 0))
       /\ reusedCanceled' = (reusedCanceled \/ (checkers[0] # NoChecker /\ checkerCanceled[0]))
       /\ pc' = [pc EXCEPT ![w] = "holding"]
    /\ UNCHANGED <<mu, discarded, checkerCanceled, fileAssoc, lastReleased, now,
                   timerScheduled, timerArmed, timerInFlight, ctxDone, diagSem, querySem,
                   wKind, wReq, wFile, noSlotPanic, disposeMismatch, timerLeakAfterDiscard, semUnderflow>>

\* Normal acquisition under p.mu (query)
AcquireQueryNormal(w) ==
    /\ pc[w] = "acquire_normal"
    /\ wKind[w] = "query"
    /\ mu = NoWorker
    /\ LET r == wReq[w]
           f == wFile[w]
           fIdx == IF f # NoFile THEN fileAssoc[f] ELSE NoSlot
           fileHit == (fIdx \in QuerySlots /\ checkers[fIdx] # NoChecker /\ heldBy[fIdx] = "")
           idleSlots == {s \in QuerySlots : checkers[s] # NoChecker /\ heldBy[s] = ""}
           emptySlots == {s \in QuerySlots : checkers[s] = NoChecker}
       IN
       IF fileHit
       THEN LET needReg == (r # NoReq /\ reqAssoc[r] = NoSlot) IN
            /\ heldBy' = [heldBy EXCEPT ![fIdx] = HoldTag(r)]
            /\ reqAssoc' = IF needReg THEN [reqAssoc EXCEPT ![r] = fIdx] ELSE reqAssoc
            /\ ctxCleanupPending' = IF needReg /\ ctxDone[r] /\ ctxCleanupPending[r] < 2
                                    THEN [ctxCleanupPending EXCEPT ![r] = ctxCleanupPending[r] + 1]
                                    ELSE ctxCleanupPending
            /\ wSlot' = [wSlot EXCEPT ![w] = fIdx]
            /\ wCheckerId' = [wCheckerId EXCEPT ![w] = checkers[fIdx]]
            /\ doubleUseChecker' = (doubleUseChecker \/ (\E u \in Workers : u # w /\ pc[u] = "holding" /\ wSlot[u] = fIdx))
            /\ reusedCanceled' = (reusedCanceled \/ checkerCanceled[fIdx])
            /\ pc' = [pc EXCEPT ![w] = "holding"]
            /\ UNCHANGED <<checkers, nextCheckerId, fileAssoc, noSlotPanic>>
       ELSE IF idleSlots # {}
       THEN LET s == CHOOSE x \in idleSlots : \A y \in idleSlots : x <= y
                needReg == (r # NoReq /\ reqAssoc[r] = NoSlot)
            IN
            /\ heldBy' = [heldBy EXCEPT ![s] = HoldTag(r)]
            /\ reqAssoc' = IF needReg THEN [reqAssoc EXCEPT ![r] = s] ELSE reqAssoc
            /\ ctxCleanupPending' = IF needReg /\ ctxDone[r] /\ ctxCleanupPending[r] < 2
                                    THEN [ctxCleanupPending EXCEPT ![r] = ctxCleanupPending[r] + 1]
                                    ELSE ctxCleanupPending
            /\ fileAssoc' = IF f # NoFile THEN [fileAssoc EXCEPT ![f] = s] ELSE fileAssoc
            /\ wSlot' = [wSlot EXCEPT ![w] = s]
            /\ wCheckerId' = [wCheckerId EXCEPT ![w] = checkers[s]]
            /\ doubleUseChecker' = (doubleUseChecker \/ (\E u \in Workers : u # w /\ pc[u] = "holding" /\ wSlot[u] = s))
            /\ reusedCanceled' = (reusedCanceled \/ checkerCanceled[s])
            /\ pc' = [pc EXCEPT ![w] = "holding"]
            /\ UNCHANGED <<checkers, nextCheckerId, noSlotPanic>>
       ELSE IF emptySlots # {}
       THEN /\ nextCheckerId <= MaxCheckerIds
            /\ LET s == CHOOSE x \in emptySlots : \A y \in emptySlots : x <= y
                   cid == nextCheckerId
                   needReg == (r # NoReq /\ reqAssoc[r] = NoSlot)
               IN
               /\ checkers' = [checkers EXCEPT ![s] = cid]
               /\ nextCheckerId' = nextCheckerId + 1
               /\ heldBy' = [heldBy EXCEPT ![s] = HoldTag(r)]
               /\ reqAssoc' = IF needReg THEN [reqAssoc EXCEPT ![r] = s] ELSE reqAssoc
               /\ ctxCleanupPending' = IF needReg /\ ctxDone[r] /\ ctxCleanupPending[r] < 2
                                       THEN [ctxCleanupPending EXCEPT ![r] = ctxCleanupPending[r] + 1]
                                       ELSE ctxCleanupPending
               /\ fileAssoc' = IF f # NoFile THEN [fileAssoc EXCEPT ![f] = s] ELSE fileAssoc
               /\ wSlot' = [wSlot EXCEPT ![w] = s]
               /\ wCheckerId' = [wCheckerId EXCEPT ![w] = cid]
               /\ doubleUseChecker' = (doubleUseChecker \/ (\E u \in Workers : u # w /\ pc[u] = "holding" /\ wSlot[u] = s))
               /\ pc' = [pc EXCEPT ![w] = "holding"]
               /\ UNCHANGED <<noSlotPanic, reusedCanceled>>
       ELSE /\ noSlotPanic' = TRUE
            /\ pc' = [pc EXCEPT ![w] = "release_sem"]
            /\ UNCHANGED <<checkers, nextCheckerId, heldBy, fileAssoc, reqAssoc,
                           ctxCleanupPending, wSlot, wCheckerId, doubleUseChecker, reusedCanceled>>
    /\ UNCHANGED <<mu, discarded, checkerCanceled, lastReleased, now,
                   timerScheduled, timerArmed, timerInFlight, ctxDone, diagSem, querySem,
                   wKind, wReq, wFile, disposeMismatch, timerLeakAfterDiscard, semUnderflow>>

\* While holding checker, it may get canceled
CancelHeldChecker(w) ==
    /\ pc[w] = "holding"
    /\ ~checkerCanceled[wSlot[w]]
    /\ checkerCanceled' = [checkerCanceled EXCEPT ![wSlot[w]] = TRUE]
    /\ UNCHANGED <<mu, discarded, checkers, nextCheckerId, heldBy, fileAssoc, reqAssoc,
                   lastReleased, now, timerScheduled, timerArmed, timerInFlight, ctxDone,
                   ctxCleanupPending, diagSem, querySem, pc, wKind, wReq, wFile, wSlot,
                   wCheckerId, doubleUseChecker, noSlotPanic, disposeMismatch,
                   timerLeakAfterDiscard, semUnderflow, reusedCanceled>>

\* Release part 1 (under p.mu): dispose if canceled, else release and schedule cleanup
ReleaseLockPart(w) ==
    /\ pc[w] = "holding"
    /\ mu = NoWorker
    /\ LET s == wSlot[w]
           cid == wCheckerId[w]
       IN
       IF checkerCanceled[s]
       THEN \* disposeCheckerLocked
            /\ disposeMismatch' = (disposeMismatch \/ checkers[s] # cid)
            /\ checkers' = [checkers EXCEPT ![s] = NoChecker]
            /\ heldBy' = [heldBy EXCEPT ![s] = ""]
            /\ checkerCanceled' = [checkerCanceled EXCEPT ![s] = FALSE]
            /\ lastReleased' = [lastReleased EXCEPT ![s] = 0]
            /\ fileAssoc' = [f \in Files |-> IF fileAssoc[f] = s THEN NoSlot ELSE fileAssoc[f]]
            /\ reqAssoc' = [r \in Reqs |-> IF reqAssoc[r] = s THEN NoSlot ELSE reqAssoc[r]]
            /\ pc' = [pc EXCEPT ![w] = "release_sem"]
            /\ UNCHANGED <<timerScheduled, timerArmed, timerLeakAfterDiscard>>
       ELSE \* normal release
            /\ LET newHeld == [heldBy EXCEPT ![s] = ""]
                   newLRel == [lastReleased EXCEPT ![s] = now]
                   hasIdle == HasIdleChecker(checkers, newHeld, newLRel)
               IN
               /\ heldBy' = newHeld
               /\ lastReleased' = newLRel
               /\ IF ~discarded
                  THEN /\ timerScheduled' = hasIdle
                       /\ timerArmed' = hasIdle
                       /\ UNCHANGED timerLeakAfterDiscard
                  ELSE /\ UNCHANGED <<timerScheduled, timerArmed, timerLeakAfterDiscard>>
               /\ pc' = [pc EXCEPT ![w] = "release_sem"]
            /\ UNCHANGED <<disposeMismatch, checkers, checkerCanceled, fileAssoc, reqAssoc>>
    /\ UNCHANGED <<mu, discarded, nextCheckerId, now, timerInFlight, ctxDone,
                   ctxCleanupPending, diagSem, querySem, wKind, wReq, wFile, wSlot,
                   wCheckerId, doubleUseChecker, noSlotPanic, semUnderflow, reusedCanceled>>

\* Release part 2 (after p.mu.Unlock()): release semaphore slot
ReleaseSemPart(w) ==
    /\ pc[w] = "release_sem"
    /\ IF wKind[w] = "diag"
       THEN /\ semUnderflow' = (semUnderflow \/ diagSem <= 0)
            /\ diagSem' = diagSem - 1
            /\ UNCHANGED querySem
       ELSE /\ semUnderflow' = (semUnderflow \/ querySem <= 0)
            /\ querySem' = querySem - 1
            /\ UNCHANGED diagSem
    /\ wKind' = [wKind EXCEPT ![w] = "none"]
    /\ wReq' = [wReq EXCEPT ![w] = NoReq]
    /\ wFile' = [wFile EXCEPT ![w] = NoFile]
    /\ wSlot' = [wSlot EXCEPT ![w] = NoSlot]
    /\ wCheckerId' = [wCheckerId EXCEPT ![w] = NoChecker]
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<mu, discarded, checkers, nextCheckerId, heldBy, checkerCanceled, fileAssoc,
                   reqAssoc, lastReleased, now, timerScheduled, timerArmed, timerInFlight,
                   ctxDone, ctxCleanupPending, doubleUseChecker, noSlotPanic, disposeMismatch,
                   timerLeakAfterDiscard, reusedCanceled>>

\* --- Async Timer: fires and later runs cleanupIdleCheckers ---

TimerFire ==
    /\ timerArmed
    /\ ~timerInFlight
    /\ timerArmed' = FALSE
    /\ timerInFlight' = TRUE
    /\ UNCHANGED <<mu, discarded, checkers, nextCheckerId, heldBy, checkerCanceled, fileAssoc,
                   reqAssoc, lastReleased, now, timerScheduled, ctxDone, ctxCleanupPending,
                   diagSem, querySem, pc, wKind, wReq, wFile, wSlot, wCheckerId,
                   doubleUseChecker, noSlotPanic, disposeMismatch, timerLeakAfterDiscard,
                   semUnderflow, reusedCanceled>>

CleanupIdleCheckers ==
    /\ timerInFlight
    /\ mu = NoWorker
    /\ timerInFlight' = FALSE
    /\ IF discarded
       THEN UNCHANGED <<checkers, heldBy, checkerCanceled, lastReleased, fileAssoc, reqAssoc,
                       timerScheduled, timerArmed, timerLeakAfterDiscard>>
       ELSE LET expired == {s \in Slots : checkers[s] # NoChecker /\ heldBy[s] = "" /\ lastReleased[s] # 0 /\ (now - lastReleased[s]) >= IdleTimeout}
                newChks == [s \in Slots |-> IF s \in expired THEN NoChecker ELSE checkers[s]]
                newHeld == [s \in Slots |-> IF s \in expired THEN "" ELSE heldBy[s]]
                newLRel == [s \in Slots |-> IF s \in expired THEN 0 ELSE lastReleased[s]]
                hasIdle == HasIdleChecker(newChks, newHeld, newLRel)
            IN
            /\ checkers' = newChks
            /\ heldBy' = newHeld
            /\ checkerCanceled' = [s \in Slots |-> IF s \in expired THEN FALSE ELSE checkerCanceled[s]]
            /\ lastReleased' = newLRel
            /\ fileAssoc' = [f \in Files |-> IF fileAssoc[f] \in expired THEN NoSlot ELSE fileAssoc[f]]
            /\ reqAssoc' = [r \in Reqs |-> IF reqAssoc[r] \in expired THEN NoSlot ELSE reqAssoc[r]]
            /\ timerScheduled' = hasIdle
            /\ timerArmed' = hasIdle
            /\ UNCHANGED timerLeakAfterDiscard
    /\ UNCHANGED <<mu, discarded, nextCheckerId, now, ctxDone, ctxCleanupPending,
                   diagSem, querySem, pc, wKind, wReq, wFile, wSlot, wCheckerId,
                   doubleUseChecker, noSlotPanic, disposeMismatch, semUnderflow, reusedCanceled>>

\* --- Context cancellation & AfterFunc ---

CancelReqCtx(r) ==
    /\ ~ctxDone[r]
    /\ ctxDone' = [ctxDone EXCEPT ![r] = TRUE]
    /\ ctxCleanupPending' = IF reqAssoc[r] # NoSlot /\ ctxCleanupPending[r] < 2
                            THEN [ctxCleanupPending EXCEPT ![r] = ctxCleanupPending[r] + 1]
                            ELSE ctxCleanupPending
    /\ UNCHANGED <<mu, discarded, checkers, nextCheckerId, heldBy, checkerCanceled, fileAssoc,
                   reqAssoc, lastReleased, now, timerScheduled, timerArmed, timerInFlight,
                   diagSem, querySem, pc, wKind, wReq, wFile, wSlot, wCheckerId,
                   doubleUseChecker, noSlotPanic, disposeMismatch, timerLeakAfterDiscard,
                   semUnderflow, reusedCanceled>>

RunReqCleanup(r) ==
    /\ ctxCleanupPending[r] > 0
    /\ mu = NoWorker
    /\ ctxCleanupPending' = [ctxCleanupPending EXCEPT ![r] = ctxCleanupPending[r] - 1]
    /\ reqAssoc' = [reqAssoc EXCEPT ![r] = NoSlot]
    /\ UNCHANGED <<mu, discarded, checkers, nextCheckerId, heldBy, checkerCanceled, fileAssoc,
                   lastReleased, now, timerScheduled, timerArmed, timerInFlight, ctxDone,
                   diagSem, querySem, pc, wKind, wReq, wFile, wSlot, wCheckerId,
                   doubleUseChecker, noSlotPanic, disposeMismatch, timerLeakAfterDiscard,
                   semUnderflow, reusedCanceled>>

\* --- Discard() ---

Discard ==
    /\ ~discarded
    /\ mu = NoWorker
    /\ discarded' = TRUE
    /\ timerScheduled' = FALSE
    /\ timerArmed' = FALSE
    /\ UNCHANGED <<mu, checkers, nextCheckerId, heldBy, checkerCanceled, fileAssoc, reqAssoc,
                   lastReleased, now, timerInFlight, ctxDone, ctxCleanupPending, diagSem,
                   querySem, pc, wKind, wReq, wFile, wSlot, wCheckerId, doubleUseChecker,
                   noSlotPanic, disposeMismatch, timerLeakAfterDiscard, semUnderflow, reusedCanceled>>

\* --- Advance Clock ---

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED <<mu, discarded, checkers, nextCheckerId, heldBy, checkerCanceled, fileAssoc,
                   reqAssoc, lastReleased, timerScheduled, timerArmed, timerInFlight, ctxDone,
                   ctxCleanupPending, diagSem, querySem, pc, wKind, wReq, wFile, wSlot,
                   wCheckerId, doubleUseChecker, noSlotPanic, disposeMismatch,
                   timerLeakAfterDiscard, semUnderflow, reusedCanceled>>

Next ==
    \/ \E w \in Workers, r \in Reqs \cup {NoReq} : StartGetDiag(w, r)
    \/ \E w \in Workers, r \in Reqs \cup {NoReq}, f \in Files \cup {NoFile} : StartGetQuery(w, r, f)
    \/ \E w \in Workers :
        \/ TryReacquire(w)
        \/ AcquireDiagNormal(w)
        \/ AcquireQueryNormal(w)
        \/ CancelHeldChecker(w)
        \/ ReleaseLockPart(w)
        \/ ReleaseSemPart(w)
    \/ TimerFire
    \/ CleanupIdleCheckers
    \/ \E r \in Reqs : CancelReqCtx(r) \/ RunReqCleanup(r)
    \/ Discard
    \/ Tick

\* --- Invariants ---

NoDoubleUse == ~doubleUseChecker
NoSlotPanic == ~noSlotPanic
NoDisposeMismatch == ~disposeMismatch
NoSemUnderflow == ~semUnderflow
NoReusedCanceled == ~reusedCanceled
NoTimerAfterDiscard == discarded => ~timerArmed

\* Semaphores match workers currently holding or in-progress
SemAccounting ==
    /\ diagSem = Cardinality({w \in Workers : wKind[w] = "diag"})
    /\ querySem = Cardinality({w \in Workers : wKind[w] = "query"})

\* No dangling fileAssoc or reqAssoc pointing to a nil checker (Wait: can reqAssoc point to nil? Let's check!)
NoDanglingFileAssoc ==
    \A f \in Files : fileAssoc[f] # NoSlot => checkers[fileAssoc[f]] # NoChecker

=============================================================================
