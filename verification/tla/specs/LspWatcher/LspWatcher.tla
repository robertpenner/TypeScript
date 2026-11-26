--------------------------- MODULE LspWatcher ---------------------------
EXTENDS Integers, FiniteSets

\* Faithful synchronization model of tsc/internal/lsp/lspwatcher/lspwatcher.go:
\* - WatchFiles(id) vs UnwatchFiles(id) (lines 147-205)
\* - targetCallback -> handleTerminated() vs ancestorCallback -> reconcile() (lines 257-380)

CONSTANTS
    MaxSubs \* Bound on backend subscription IDs, e.g. 4

SubIds == 1..MaxSubs
NoSub == 0

VARIABLES
    \* Watcher.watches["id1"]: "absent" | "present"
    idInMap,
    watchCountInMap,   \* number of *watch objects stored under w.watches["id1"]
    nextSubId,         \* monotonic subscription ID
    \* WatchFiles("id1") caller state (installing 1 watch)
    wfPC,              \* "idle" | "reconciling" | "done"
    wfInstalledSub,    \* 0..MaxSubs
    \* UnwatchFiles("id1") caller state
    uwDone,            \* BOOLEAN: UnwatchFiles("id1") already returned nil (success)
    \* Single *watch internal state (for testing handleTerminated vs reconcile)
    curSub,            \* current w.subscription (0 = nil, or SubIds)
    watchingTarget,    \* BOOLEAN
    subAlive,          \* [SubIds -> BOOLEAN] whether backend sub is open (not closed)
    \* Callback goroutines for handleTerminated (capturing the sub that terminated)
    termPendingSub,    \* 0 or SubId whose targetCallback received ErrWatchTerminated
    \* Ghost violation flags
    resurrectedAfterUnwatch, \* TRUE if WatchFiles re-added id after UnwatchFiles returned nil
    killedNewerLiveSub       \* TRUE if handleTerminated closed a DIFFERENT live sub than the one that terminated

vars == <<idInMap, watchCountInMap, nextSubId, wfPC, wfInstalledSub, uwDone,
          curSub, watchingTarget, subAlive, termPendingSub,
          resurrectedAfterUnwatch, killedNewerLiveSub>>

Init ==
    /\ idInMap = FALSE
    /\ watchCountInMap = 0
    /\ nextSubId = 1
    /\ wfPC = "idle"
    /\ wfInstalledSub = NoSub
    /\ uwDone = FALSE
    /\ curSub = NoSub
    /\ watchingTarget = FALSE
    /\ subAlive = [s \in SubIds |-> FALSE]
    /\ termPendingSub = NoSub
    /\ resurrectedAfterUnwatch = FALSE
    /\ killedNewerLiveSub = FALSE

\* --- Part A: WatchFiles("id1") vs UnwatchFiles("id1") ---

\* Lines 147-159: lock w.mu, set w.watches[id] = nil, unlock w.mu
WatchFilesStart ==
    /\ wfPC = "idle"
    /\ ~idInMap
    /\ idInMap' = TRUE
    /\ watchCountInMap' = 0
    /\ wfPC' = "reconciling"
    /\ UNCHANGED <<nextSubId, wfInstalledSub, uwDone, curSub, watchingTarget, subAlive,
                   termPendingSub, resurrectedAfterUnwatch, killedNewerLiveSub>>

\* Lines 167-182: reconcile() succeeded outside w.mu; now lock w.mu and append to w.watches[id]
\* BUG: does NOT check if id is still in w.watches!
WatchFilesFinish ==
    /\ wfPC = "reconciling"
    /\ nextSubId <= MaxSubs
    /\ LET s == nextSubId IN
       /\ nextSubId' = nextSubId + 1
       /\ curSub' = s
       /\ watchingTarget' = TRUE
       /\ subAlive' = [subAlive EXCEPT ![s] = TRUE]
       /\ wfInstalledSub' = s
       /\ resurrectedAfterUnwatch' = (resurrectedAfterUnwatch \/ (~idInMap /\ uwDone))
       /\ idInMap' = TRUE
       /\ watchCountInMap' = watchCountInMap + 1
       /\ wfPC' = "done"
    /\ UNCHANGED <<uwDone, termPendingSub, killedNewerLiveSub>>

\* Lines 193-206: UnwatchFiles("id1")
UnwatchFiles ==
    /\ ~uwDone
    /\ idInMap
    /\ idInMap' = FALSE
    /\ watchCountInMap' = 0
    /\ uwDone' = TRUE
    /\ IF curSub # NoSub
       THEN /\ subAlive' = [subAlive EXCEPT ![curSub] = FALSE]
            /\ curSub' = NoSub
            /\ watchingTarget' = FALSE
       ELSE UNCHANGED <<subAlive, curSub, watchingTarget>>
    /\ UNCHANGED <<nextSubId, wfPC, wfInstalledSub, termPendingSub,
                   resurrectedAfterUnwatch, killedNewerLiveSub>>

\* --- Part B: targetCallback(ErrWatchTerminated) -> handleTerminated() vs reconcile() ---

\* Target subscription terminates in backend (queues targetCallback -> handleTerminated)
BackendTerminateCurrentSub ==
    /\ curSub # NoSub
    /\ watchingTarget
    /\ termPendingSub = NoSub
    /\ termPendingSub' = curSub
    /\ UNCHANGED <<idInMap, watchCountInMap, nextSubId, wfPC, wfInstalledSub, uwDone,
                   curSub, watchingTarget, subAlive, resurrectedAfterUnwatch, killedNewerLiveSub>>

\* Concurrent reconcile() (e.g. from ancestor callback or another recovery) replaces curSub with a fresh live sub
ConcurrentReconcileInstallNewSub ==
    /\ curSub # NoSub
    /\ nextSubId <= MaxSubs
    /\ LET s == nextSubId IN
       /\ nextSubId' = nextSubId + 1
       /\ subAlive' = [subAlive EXCEPT ![curSub] = FALSE, ![s] = TRUE]
       /\ curSub' = s
       /\ watchingTarget' = TRUE
    /\ UNCHANGED <<idInMap, watchCountInMap, wfPC, wfInstalledSub, uwDone,
                   termPendingSub, resurrectedAfterUnwatch, killedNewerLiveSub>>

\* Lines 366-380: handleTerminated() unconditionally clears & closes w.subscription without checking identity!
HandleTerminatedRun ==
    /\ termPendingSub # NoSub
    /\ killedNewerLiveSub' = (killedNewerLiveSub \/ (curSub # NoSub /\ curSub # termPendingSub /\ subAlive[curSub]))
    /\ IF curSub # NoSub
       THEN /\ subAlive' = [subAlive EXCEPT ![curSub] = FALSE]
            /\ curSub' = NoSub
            /\ watchingTarget' = FALSE
       ELSE UNCHANGED <<subAlive, curSub, watchingTarget>>
    /\ termPendingSub' = NoSub
    /\ UNCHANGED <<idInMap, watchCountInMap, nextSubId, wfPC, wfInstalledSub, uwDone,
                   resurrectedAfterUnwatch>>

Next ==
    \/ WatchFilesStart
    \/ WatchFilesFinish
    \/ UnwatchFiles
    \/ BackendTerminateCurrentSub
    \/ ConcurrentReconcileInstallNewSub
    \/ HandleTerminatedRun

NoResurrectedWatch == ~resurrectedAfterUnwatch
NoKilledNewerSub == ~killedNewerLiveSub

=============================================================================
