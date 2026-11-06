------------------------- MODULE WindowsPublication -------------------------
\* Windows cannot rename a session folder with its log and lock still open.
\* The root publication lock excludes resume and deletion while the publisher
\* closes those files, renames the folder, then reopens and relocks them.
\* This models process crashes and ownership, not power-loss persistence.
EXTENDS Naturals, FiniteSets
CONSTANTS Procs, None
VARIABLES gate, holder, phase, published, opened
vars == <<gate, holder, phase, published, opened>>
Init ==
    /\ gate = None
    /\ holder = None
    /\ phase = [p \in Procs |-> "idle"]
    /\ published = FALSE
    /\ opened = {}
Begin(p) ==
    /\ gate = None /\ ~published /\ phase[p] = "idle"
    /\ gate' = p /\ holder' = p
    /\ phase' = [phase EXCEPT ![p] = "staged"]
    /\ UNCHANGED <<published, opened>>
CloseHandles(p) ==
    /\ gate = p /\ phase[p] = "staged" /\ holder = p
    /\ holder' = None
    /\ phase' = [phase EXCEPT ![p] = "closed"]
    /\ UNCHANGED <<gate, published, opened>>
Rename(p) ==
    /\ gate = p /\ phase[p] = "closed"
    /\ published' = TRUE
    /\ phase' = [phase EXCEPT ![p] = "renamed"]
    /\ UNCHANGED <<gate, holder, opened>>
Reopen(p) ==
    /\ gate = p /\ phase[p] = "renamed" /\ holder = None
    /\ holder' = p /\ opened' = {p}
    /\ gate' = None
    /\ phase' = [phase EXCEPT ![p] = "idle"]
    /\ UNCHANGED published
Open(p) ==
    /\ gate = None /\ published /\ holder = None
    /\ holder' = p /\ opened' = {p}
    /\ UNCHANGED <<gate, phase, published>>
Close(p) ==
    /\ p \in opened
    /\ holder' = None /\ opened' = {}
    /\ UNCHANGED <<gate, phase, published>>
Trash ==
    /\ gate = None /\ published /\ holder = None
    /\ published' = FALSE
    /\ UNCHANGED <<gate, holder, phase, opened>>
Crash(p) ==
    /\ gate' = IF gate = p THEN None ELSE gate
    /\ holder' = IF holder = p THEN None ELSE holder
    /\ opened' = opened \ {p}
    /\ phase' = [phase EXCEPT ![p] = "idle"]
    /\ UNCHANGED published
Next == Trash \/ (\E p \in Procs : Begin(p) \/ CloseHandles(p) \/ Rename(p) \/ Reopen(p) \/ Open(p) \/ Close(p) \/ Crash(p))
Spec == Init /\ [][Next]_vars
TypeOK ==
    /\ gate \in Procs \cup {None}
    /\ holder \in Procs \cup {None}
    /\ phase \in [Procs -> {"idle", "staged", "closed", "renamed"}]
    /\ published \in BOOLEAN
    /\ opened \subseteq Procs
OneWriter == Cardinality(opened) <= 1
OnlyHolderOpen == \A p \in opened : holder = p /\ published
PublicationExcludesOpen == \A p \in Procs : phase[p] # "idle" => gate = p /\ opened = {}
=============================================================================
