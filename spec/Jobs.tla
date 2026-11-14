---------------------------- MODULE Jobs ----------------------------
\* Bounded TLA+ model of the durable egress job queue.
\*
\* A job row has a kind and a target (a bookmark, webhook, or sweep range),
\* a state, a set of attempts, an owner while running, and an abstract
\* external-effect flag for at-least-once delivery. The model checks the
\* properties the server relies on:
\*
\*   1. TypeOK                - all variables stay in their domains.
\*   2. SingleOwner           - a running job has exactly one worker.
\*   3. OueueNoOwner          - queued jobs are not owned by a worker.
\*   4. NoActiveDuplicate     - at most one queued/running job per kind+target
\*                              (the partial unique index).
\*   5. AttemptsBounded       - the retry counter never exceeds MaxAttempts.
\*   6. DeliveredAfterClaim   - an external effect only happens for a job that
\*                              was claimed at least once.
\*   7. DoneDelivered         - a completed job has performed its external
\*                              effect (at-least-once).
\*   8. CancelledUndelivered  - in this model delivery is atomic with
\*                              completion, so a cancelled job has no effect.
\*
\* Crash recovery is modeled: a worker crash/restart resets every job it owns
\* from running to queued without changing the attempt count. That is the
\* server's resetRunningJobs lifecycle.
\*
\* This is a bounded design check, not a refinement proof. The real worker
\* claim is an atomic conditional UPDATE; the model abstracts SQL and time
\* and treats the external effect as atomic with completion. See spec/README.md.
\*
\* Bounds: three jobs (two share a kind+target), two workers, at most two
\* attempts. Those bounds are the CONSTANTS below.

EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxAttempts  \* retries before a job is parked as failed, e.g. 2

ASSUME MaxAttempts \in Nat /\ MaxAttempts > 0

Jobs == {"j1", "j2", "j3"}
Workers == {"w1", "w2"}
Kinds == {"enrich", "snapshot"}
Targets == {"bookmark1", "webhook1"}
NoWorker == "none"
NoState == "none"

jobKind == [j1 |-> "enrich", j2 |-> "enrich", j3 |-> "snapshot"]
jobTarget == [j1 |-> "bookmark1", j2 |-> "bookmark1", j3 |-> "webhook1"]

States == {"none", "queued", "running", "done", "failed", "cancelled"}
Active(s) == s = "queued" \/ s = "running"
Terminal(s) == s = "done" \/ s = "failed" \/ s = "cancelled"

VARIABLE
    state,      \* [Jobs -> States]
    owner,      \* [Jobs -> Workers \cup {NoWorker}]
    attempts,   \* [Jobs -> 0..MaxAttempts]
    delivered   \* [Jobs -> BOOLEAN]

vars == <<state, owner, attempts, delivered>>

Init ==
    /\ state = [j \in Jobs |-> NoState]
    /\ owner = [j \in Jobs |-> NoWorker]
    /\ attempts = [j \in Jobs |-> 0]
    /\ delivered = [j \in Jobs |-> FALSE]

\* ---------------------------------------------------------------- actions ---

\* The partial unique index: no second active job for the same kind+target.
Enqueue(j) ==
    /\ state[j] = NoState
    /\ \A k \in Jobs :
        ~(Active(state[k]) /\ jobKind[k] = jobKind[j] /\ jobTarget[k] = jobTarget[j])
    /\ state' = [state EXCEPT ![j] = "queued"]
    /\ UNCHANGED <<owner, attempts, delivered>>

Claim(w, j) ==
    /\ state[j] = "queued"
    /\ attempts[j] < MaxAttempts
    /\ state' = [state EXCEPT ![j] = "running"]
    /\ owner' = [owner EXCEPT ![j] = w]
    /\ attempts' = [attempts EXCEPT ![j] = attempts[j] + 1]
    /\ UNCHANGED delivered

\* Successful completion performs the external effect exactly in this model.
Complete(w, j) ==
    /\ state[j] = "running"
    /\ owner[j] = w
    /\ state' = [state EXCEPT ![j] = "done"]
    /\ owner' = [owner EXCEPT ![j] = NoWorker]
    /\ delivered' = [delivered EXCEPT ![j] = TRUE]
    /\ UNCHANGED attempts

\* A failure retries while attempts remain, then parks the job as failed.
Fail(w, j) ==
    /\ state[j] = "running"
    /\ owner[j] = w
    /\ state' = [state EXCEPT ![j] = IF attempts[j] < MaxAttempts THEN "queued" ELSE "failed"]
    /\ owner' = [owner EXCEPT ![j] = NoWorker]
    /\ UNCHANGED <<attempts, delivered>>

\* An operator may cancel a queued or running job.
Cancel(j) ==
    /\ Active(state[j])
    /\ state' = [state EXCEPT ![j] = "cancelled"]
    /\ owner' = [owner EXCEPT ![j] = NoWorker]
    /\ UNCHANGED <<attempts, delivered>>

\* Process restart: every running job owned by this worker becomes queued again.
Crash(w) ==
    /\ \E j \in Jobs : state[j] = "running" /\ owner[j] = w
    /\ state' =
        [j \in Jobs |-> IF state[j] = "running" /\ owner[j] = w THEN "queued" ELSE state[j]]
    /\ owner' =
        [j \in Jobs |-> IF state[j] = "running" /\ owner[j] = w THEN NoWorker ELSE owner[j]]
    /\ UNCHANGED <<attempts, delivered>>

Next ==
    \/ \E j \in Jobs : Enqueue(j)
    \/ \E w \in Workers, j \in Jobs : Claim(w, j)
    \/ \E w \in Workers, j \in Jobs : Complete(w, j)
    \/ \E w \in Workers, j \in Jobs : Fail(w, j)
    \/ \E j \in Jobs : Cancel(j)
    \/ \E w \in Workers : Crash(w)

Spec == Init /\ [][Next]_vars

\* ------------------------------------------------------------- invariants ---

TypeOK ==
    /\ state \in [Jobs -> States]
    /\ owner \in [Jobs -> Workers \cup {NoWorker}]
    /\ attempts \in [Jobs -> 0..MaxAttempts]
    /\ delivered \in [Jobs -> BOOLEAN]

SingleOwner ==
    \A j \in Jobs : state[j] = "running" => owner[j] \in Workers

QueuedNoOwner ==
    \A j \in Jobs : state[j] /= "running" => owner[j] = NoWorker

NoActiveDuplicate ==
    \A j, k \in Jobs :
        (j /= k /\ Active(state[j]) /\ Active(state[k])) =>
            ~(jobKind[j] = jobKind[k] /\ jobTarget[j] = jobTarget[k])

AttemptsBounded ==
    \A j \in Jobs : attempts[j] <= MaxAttempts

DeliveredAfterClaim ==
    \A j \in Jobs : delivered[j] => attempts[j] > 0

DoneDelivered ==
    \A j \in Jobs : state[j] = "done" => delivered[j]

CancelledUndelivered ==
    \A j \in Jobs : state[j] = "cancelled" => delivered[j] = FALSE

TerminalStateKnown ==
    \A j \in Jobs : Terminal(state[j]) => state[j] \in {"done", "failed", "cancelled"}

=======================================================================
