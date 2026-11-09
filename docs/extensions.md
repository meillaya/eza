# Extension contract

eza can be extended without running anyone else's code. Extensions v1 has two
extension surfaces: declarative views stored in the library, and webhooks that
receive signed HTTP POSTs when the library changes. Both travel over the
versioned HTTP API.

A view is a JSON document. The server validates it, stores it, and the client
renders it; nothing in the document is executed. A webhook is a URL the server
posts to. There is no plugin loader, no sandboxed script host, and no custom
extraction code in v1. The browser clipper and the extraction sidecar are
documented separately and are not part of this contract.

The endpoint reference is [API.md](API.md). The JSON schemas, example
documents, counterexamples and formal models are in [../spec/README.md](../spec/README.md).
This page covers what the contract promises, the document shapes, the limits,
and how to consume events safely.

## What an extension is

- **Views** are declarative graph and ledger documents stored in the library.
  A graph view carries the graph filter, label mode, layout preset, local depth
  and colour groups. A ledger view carries a search expression and a sort. The
  boot payload includes the stored views, and every database seeds one default
  graph view, so a fresh install has something to open.
- **Webhooks** are outbound integrations. The server records a library change
  in an event outbox in the same transaction as the write, then posts a signed
  `EventEnvelope` to each enabled subscription that named the event kind.
  Delivery is at least once, retried, and disabled after a terminal failure.
- **The API** is the read and write surface those documents travel over. The
  JSON API lives under `/api/v1` and is described in [API.md](API.md).

Out of scope for v1: sandboxed UI plugins, third-party code executed in the
server or the browser, script hooks, and custom import or extraction code. A
view cannot call a function, and a webhook cannot ask eza to run one.

## Versioning and stability

`/api/v1` is the stable surface. Within v1, new routes, response fields, view
definition fields, and event kinds may be added, and existing status codes keep
their meaning. A client should ignore response fields it does not know and must
not fail when one appears. An incompatible change ships under a new prefix or
is announced in [API.md](API.md) with a deprecation window before removal; it
does not silently change a v1 field.

Stored and imported view documents carry `"schema": 1` on the wrapper. A
document with an unknown wrapper schema or an unknown `kind` is rejected with
`400 bad_request`. A definition shape change that old readers could not ignore
bumps the schema number instead. The JSON schemas in
[../spec/schema](../spec/schema) are the shape contract; the server is the
semantic check behind them, covering slug rules, query length, colours, local
depth, and operators the graph does not support.

The webhook event catalog is versioned with the API. Subscriptions name the
event kinds they want; an unknown kind is rejected when the subscription is
created or updated. A receiver should treat an unrecognised `type` as a
version skew and ignore that delivery, not as a reason to fail the endpoint.

Authentication has three token scopes: `read`, `write` and `capture`. Read
routes accept a `read` or `write` token, write routes need `write`, and the
capture routes use `capture`. Webhook management is session-only: a bearer
token, including a `write` token, is rejected with 403 `session_required`. The
same session-only rule covers account, token and rule management, and clip
template writes. Cookie requests with unsafe methods also need the
`X-CSRF-Token` header; bearer requests do not use CSRF.

## Views

### Document shape

A stored view is a wrapper with a versioned schema, a server-assigned identity,
and a definition whose shape depends on the kind:

| Field | Type | Notes |
|---|---|---|
| `schema` | integer | `1`. Assigned by the server, rejected when unknown. |
| `id` | integer | Server-assigned. |
| `slug` | string | At most 48 characters, lowercase letters, digits and hyphens. Used in URLs and as the view name in routes. |
| `name` | string | Required, at most 80 characters. |
| `kind` | string | `graph` or `ledger`. |
| `is_default` | boolean | At most one default per kind. |
| `definition` | object | Graph or ledger shape, below. |
| `created_at` | integer | POSIX seconds, server-assigned. |
| `updated_at` | integer | POSIX seconds, server-assigned. |

A create request sends a `ViewInput`: `name`, `kind`, `definition`, and an
optional `slug`. When the slug is omitted the server derives it from the name,
appends `-2`, `-3` and so on on a collision, and stores the result. The server
owns `id`, `schema`, `created_at`, `updated_at` and the default flag on create;
set a default with a PATCH.

The full wrapper is what export and import carry. See
[../spec/examples/graph-view.json](../spec/examples/graph-view.json) and
[../spec/examples/ledger-view.json](../spec/examples/ledger-view.json), and
[view.schema.json](../spec/schema/view.schema.json) for the machine shape.

### Graph definitions

| Field | Type | Notes |
|---|---|---|
| `query` | string | Search expression, at most 512 characters, same syntax as the ledger `q` parameter. |
| `tags_shown` | boolean | Draw tag nodes. |
| `label_mode` | string | `auto`, `tags` or `none`. |
| `layout_preset` | string | `compact`, `standard` or `airy`. Deterministic spacing. |
| `local_depth` | integer or null | `1` to `3` for a neighbourhood around the focused record; null for the whole library. |
| `color_groups` | array | Up to 24 ordered colour rules. |

The query is evaluated against the fields the graph payload carries: title,
domain, tag names, filed date, read and dead flags. The graph has no record
URLs, so `link:` is rejected in a graph view. `year:` and `day:` work, and the
filed date is UTC.

A colour group is `{"name","query","color","enabled"}`, with a `#rrggbb` colour
and a query of its own, evaluated against the same record fields. Groups are
ordered and the first enabled match wins: a record takes the colour of the
first enabled group whose query matches it, and a tag takes the colour of the
first enabled group whose query matches the tag name. A disabled group is
skipped. The match is declarative; the client caches the assignment and
recomputes it only when the view or the library changes.

### Ledger definitions

| Field | Type | Notes |
|---|---|---|
| `query` | string | Search expression, at most 512 characters. |
| `sort` | string | `created`, `added` or `opened`, matching the bookmarks API sort parameter. |

An empty query with the `created` sort opens the ordinary ledger.

### Limits

| Limit | Value |
|---|---|
| Views per database | 64 |
| Name | 80 characters |
| Slug | 48 characters, lowercase letters, digits and hyphens |
| Query, per view and per colour group | 512 characters |
| Colour groups per graph view | 24 |
| Colour | `#rrggbb` |
| `local_depth` | 1 to 3 |
| Colour group name | 80 characters |

The server enforces these defaults, and the schema records them. A create
beyond the view limit returns `409 view_limit`. Validation failures return
`400 bad_request` with a message, and an unknown slug returns `404 not_found`.
Errors use the envelope `{"error":{"code":...,"message":...}}` described in
[API.md](API.md).

### Lifecycle

```
GET    /api/v1/views
POST   /api/v1/views
GET    /api/v1/views/{slug}
PATCH  /api/v1/views/{slug}
DELETE /api/v1/views/{slug}
```

`GET /api/v1/views` returns `{"views":[View]}`, default first, then graph views
before ledger views, then slug. `POST` returns 201 with the stored wrapper, and
`DELETE` returns 204. `PATCH` accepts any of `name`, `slug`, `definition` and
`is_default` and returns the updated wrapper; fields that are omitted keep
their value. Setting `is_default` true clears the flag on the other views of the
same kind in the same transaction. Deleting the current default promotes the
lowest-id remaining view of that kind, and deleting the last graph view seeds
the default graph view again.

The boot payload carries the same views, so the client can select the default
graph view without a second request.

### Example

Create a graph view with a write token:

```bash
curl -sS -X POST https://eza.example/api/v1/views \
  -H "Authorization: Bearer $EZA_WRITE_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "name": "Reading graph",
    "kind": "graph",
    "definition": {
      "query": "is:unread tag:reading",
      "tags_shown": true,
      "label_mode": "auto",
      "layout_preset": "standard",
      "local_depth": 2,
      "color_groups": [
        {"name": "Reading", "query": "tag:reading", "color": "#3b6ea5", "enabled": true}
      ]
    }
  }'
```

Make it the default and then delete it:

```bash
curl -sS -X PATCH https://eza.example/api/v1/views/reading-graph \
  -H "Authorization: Bearer $EZA_WRITE_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"is_default":true}'

curl -sS -X DELETE https://eza.example/api/v1/views/reading-graph \
  -H "Authorization: Bearer $EZA_WRITE_TOKEN"
```

## Webhooks

### Subscription document

| Field | Type | Notes |
|---|---|---|
| `name` | string | Required, at most 80 characters. |
| `url` | string | Required, absolute `http` or `https` URL, at most 2048 characters. |
| `events` | array | One to four unique event kinds from the catalog below. |
| `enabled` | boolean | Delivery is attempted only while true. Omitted on create it defaults to true. |

At most 16 subscriptions exist per database. A create beyond the limit returns
`409 webhook_limit`. A missing subscription returns `404 not_found`, and
validation failures return `400 bad_request`. The stored object also carries
`id`, `created_at`, `last_status`, `last_attempt_at`, `last_error` and
`fail_streak`; the secret is separate and never part of the list payload.

`PATCH /api/v1/webhooks/{id}` takes a full subscription document, not a partial
one: send `name`, `url`, `events` and `enabled` together. To re-enable a
disabled subscription after fixing the receiver, PATCH it with `enabled` true.

### Management routes

```
GET    /api/v1/webhooks
POST   /api/v1/webhooks
GET    /api/v1/webhooks/{id}
PATCH  /api/v1/webhooks/{id}
DELETE /api/v1/webhooks/{id}
POST   /api/v1/webhooks/{id}/test
GET    /api/v1/webhooks/{id}/deliveries?limit=20
```

Management is session-only. A bearer token is rejected with 403
`session_required` even when it carries the `write` scope. With a cookie
session, unsafe methods need `X-CSRF-Token`. `GET /api/v1/webhooks` returns
`{"webhooks":[Webhook]}`; `POST` returns 201 with
`{"webhook":Webhook,"secret":Text}`; `PATCH` returns the updated `Webhook`;
`DELETE` returns 204.

### Secrets

The create response carries a 64-character lowercase hex secret. That is the
only time the server returns it, and the list and update responses never
include it. The secret is the HMAC key exactly as returned: the ASCII string,
not its hex-decoded bytes. Store it in the receiver's secret storage, never in
a URL, a log line or a client bundle. If it is lost, delete the subscription
and create it again; PATCH does not accept a new secret.

### Event catalogue

Every event is an envelope:

```json
{
  "id": "evt-42",
  "type": "bookmark.updated",
  "occurred_at": 1700000100,
  "data": {
    "id": 245,
    "url": "https://example.com/page",
    "title": "A page",
    "domain": "example.com",
    "is_read": false,
    "is_dead": false,
    "tags": ["reading", "rust"]
  }
}
```

| Event | `data` shape |
|---|---|
| `bookmark.created` | `{"id","url","title","domain","is_read","is_dead","tags":[Text]}` |
| `bookmark.updated` | the same bookmark object |
| `bookmark.deleted` | the same bookmark object, captured before the row is removed |
| `clip.created` | `{"capture_id","bookmark_id"}` |

`id` is stable for one outbox event and `occurred_at` is POSIX seconds. The
event row is written in the same transaction as the library change, so an event
exists if and only if the write committed. Merge and merge-all emit
`bookmark.updated` for each keeper and `bookmark.deleted` for each absorbed row;
bulk tag and read changes emit `bookmark.updated` per affected row. A no-op
patch and an idempotent clip replay record nothing, and imports do not emit
per-row events. The v1 catalog has no `import.completed`. A clip emits
`clip.created` and does not re-emit its bookmark side as
`bookmark.created`.

### Delivery request

Each delivery is one `POST` with a JSON body and these headers:

| Header | Value |
|---|---|
| `X-Eza-Event` | The event type, for example `bookmark.created`. |
| `X-Eza-Delivery` | The delivery id, stable across retries of one delivery. |
| `X-Eza-Timestamp` | POSIX seconds at send time. |
| `X-Eza-Signature` | `sha256=` plus the lowercase hex HMAC-SHA256 of the timestamp, a dot, and the raw body, keyed with the subscription secret. |
| `Content-Type` | `application/json` |

The signed message is `X-Eza-Timestamp + "." + body`. The body is the exact
bytes on the wire; parse it after verifying, not before. A receiver that reads
the body through a JSON layer may normalize whitespace or reorder keys and then
fail the check.

```python
import hashlib
import hmac


def verify(secret: str, timestamp: str, body: bytes, signature: str) -> bool:
    message = timestamp.encode("utf-8") + b"." + body
    expected = "sha256=" + hmac.new(
        secret.encode("utf-8"), message, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)
```

A receiver should also reject an old timestamp (a few minutes is a reasonable
window), return 2xx only after the event is durably handled, and treat the
delivery id as the idempotency key. The secret proves the request came from
eza; it does not encrypt the payload, so use HTTPS and keep logs out of the
body if the library contents are sensitive.

### Retries and failure

A delivery gets five attempts in total. The first failure schedules the next
attempt after 30 seconds, then 60, 120 and 240 seconds. If the fifth attempt
fails, the delivery is marked `failed` and the subscription is disabled so a
dead receiver cannot be retried forever. Fix the receiver, then PATCH the
subscription with `enabled` true. A disabled subscription receives nothing
while it is disabled.

Only a 2xx response counts as delivered. A 3xx is a failure because redirects
are not followed, and a 4xx or 5xx is a failure and schedules the next attempt.
Response bodies are drained within the size cap and discarded; the status code
is recorded, not the answer.

`POST /api/v1/webhooks/{id}/test` sends one synthetic delivery through the same
signed path and returns `{"ok":Bool,"status":Maybe Int,"error":Text}`. The test
envelope has `id` `evt-test`, type `bookmark.updated`, and `data` `{"test":true}`,
and its `X-Eza-Delivery` is `test`. The result updates the subscription's
`last_status`, `last_attempt_at` and `last_error`; it does not create a
delivery row.

### Delivery records and retention

`GET /api/v1/webhooks/{id}/deliveries` returns the most recent deliveries as
`{"deliveries":[DeliveryView]}`, newest first. `limit` defaults to 20 and is
clamped to 1-100. A delivery has `id`, `event`, `state`, `attempts`,
`last_error` and `created_at`. The states are `queued`, `delivering`,
`delivered` and `failed`. Events and finished deliveries older than 30 days
are purged.

### Outbound policy

The URL must be absolute `http` or `https`. The server resolves the host on
every request and rejects loopback, link-local, private, documentation and
multicast addresses. An operator can lift the private-network guard with
`EZA_ALLOW_PRIVATE_FETCH=1` for a deliberately local receiver; leave it off
otherwise. Redirects are not followed. The request body is capped at 64 KiB
and the same cap bounds the response drain, so a receiver cannot fill the
database with its answer. Each attempt uses the server's outbound fetch
timeout, `EZA_FETCH_TIMEOUT_MS`.

### At-least-once delivery

Delivery is at least once, not exactly once. A receiver may see the same
delivery more than once: a crash between the send and the delivery record,
or a retry after a timeout whose response was lost. Make the handler
idempotent and record the `X-Eza-Delivery` value (or the envelope `id`)
before applying the side effect. The fan-out itself is guarded by a unique
`(webhook, event)` row and a persistent cursor, so one event is queued at
most once per subscription.

Ordering is not guaranteed. A retry with a backoff can arrive after a later
event, so consume events as independent facts about the library rather than as
an ordered stream.

## Threat model and boundaries

Extensions v1 is data. The server validates a view or a webhook against the
schemas and the semantic rules above, stores it, and renders or posts it from
the trusted code that already exists. No extension-provided code path exists,
so there is no sandbox to escape. The bounded `NoCodeExecution` invariant in
[Extensions.tla](../spec/Extensions.tla) models this with a run counter that no
transition increments.

The design targets multiple accounts. In that design each account's views,
webhooks, events and deliveries live in that account's database; a view or
webhook write is recorded against its owner; a webhook receives events only
from its owner's database; a disabled webhook receives nothing; and each
(owner, kind) pair has at most one default view. An admin can create, disable,
reset, and delete accounts but cannot read another account's library content
without taking the account over; an admin password reset is a deliberate
break-glass path and should only be used for account recovery. Those
rules are enforced by the server's per-account database routing and are
exercised by the multi-user browser and API tests; the formal models in
[../spec/README.md](../spec/README.md) are the bounded design check behind
them.

What an extension cannot do in v1:

- run code in the server or the client;
- read or write another account's library content;
- edit another account's views or webhooks;
- manage webhooks with a bearer token;
- choose a scheme other than `http` or `https`, or reach a private address
  unless the operator lifts the guard;
- make the server follow a redirect;
- recover a webhook secret after creation.

Snapshot capture is a separate egress path: `POST
/api/v1/bookmarks/{id}/snapshot` checks the stored bookmark URL against the
same public-address policy before it spawns `monolith`, and the captured file
is size-capped. `monolith` itself is a general-purpose fetcher; its own
redirect and subresource fetches are outside the guard. An operator hosting
untrusted members should set `EZA_MONOLITH` to a disabled command or accept
that risk.

The formal models are bounded design checks, not a proof about the Haskell
server or the Miso client. The models treat transactions, HTTP and
cryptography as atomic and correct, and they do not cover TLS, rate limiting,
credential guessing, or WebAuthn. [../spec/README.md](../spec/README.md) lists
exactly which invariants are checked and what is not proven.

## Further reading

- [API.md](API.md): the endpoint reference, DTOs and status codes.
- [../spec/README.md](../spec/README.md): threat model, bounded models, what
  TLC proves and what it does not.
- [view.schema.json](../spec/schema/view.schema.json) and
  [webhook.schema.json](../spec/schema/webhook.schema.json): draft 2020-12
  schemas.
- [../spec/examples](../spec/examples): valid graph, ledger and webhook
  documents.
