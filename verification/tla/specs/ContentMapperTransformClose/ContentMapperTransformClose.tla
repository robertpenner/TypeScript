-------------------- MODULE ContentMapperTransformClose --------------------
(***************************************************************************)
(* Formal model of two distinct defects in tsc/internal/contentmapper/     *)
(* hostimpl.go (strictly disjoint from Tier 1 #6 ContentMapperHost, which  *)
(* modeled Refresh-vs-Transform handle reuse and Close-vs-Acquire orphan): *)
(*                                                                         *)
(*  1. host.Transform(mapper, request) (lines 578-586) vs host.Close()     *)
(*     (lines 617-641):                                                    *)
(*     host.Close() sets h.projects = nil under h.mu.                      *)
(*     host.Project(spec) (lines 415-447) returns nil when h.projects ==   *)
(*     nil. host.Transform calls project := h.Project(...), schedules      *)
(*     defer project.Close(), and immediately calls                        *)
(*     project.Transform(mapper, request) with no nil check, panicking     *)
(*     with a nil-pointer dereference whenever Transform races with Close  *)
(*     or runs after context cancellation triggers context.AfterFunc.      *)
(*                                                                         *)
(*  2. host.Project(spec) (lines 426-442) duplicate *Mapper pointer leak:  *)
(*     Unlike host.Acquire (lines 558-567), host.Project does not          *)
(*     deduplicate spec.Mappers. Passing [m1, m1] inserts two entries      *)
(*     into h.projects and increments connEntry.refs twice, while          *)
(*     overwriting lease.entries[m1] (keyed by *Mapper). projectLease      *)
(*     release() (lines 861-877) iterates lease.entries once, permanently  *)
(*     leaking 1 h.projects entry and 1 connEntry.refs (pinning the        *)
(*     subprocess alive until host.Close()).                               *)
(***************************************************************************)

EXTENDS Naturals

CONSTANTS
    FixNilCheck,     \* FALSE = current host.Transform; TRUE = check project == nil
    FixDedup,        \* FALSE = current host.Project; TRUE = deduplicate spec.Mappers
    EnableTransform, \* TRUE to model host.Transform racing with host.Close
    EnableDupProject \* TRUE to model host.Project([m1, m1]) -> lease.Close()

VARIABLES
    hostClosed,     \* TRUE after host.Close() sets h.projects = nil
    closePC,        \* "idle" | "done"
    transformPC,    \* "idle" | "got_nil" | "got_lease" | "panicked" | "done"
    dupPC,          \* "idle" | "leased" | "closed"
    projectsCount,  \* number of entries in h.projects
    connRefs,       \* connEntry.refs for mapper m1
    leaseEntries,   \* number of distinct keys stored in dup lease.entries (map[*Mapper]string)
    nilDerefPanic   \* TRUE if Transform dereferences a nil Project

vars == <<hostClosed, closePC, transformPC, dupPC,
          projectsCount, connRefs, leaseEntries, nilDerefPanic>>

TypeOK ==
    /\ hostClosed \in BOOLEAN
    /\ closePC \in {"idle", "done"}
    /\ transformPC \in {"idle", "got_nil", "got_lease", "panicked", "done"}
    /\ dupPC \in {"idle", "leased", "closed"}
    /\ projectsCount \in 0..4
    /\ connRefs \in 0..4
    /\ leaseEntries \in 0..2
    /\ nilDerefPanic \in BOOLEAN

Init ==
    /\ hostClosed = FALSE
    /\ closePC = IF EnableTransform THEN "idle" ELSE "done"
    /\ transformPC = IF EnableTransform THEN "idle" ELSE "done"
    /\ dupPC = IF EnableDupProject THEN "idle" ELSE "closed"
    /\ projectsCount = 0
    /\ connRefs = 0
    /\ leaseEntries = 0
    /\ nilDerefPanic = FALSE

\* --- host.Close(): acquires lifecycleMu + mu, sets h.projects = nil, h.conns = nil ---

HostClose ==
    /\ closePC = "idle"
    /\ hostClosed' = TRUE
    /\ projectsCount' = 0
    /\ connRefs' = 0
    /\ closePC' = "done"
    /\ UNCHANGED <<transformPC, dupPC, leaseEntries, nilDerefPanic>>

\* --- host.Transform(m1, req): step 1 calls project := h.Project([m1]) ---

TransformAcquireProject ==
    /\ transformPC = "idle"
    /\ IF hostClosed THEN
           \* host.Project sees h.projects == nil and returns nil
           /\ transformPC' = "got_nil"
           /\ UNCHANGED <<projectsCount, connRefs>>
       ELSE
           /\ projectsCount' = projectsCount + 1
           /\ connRefs' = connRefs + 1
           /\ transformPC' = "got_lease"
    /\ UNCHANGED <<hostClosed, closePC, dupPC, leaseEntries, nilDerefPanic>>

\* --- host.Transform step 2 when h.Project returned nil ---

TransformUseNilProject ==
    /\ transformPC = "got_nil"
    /\ IF FixNilCheck THEN
           /\ transformPC' = "done"
           /\ UNCHANGED nilDerefPanic
       ELSE
           \* defer project.Close() + project.Transform(...) dereference nil *projectLease
           /\ nilDerefPanic' = TRUE
           /\ transformPC' = "panicked"
    /\ UNCHANGED <<hostClosed, closePC, dupPC, projectsCount, connRefs, leaseEntries>>

\* --- host.Transform step 2 when h.Project returned a live lease ---

TransformUseLiveLease ==
    /\ transformPC = "got_lease"
    /\ IF hostClosed THEN
           \* host.Close already cleared maps; release() sees nil maps and returns
           /\ UNCHANGED <<projectsCount, connRefs>>
       ELSE
           /\ projectsCount' = projectsCount - 1
           /\ connRefs' = connRefs - 1
    /\ transformPC' = "done"
    /\ UNCHANGED <<hostClosed, closePC, dupPC, leaseEntries, nilDerefPanic>>

\* --- Caller passing duplicate *Mapper [m1, m1] to host.Project(spec) ---

DupProjectCreate ==
    /\ dupPC = "idle"
    /\ IF hostClosed THEN
           \* host.Project sees h.projects == nil and returns nil
           /\ dupPC' = "closed"
           /\ UNCHANGED <<projectsCount, connRefs, leaseEntries>>
       ELSE
           /\ IF FixDedup THEN
                  \* Fixed: deduplicate mappers as host.Acquire does
                  /\ projectsCount' = projectsCount + 1
                  /\ connRefs' = connRefs + 1
                  /\ leaseEntries' = 1
              ELSE
                  \* Buggy: loop inserts 2 entries into h.projects & increments connRefs twice,
                  \* but map[*Mapper]string lease.entries[m1] overwrites slot 1 -> len = 1
                  /\ projectsCount' = projectsCount + 2
                  /\ connRefs' = connRefs + 2
                  /\ leaseEntries' = 1
           /\ dupPC' = "leased"
    /\ UNCHANGED <<hostClosed, closePC, transformPC, nilDerefPanic>>

\* --- projectLease.Close() -> release(): iterates p.entries (only 1 entry for m1) ---

DupProjectClose ==
    /\ dupPC = "leased"
    /\ IF hostClosed THEN
           /\ UNCHANGED <<projectsCount, connRefs>>
       ELSE
           /\ projectsCount' = projectsCount - leaseEntries
           /\ connRefs' = connRefs - leaseEntries
    /\ leaseEntries' = 0
    /\ dupPC' = "closed"
    /\ UNCHANGED <<hostClosed, closePC, transformPC, nilDerefPanic>>

Done ==
    /\ closePC = "done"
    /\ transformPC \in {"done", "panicked"}
    /\ dupPC = "closed"
    /\ UNCHANGED vars

Next ==
    \/ HostClose
    \/ TransformAcquireProject
    \/ TransformUseNilProject
    \/ TransformUseLiveLease
    \/ DupProjectCreate
    \/ DupProjectClose
    \/ Done

Spec == Init /\ [][Next]_vars

\* --- Safety invariants ---

NoNilProjectDeref == ~nilDerefPanic

NoLeakedConnRef ==
    (dupPC = "closed" /\ ~hostClosed /\ transformPC = "done") =>
        (connRefs = 0 /\ projectsCount = 0)

AllSafe ==
    /\ NoNilProjectDeref
    /\ NoLeakedConnRef

=============================================================================
