---- MODULE LspProgressLocale ----
EXTENDS Naturals, Sequences, FiniteSets

(*
 * Models projectLoadingProgress + Server.SetLocale in:
 *   tsc/internal/lsp/progress.go:42-44, 108-175
 *   tsc/internal/lsp/server.go:833-853
 *
 * Two independent defects:
 *   1. Data race (InvNoLocaleDataRace):
 *      serverProgressReporter.localize reads r.server.locale without acquiring
 *      r.server.localeMu.RLock(), racing with Server.SetLocale writing
 *      s.locale under s.localeMu.Lock().
 *   2. Stuck WorkDoneProgress spinner (InvProgressEndsWhenIdle):
 *      projectLoadingProgress.run() keys its refcounted `loading` map by the
 *      localized string produced at event-processing time. If Server.SetLocale
 *      changes the locale between ProgressStart(msg) and ProgressFinish(msg),
 *      the finish event hashes to a different localized string, fails to
 *      decrement/delete the original entry, leaves loading non-empty, and
 *      never emits WorkDoneProgressEnd.
 *)

LOCALES == {"en", "de"}
TEXTS   == {"en_msg", "de_msg"}

Localize(loc) == IF loc = "en" THEN "en_msg" ELSE "de_msg"

VARIABLES
    locale,          \* Server.locale (guarded by localeMu on write, UNGUARDED on progress read)
    localeMuLocked,  \* TRUE while SetLocale holds localeMu.Lock()
    setLocalePC,     \* "idle" | "writing" | "done"
    progPC,          \* "idle" | "readingLocaleStart" | "readingLocaleFinish"
    inFlightOps,     \* Ground-truth count of active (started - finished) operations
    queue,           \* Bounded FIFO of <<"start">> / <<"finish">> events on p.ch
    loading,         \* [TEXTS -> Nat]: refcounts keyed by localized text
    tokenOpen,       \* TRUE while WorkDoneProgress token is open (begin sent, end not yet sent)
    dataRace         \* Sticky latch: TRUE if unlocked read overlaps localeMu-locked write

vars == <<locale, localeMuLocked, setLocalePC, progPC, inFlightOps,
          queue, loading, tokenOpen, dataRace>>

TypeOK ==
    /\ locale \in LOCALES
    /\ localeMuLocked \in BOOLEAN
    /\ setLocalePC \in {"idle", "writing", "done"}
    /\ progPC \in {"idle", "readingLocaleStart", "readingLocaleFinish"}
    /\ inFlightOps \in 0..1
    /\ loading \in [TEXTS -> 0..1]
    /\ tokenOpen \in BOOLEAN
    /\ dataRace \in BOOLEAN

Init ==
    /\ locale = "en"
    /\ localeMuLocked = FALSE
    /\ setLocalePC = "idle"
    /\ progPC = "idle"
    /\ inFlightOps = 0
    /\ queue = <<>>
    /\ loading = [t \in TEXTS |-> 0]
    /\ tokenOpen = FALSE
    /\ dataRace = FALSE

\* Caller invokes Server.ProgressStart(diagnostics.Project_0, "p")
CallerStart ==
    /\ inFlightOps = 0
    /\ Len(queue) < 2
    /\ inFlightOps' = 1
    /\ queue' = Append(queue, "start")
    /\ UNCHANGED <<locale, localeMuLocked, setLocalePC, progPC, loading, tokenOpen, dataRace>>

\* Caller invokes Server.ProgressFinish(diagnostics.Project_0, "p")
CallerFinish ==
    /\ inFlightOps = 1
    /\ Len(queue) < 2
    /\ inFlightOps' = 0
    /\ queue' = Append(queue, "finish")
    /\ UNCHANGED <<locale, localeMuLocked, setLocalePC, progPC, loading, tokenOpen, dataRace>>

\* Server.SetLocale("de"): acquires localeMu.Lock() and begins writing s.locale
SetLocaleBeginWrite ==
    /\ setLocalePC = "idle"
    /\ ~localeMuLocked
    /\ localeMuLocked' = TRUE
    /\ setLocalePC' = "writing"
    /\ dataRace' = (dataRace \/ progPC \in {"readingLocaleStart", "readingLocaleFinish"})
    /\ UNCHANGED <<locale, progPC, inFlightOps, queue, loading, tokenOpen>>

\* Server.SetLocale("de"): stores new locale and releases localeMu.Unlock()
SetLocaleEndWrite ==
    /\ setLocalePC = "writing"
    /\ locale' = "de"
    /\ localeMuLocked' = FALSE
    /\ setLocalePC' = "done"
    /\ UNCHANGED <<progPC, inFlightOps, queue, loading, tokenOpen, dataRace>>

\* projectLoadingProgress.run(): pops event and begins unlocked read of r.server.locale
ProgBeginLocalize ==
    /\ progPC = "idle"
    /\ Len(queue) > 0
    /\ LET ev == Head(queue) IN
       /\ progPC' = IF ev = "start" THEN "readingLocaleStart" ELSE "readingLocaleFinish"
       /\ queue' = Tail(queue)
       /\ dataRace' = (dataRace \/ localeMuLocked)
    /\ UNCHANGED <<locale, localeMuLocked, setLocalePC, inFlightOps, loading, tokenOpen>>

\* projectLoadingProgress.run(): finishes processing start event with localized text key
ProgApplyStart ==
    /\ progPC = "readingLocaleStart"
    /\ LET txt == Localize(locale) IN
       /\ loading' = [loading EXCEPT ![txt] = IF @ < 1 THEN @ + 1 ELSE @]
       /\ tokenOpen' = TRUE
    /\ progPC' = "idle"
    /\ UNCHANGED <<locale, localeMuLocked, setLocalePC, inFlightOps, queue, dataRace>>

\* projectLoadingProgress.run(): finishes processing finish event with localized text key
ProgApplyFinish ==
    /\ progPC = "readingLocaleFinish"
    /\ LET txt == Localize(locale)
           newLoading == [loading EXCEPT ![txt] = IF @ > 0 THEN @ - 1 ELSE 0]
           empty == \A k \in TEXTS : newLoading[k] = 0
       IN
       /\ loading' = newLoading
       /\ tokenOpen' = IF empty THEN FALSE ELSE tokenOpen
    /\ progPC' = "idle"
    /\ UNCHANGED <<locale, localeMuLocked, setLocalePC, inFlightOps, queue, dataRace>>

Next ==
    \/ CallerStart
    \/ CallerFinish
    \/ SetLocaleBeginWrite
    \/ SetLocaleEndWrite
    \/ ProgBeginLocalize
    \/ ProgApplyStart
    \/ ProgApplyFinish

Spec == Init /\ [][Next]_vars

\* Bug 3.1a: unlocked read of r.server.locale overlaps localeMu-locked write in SetLocale
InvNoLocaleDataRace == ~dataRace

\* Bug 3.1b: once all started operations have finished and the progress queue has
\* drained, WorkDoneProgressEnd must have been emitted (tokenOpen = FALSE).
InvProgressEndsWhenIdle ==
    (inFlightOps = 0 /\ Len(queue) = 0 /\ progPC = "idle") => ~tokenOpen
====
