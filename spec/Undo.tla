---------------------------- MODULE Undo ----------------------------
\* Bounded TLA+ model of the journal-backed undo design.
\*
\* A library write records the before-image of every affected row in one
\* journal entry before it changes anything. This model abstracts all row
\* tables to one entity map (`rows`), where an entity key stands for a row in
\* one table (bookmark, tag, highlight, wikilink, capture, dead override) and a
\* value stands for that row's stored content (for a bookmark, including its
\* URL). The generic restore rule is the real one:
\*
\*   * the row is absent today, or still equals the before-image -> restore it;
\*   * the row exists today with a different content -> refuse it and count it
\*     as a conflict; never overwrite a row whose key was reused.
\*
\* The model checks:
\*
\*   1. TypeOK             - variables stay in their domains.
\*   2. IndexMatchesRows   - the abstract FTS index equals the searchable rows
\*                           (a restore must rebuild it, not leave stale terms).
\*   3. JournalBounded     - the journal keeps at most MaxEntries entries; an
\*                           append prunes the oldest first.
\*   4. UndoConsistent     - after an undo every restored row holds its
\*                           before-image, every conflict row is unchanged,
\*                           a row is never both, and restored+conflicts
\*                           covers the captured row set.
\*   5. ConflictNotOverwritten - a conflict row never takes the captured value.
\*
\* Only the newest journal entry can be undone: the Undo action takes
\* Last(journal) and pops it; there is no action that selects an older entry.
\* That is a structural property of the model rather than a checked invariant.
\*
\* This is a bounded design check, not a refinement proof. SQL, XML/JSON
\* encoding of before-images, and the FTS trigger mechanics are abstracted; see
\* spec/README.md for the scope. Bounds: three entity rows (two searchable
\* bookmarks and one tag-like row), two values, and MaxEntries in the config file.

EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    MaxEntries  \* journal depth bound, e.g. 3

ASSUME MaxEntries \in Nat /\ MaxEntries >= 1

Entities == {"bookmark1", "bookmark2", "tag1"}
Searchable == {"bookmark1", "bookmark2"}
Values == {"v1", "v2"}
NoValue == "none"
NoUndo == [ captured |-> {}, restored |-> {}, conflicts |-> {}, deleted |-> {},
             pre |-> [e \in Entities |-> NoValue] ]

VARIABLE
    rows,      \* [Entities -> Values \cup {NoValue}]
    journal,   \* sequence of [op, captured]
    index,     \* abstract FTS index: set of <<entity, value>> for searchable rows
    lastUndo,  \* NoUndo | [captured, restored, conflicts, deleted, pre]
    undoFresh  \* TRUE only until the next write after an undo

vars == <<rows, journal, index, lastUndo, undoFresh>>

Init ==
    /\ rows = [e \in Entities |-> NoValue]
    /\ journal = <<>>
    /\ index = {}
    /\ lastUndo = NoUndo
    /\ undoFresh = FALSE

\* ---------------------------------------------------------------- helpers ---

DerivedIndex(r) ==
    { <<e, v>> \in Searchable \X Values : r[e] = v }

\* Keep the journal bounded: appending to a full journal drops the oldest
\* entry first, which is the server's newest-100 prune.
BoundedAppend(j, entry) ==
    IF Len(j) < MaxEntries
    THEN Append(j, entry)
    ELSE Append(Tail(j), entry)

RowAfter(pre, restored, e) ==
    LET matching == { r \in restored : r[1] = e }
    IN IF matching = {}
       THEN pre[e]
       ELSE (CHOOSE r \in matching : TRUE)[2]

LastOf(j) == j[Len(j)]

FrontOf(j) ==
    IF Len(j) <= 1 THEN <<>> ELSE SubSeq(j, 1, Len(j) - 1)

\* ---------------------------------------------------------------- actions ---

ApplyDelete(e) ==
    LET entry == [op |-> "delete", captured |-> { <<e, rows[e]>> }]
        rows2 == [rows EXCEPT ![e] = NoValue]
    IN /\ rows[e] /= NoValue
       /\ rows' = rows2
       /\ index' = DerivedIndex(rows2)
       /\ journal' = BoundedAppend(journal, entry)
       /\ UNCHANGED lastUndo
       /\ undoFresh' = FALSE

ApplyCreate(e, v) ==
    LET entry == [op |-> "create", captured |-> { <<e, NoValue>> }]
        rows2 == [rows EXCEPT ![e] = v]
    IN /\ rows[e] = NoValue
       /\ v \in Values
       /\ rows' = rows2
       /\ index' = DerivedIndex(rows2)
       /\ journal' = BoundedAppend(journal, entry)
       /\ UNCHANGED lastUndo
       /\ undoFresh' = FALSE

ApplyUpdate(e, v) ==
    LET entry == [op |-> "update", captured |-> { <<e, rows[e]>> }]
        rows2 == [rows EXCEPT ![e] = v]
    IN /\ rows[e] /= NoValue
       /\ rows[e] /= v
       /\ v \in Values
       /\ rows' = rows2
       /\ index' = DerivedIndex(rows2)
       /\ journal' = BoundedAppend(journal, entry)
       /\ UNCHANGED lastUndo
       /\ undoFresh' = FALSE

\* Restore the newest journal entry. Rows whose current value is absent or
\* equal to the before-image are restored; rows whose key now holds different
\* content are conflicts and are left untouched.
Undo ==
    LET entry == LastOf(journal)
        captured == entry.captured
        pre == [e \in Entities |-> rows[e]]
        deletes == { r \in captured : r[2] = NoValue }
        restorable == { r \in captured : r[2] /= NoValue }
        restored == { r \in restorable : pre[r[1]] = NoValue \/ pre[r[1]] = r[2] }
        conflicts == { r \in restorable : pre[r[1]] /= NoValue /\ pre[r[1]] /= r[2] }
        rows2 ==
            [e \in Entities |->
                IF \E r \in deletes : r[1] = e
                THEN NoValue
                ELSE RowAfter(pre, restored, e)]
    IN /\ Len(journal) > 0
       /\ rows' = rows2
       /\ index' = DerivedIndex(rows2)
       /\ journal' = FrontOf(journal)
       /\ lastUndo' =
           [ captured |-> captured,
             restored |-> restored,
             conflicts |-> conflicts,
             deleted |-> deletes,
             pre |-> pre ]
       /\ undoFresh' = TRUE

Next ==
    \/ \E e \in Entities : ApplyDelete(e)
    \/ \E e \in Entities, v \in Values : ApplyCreate(e, v)
    \/ \E e \in Entities, v \in Values : ApplyUpdate(e, v)
    \/ Undo

Spec == Init /\ [][Next]_vars

\* ------------------------------------------------------------- invariants ---

TypeOK ==
    /\ rows \in [Entities -> Values \cup {NoValue}]
    /\ journal \in Seq([op : {"delete", "create", "update"},
                        captured : SUBSET (Entities \X (Values \cup {NoValue}))])
    /\ index \in SUBSET (Searchable \X Values)
    /\ undoFresh \in BOOLEAN
    /\ lastUndo \in [captured : SUBSET (Entities \X (Values \cup {NoValue})),
                      restored : SUBSET (Entities \X (Values \cup {NoValue})),
                      conflicts : SUBSET (Entities \X (Values \cup {NoValue})),
                      deleted : SUBSET (Entities \X (Values \cup {NoValue})),
                      pre : [Entities -> Values \cup {NoValue}]]

IndexMatchesRows ==
    index = DerivedIndex(rows)

JournalBounded ==
    Len(journal) <= MaxEntries

UndoConsistent ==
    undoFresh =>
    LET lu == lastUndo IN
        /\ \A r \in lu.restored : rows[r[1]] = r[2]
        /\ \A r \in lu.conflicts : rows[r[1]] = lu.pre[r[1]]
        /\ \A r \in lu.deleted : rows[r[1]] = NoValue
        /\ lu.restored \cap lu.conflicts = {}
        /\ lu.restored \cap lu.deleted = {}
        /\ lu.conflicts \cap lu.deleted = {}
        /\ \A r \in lu.captured : r \in lu.restored \/ r \in lu.conflicts \/ r \in lu.deleted

ConflictNotOverwritten ==
    undoFresh => \A r \in lastUndo.conflicts : rows[r[1]] /= r[2]

=======================================================================
