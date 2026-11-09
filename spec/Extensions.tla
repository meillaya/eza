--------------------------- MODULE Extensions ---------------------------
\* Bounded TLA+ model of the planned extensions v1 design.
\*
\* Two declarative surfaces live in each user database:
\*
\*   - views: a graph or ledger layout stored as JSON. A view has an owner,
\*     a kind, an at most one default per (owner, kind), and a revision.
\*     The definition is data; nothing in this model parses or runs it.
\*   - webhooks: a name, a URL, a subscribed event list, and an enabled flag.
\*     Events are appended to a transactional outbox; a delivery advances the
\*     webhook cursor; a terminal failure disables the webhook.
\*
\* The model checks:
\*
\*   ViewOwnerOnly             - a view is only written by its owner.
\*   WebhookOwnerOnly          - a webhook only receives events of its owner.
\*   DisabledWebhookNoDelivery - a disabled webhook accepts no delivery.
\*   CursorMonotone            - a webhook cursor never moves backwards.
\*   NoCodeExecution           - no transition executes extension-defined code.
\*   DefaultUniquePerKind      - at most one default view per (owner, kind).
\*
\* Nothing here proves that the Haskell implementation refines the model. See
\* spec/README.md for the scope, the threat model, and what is not checked.
\*
\* The definition payloads are validated by spec/schema/*.json, not by TLC.
\* TLC models the extension records as opaque data and the delivery state
\* machine. The bounds live in Extensions.cfg.

EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Users,          \* account ids, e.g. {u1, u2}
    ViewIds,        \* view ids (slugs), e.g. {v1, v2}
    WebhookIds,     \* webhook ids, e.g. {w1, w2}
    ViewKinds,      \* {"graph", "ledger"}
    EventKinds,     \* {"bookmark_created", "clip_created", ...}
    MaxViews,       \* bound on views per model
    MaxWebhooks,    \* bound on webhooks per model
    MaxEvents,      \* bound on events per model
    MaxRevisions    \* bound on a view revision counter

\* The delivery cursor is the index of the last event delivered to a webhook.
\* -1 means no delivery yet. A disabled webhook parks its cursor at FROZEN,
\* one past the bounded event range: disabling never lowers the cursor, so
\* CursorMonotone can be checked as a plain action property.
FROZEN == MaxEvents + 1
Cursors == {-1} \cup (1..MaxEvents) \cup {FROZEN}

ViewRecords ==
    [id : ViewIds, owner : Users, kind : ViewKinds, isDefault : BOOLEAN,
     revision : 0..MaxRevisions, writer : Users]
WebhookRecords == [id : WebhookIds, owner : Users, enabled : BOOLEAN]
EventRecords == [owner : Users, kind : EventKinds]

VARIABLE
    views,     \* SUBSET ViewRecords
    webhooks,  \* SUBSET WebhookRecords
    cursor,    \* [WebhookIds -> Cursors], last delivered event index
    events,    \* Seq(EventRecords), the transactional outbox
    codeRuns   \* 0..0, no action ever executes extension code

vars == <<views, webhooks, cursor, events, codeRuns>>

--------------------------------------------------------------------------------
\* Initial state: no views, no webhooks, no events, nothing executed.
--------------------------------------------------------------------------------

Init ==
    /\ views = {}
    /\ webhooks = {}
    /\ cursor = [id \in WebhookIds |-> -1]
    /\ events = <<>>
    /\ codeRuns = 0

--------------------------------------------------------------------------------
\* View actions. Every write is guarded by the view owner.
--------------------------------------------------------------------------------

CreateView(owner, id, kind) ==
    /\ owner \in Users
    /\ id \in ViewIds
    /\ kind \in ViewKinds
    /\ Cardinality(views) < MaxViews
    /\ \A v \in views : v.id # id
    /\ views' =
         views
           \cup
         {[id |-> id, owner |-> owner, kind |-> kind, isDefault |-> FALSE,
           revision |-> 0, writer |-> owner]}
    /\ UNCHANGED <<webhooks, cursor, events, codeRuns>>

UpdateView(actor, v) ==
    /\ v \in views
    /\ v.owner = actor
    /\ v.revision < MaxRevisions
    /\ views' =
         (views \ {v})
           \cup
         {[id |-> v.id, owner |-> v.owner, kind |-> v.kind,
           isDefault |-> v.isDefault, revision |-> v.revision + 1,
           writer |-> actor]}
    /\ UNCHANGED <<webhooks, cursor, events, codeRuns>>

DeleteView(actor, v) ==
    /\ v \in views
    /\ v.owner = actor
    /\ views' = views \ {v}
    /\ UNCHANGED <<webhooks, cursor, events, codeRuns>>

\* Make one view the default for its (owner, kind) and clear the previous
\* default of that owner and kind. Other owners and other kinds are untouched.
SetDefault(actor, v) ==
    /\ v \in views
    /\ v.owner = actor
    /\ views' =
         {[id |-> w.id, owner |-> w.owner, kind |-> w.kind,
           isDefault |-> IF w.owner = v.owner /\ w.kind = v.kind
                         THEN w.id = v.id
                         ELSE w.isDefault,
           revision |-> w.revision,
           writer |-> IF w.id = v.id THEN actor ELSE w.writer] : w \in views}
    /\ UNCHANGED <<webhooks, cursor, events, codeRuns>>

--------------------------------------------------------------------------------
\* Webhook and event actions.
--------------------------------------------------------------------------------

CreateWebhook(owner, id) ==
    /\ owner \in Users
    /\ id \in WebhookIds
    /\ Cardinality(webhooks) < MaxWebhooks
    /\ \A w \in webhooks : w.id # id
    /\ webhooks' = webhooks \cup {[id |-> id, owner |-> owner, enabled |-> TRUE]}
    /\ cursor' = [cursor EXCEPT ![id] = -1]
    /\ UNCHANGED <<views, events, codeRuns>>

\* Stop delivering on operator request: the webhook record stays, disabled.
DisableWebhook(id) ==
    /\ \E w \in webhooks : w.id = id /\ w.enabled
    /\ webhooks' =
         {[id |-> w.id, owner |-> w.owner,
           enabled |-> IF w.id = id THEN FALSE ELSE w.enabled] : w \in webhooks}
    /\ cursor' = [cursor EXCEPT ![id] = FROZEN]
    /\ UNCHANGED <<views, events, codeRuns>>

\* A delivery exhausts its retries. The design disables the webhook rather than
\* retrying forever, so the state change is the same as an explicit disable.
\* The HMAC signature, HTTP call, and backoff schedule are not part of the
\* model; only their safety-relevant consequence is.
Fail(id) ==
    /\ \E w \in webhooks : w.id = id /\ w.enabled
    /\ webhooks' =
         {[id |-> w.id, owner |-> w.owner,
           enabled |-> IF w.id = id THEN FALSE ELSE w.enabled] : w \in webhooks}
    /\ cursor' = [cursor EXCEPT ![id] = FROZEN]
    /\ UNCHANGED <<views, events, codeRuns>>

\* Append to the transactional outbox. The outbox is per user database; the
\* event owner is the account whose database holds it.
RecordEvent(owner, kind) ==
    /\ owner \in Users
    /\ kind \in EventKinds
    /\ Len(events) < MaxEvents
    /\ events' = Append(events, [owner |-> owner, kind |-> kind])
    /\ UNCHANGED <<views, webhooks, cursor, codeRuns>>

\* Deliver the next outbox event to an enabled webhook whose owner matches the
\* event owner. Delivery is at least once: the outbox row is removed after an
\* acknowledged delivery, so a retry resends it. The model advances the cursor
\* one event at a time and a repeated attempt is a stuttering step.
Deliver(id) ==
    \E w \in webhooks :
        /\ w.id = id
        /\ w.enabled
        /\ cursor[id] \in {-1} \cup (1..MaxEvents)
        /\ LET next == IF cursor[id] = -1 THEN 1 ELSE cursor[id] + 1
           IN /\ IF next <= Len(events)
                 THEN events[next].owner = w.owner
                 ELSE FALSE
              /\ cursor' = [cursor EXCEPT ![id] = next]
              /\ UNCHANGED <<views, webhooks, events, codeRuns>>

Next ==
    \/ \E owner \in Users, id \in ViewIds, kind \in ViewKinds :
           CreateView(owner, id, kind)
    \/ \E actor \in Users, v \in views : UpdateView(actor, v)
    \/ \E actor \in Users, v \in views : DeleteView(actor, v)
    \/ \E actor \in Users, v \in views : SetDefault(actor, v)
    \/ \E owner \in Users, id \in WebhookIds : CreateWebhook(owner, id)
    \/ \E id \in WebhookIds : DisableWebhook(id)
    \/ \E id \in WebhookIds : Fail(id)
    \/ \E owner \in Users, kind \in EventKinds : RecordEvent(owner, kind)
    \/ \E id \in WebhookIds : Deliver(id)

Spec == Init /\ [][Next]_vars

--------------------------------------------------------------------------------
\* Invariants
--------------------------------------------------------------------------------

TypeOK ==
    /\ views \subseteq ViewRecords
    /\ webhooks \subseteq WebhookRecords
    /\ cursor \in [WebhookIds -> Cursors]
    /\ Len(events) <= MaxEvents
    /\ \A i \in DOMAIN events : events[i] \in EventRecords
    /\ codeRuns \in 0..0

\* A view is only created, edited, deleted, or made default by its owner.
\* @writer@ records the acting account, and it is always the owner.
ViewOwnerOnly ==
    \A v \in views : v.writer = v.owner

\* View ids are unique across the model, as slugs are unique per user database.
ViewIdUnique ==
    \A v1, v2 \in views : v1 # v2 => v1.id # v2.id

\* At most one default view per (owner, kind).
DefaultUniquePerKind ==
    \A v1, v2 \in views :
        (v1.owner = v2.owner /\ v1.kind = v2.kind
           /\ v1.isDefault /\ v2.isDefault)
        => v1 = v2

\* A webhook receives only events recorded in its owner's database. The
\* last-delivered event therefore has the webhook owner, and earlier
\* deliveries were checked by the same guard.
WebhookOwnerOnly ==
    \A w \in webhooks :
        IF w.enabled
        THEN /\ cursor[w.id] \in {-1} \cup (1..MaxEvents)
             /\ IF cursor[w.id] = -1
                THEN TRUE
                ELSE IF cursor[w.id] <= Len(events)
                     THEN events[cursor[w.id]].owner = w.owner
                     ELSE FALSE
        ELSE cursor[w.id] = FROZEN

\* Disabling a webhook parks its cursor past the event range. Deliver is only
\* enabled for an enabled webhook, so a disabled webhook never advances again.
DisabledWebhookNoDelivery ==
    \A w \in webhooks : w.enabled = FALSE => cursor[w.id] = FROZEN

\* CursorMonotone is an action property: across every transition the cursor
\* never decreases. Disabling parks it at FROZEN, which is above every event
\* index, so it is monotone there too. TLC checks the PROPERTY entry in the
\* config; the other invariants above also pin the cursor to a live event.
CursorMonotone ==
    [][ \A id \in WebhookIds : cursor'[id] >= cursor[id] ]_cursor

\* No transition in this model evaluates an extension-provided definition, and
\* no variable holds executable code. View definitions are opaque JSON data
\* validated by the schemas; webhook delivery only advances a cursor.
NoCodeExecution ==
    codeRuns = 0

=============================================================================
