# Formal specifications

This directory holds the formal foundation for the multi-user, extension,
durable-job and journal/undo designs. It contains four bounded TLA+ models, the
JSON schemas for the declarative extension documents, and example and
counterexample fixtures.

The models are design checks. The Haskell server and the Miso client are not
proved to refine them. The scope section below says exactly what is checked.

## Files

```
spec/
  MultiUser.tla       bounded model of the control database and per-user databases
  MultiUser.cfg       bounds: two accounts, two databases, two usernames, two nonces
  Extensions.tla      bounded model of views, webhooks, and the event outbox
  Extensions.cfg      bounds: two accounts, two views, two webhooks, two events
  Jobs.tla            bounded model of the durable egress job queue
  Jobs.cfg            bounds: three jobs, two workers, two attempts
  Undo.tla            bounded model of the journal and the restore/conflict rule
  Undo.cfg            bounds: three rows, two values, journal depth 2
  README.md           this file
  schema/
    view.schema.json      view wrapper and graph/ledger definitions, draft 2020-12
    webhook.schema.json   webhook document, draft 2020-12
  examples/           documents that satisfy the plan constraints
  bad/                documents that violate exactly one plan constraint
```

`scripts/check-specs.sh` runs TLC on all four models and validates the JSON.
The CI workflow runs the same script.

## Threat model

The design has to hold these lines under a compromised or careless client.

- A session, API token, or share token must never reach another account's
  database. Tokens are `u<id>_<random>`; the prefix picks the database and the
  full token is hashed, so a rewritten prefix matches no stored row.
- A disabled account must keep no usable session or token. Disabling deletes
  them and the account's library content stays in its own database.
- A legacy unprefixed credential must not become an ambiguous mapping once a
  second account exists. It resolves only while exactly one account is enabled.
- An admin must not read another account's library content. Admin rights cover
  account creation and disabling, not user data.
- The control database must keep at least one enabled admin while it holds any
  account, so the instance cannot lock itself out.
- An extension definition is data. It must not execute code, and it must not
  edit another account's view or webhook.
- A webhook must only receive events from its owner's database. A disabled
  webhook must receive nothing. The delivery cursor must never move backwards.
- Each (owner, kind) pair has at most one default view.
- A job is claimed by at most one worker at a time, and at most one job per
  (kind, target) is active; retries are bounded and a crash-reset returns the
  job to the queue without losing its attempt count. A completed job has
  performed its external effect at least once.
- An undo restores the newest journal entry's before-images. A row whose key
  now holds different content is refused as a URL conflict and never
  overwritten; the abstract search index must match the restored rows (the
  restore rebuilds FTS rather than leaving stale terms).

Out of scope for these models: network attackers on the HTTP surface, TLS,
rate limiting, password guessing, and WebAuthn ceremony correctness. Those
belong to the existing server design and the M0 authorization matrix
workstream.

## Assumptions

- One node runs one server process against a control database and one SQLite
  file per user. SQLite serializes writers; the deployment keeps one replica.
- Credentials, sessions, views, webhooks, events, and share links live in the
  user database. The control database holds account rows and no library data.
- Extensions v1 are declarative. A view or webhook document is stored, read,
  and validated against the schemas here. No extension-provided code runs.
- Event delivery uses a transactional outbox, at-least-once delivery, an HMAC
  signature, retries, and disable on terminal failure. The models abstract
  timing, HTTP calls, and cryptography.
- Egress jobs use the SQLite `jobs` table: an atomic conditional claim, a
  bounded retry/backoff, a crash reset of running rows, and a partial unique
  index for one active job per kind and target. The models abstract SQL and
  treat each external effect as atomic.
- Undo snapshots are before-images recorded in the same transaction as the
  write. The journal/undo model abstracts row tables to one entity map, the
  JSON encoding of a before-image, and the FTS triggers; it keeps the restore
  selection rule and the conflict rule exact.
- The token formats and the control database columns are those in the approved
  plan: `users(id, username UNIQUE COLLATE NOCASE, db_path UNIQUE, role,
  credential_handle, created_at, disabled_at, last_login_at)`.

## What TLC proves

TLC enumerates every reachable state of each bounded transition system. The
bounds come from the `.cfg` file. For the current bounds the models have about
48,000 reachable states (`MultiUser`) and 232,000 (`Extensions`), and each
check finishes in seconds.

`MultiUser.tla` checks these invariants in every reachable state:

| Invariant | Meaning |
|---|---|
| `NoCrossUserAccess` | A resolved request for user u recorded db(u). |
| `SessionStableUser` | A session token resolves only to the account id in its prefix. |
| `TokenStableUser` | API and share tokens follow the same prefix rule. |
| `DisabledUserNoSession` | No enabled user session or token points at a disabled account. |
| `SoleUserFallbackOnly` | A legacy credential resolves only with exactly one enabled account, and to that account. |
| `AtLeastOneAdmin` | While any account exists, an enabled admin exists. |
| `AccountKeysUnique` | Usernames and account ids are unique. |
| `DbPathsUnique` | Database paths are unique. |
| `RoleRegistered` | Every account has a role, and no other id does. |
| `LoginAuthConsistent` | A successful login reported an account and left its session; a failed login left no session. |

`Extensions.tla` checks these:

| Invariant | Meaning |
|---|---|
| `ViewOwnerOnly` | Every view write records the view owner as the acting account. |
| `ViewIdUnique` | View ids are unique. |
| `DefaultUniquePerKind` | At most one view per (owner, kind) is the default. |
| `WebhookOwnerOnly` | The last event delivered to a webhook belongs to the webhook owner. |
| `DisabledWebhookNoDelivery` | A disabled webhook cursor is parked past the event range, so no delivery advances it. |
| `NoCodeExecution` | A run counter that no transition increments stays zero; the model has no transition that evaluates extension data. |
| `CursorMonotone` | An action property checked by TLC: across every transition each webhook cursor never decreases. |

`Jobs.tla` checks these:

| Invariant | Meaning |
|---|---|
| `SingleOwner` | A running job has exactly one worker. |
| `QueuedNoOwner` | Queued jobs are not owned by a worker. |
| `NoActiveDuplicate` | At most one queued/running job per (kind, target). |
| `AttemptsBounded` | The attempt counter never exceeds `MaxAttempts`. |
| `DeliveredAfterClaim` | An external effect only occurs for a claimed job. |
| `DoneDelivered` | A completed job performed its external effect. |
| `CancelledUndelivered` | In this model delivery is atomic with completion, so a cancelled job has no effect. |

`Undo.tla` checks these:

| Invariant | Meaning |
|---|---|
| `IndexMatchesRows` | The abstract FTS index equals the current searchable rows (restores rebuild it). |
| `JournalBounded` | The journal never exceeds `MaxEntries`; appends prune the oldest. |
| `UndoConsistent` | After an undo, restored rows hold their before-image, deleted rows are absent again, conflicts are unchanged, and restored/conflicts/deleted partition the captured set. |
| `ConflictNotOverwritten` | A conflict row never takes the captured value. |

The bounds are part of the claim. Two accounts and two databases exercise one
cross-account collision, one second-admin disable, and one two-user legacy
fallback. Two views exercise the default rule for both kinds. Two webhooks and
two events exercise owner matching, disable, and cursor progress. Three jobs
(two sharing a kind+target) and two workers exercise duplicate suppression,
the retry bound, completion delivery and crash reset. Three journaled rows,
two values and journal depth two exercise update/insert/delete undo, URL
conflict refusal, oldest-entry pruning and FTS index consistency. A larger
bound adds states but not a new kind of transition; it is not required for
these invariants. Current bounds find about 48,000 (`MultiUser`), 232,000
(`Extensions`), 2,000 (`Jobs`) and 216,000 (`Undo`) distinct states.

The JSON checks are shape checks. `view.schema.json` and
`webhook.schema.json` are draft 2020-12 schemas. The validator in the script
checks the schemas themselves and the fixtures when a JSON-Schema validator is
available; otherwise `jq` checks the same constraints the schemas state.

## What is not proven

- There is no refinement proof. Nothing checks that the Haskell server, the
  SQLite schema, or the Miso client implements these transitions. A passing
  TLC run says the design model keeps the invariants, not that the program does.
- Cryptography is assumed, not modeled. The models treat `sha256(full token)`,
  HMAC signatures, and Argon2id hashes as opaque and correct.
- SQLite behavior is assumed. Transactions, WAL, unique constraints, and
  foreign keys are modeled as atomic state changes.
- HTTP details are out of scope: CSRF, `Origin` checks, cookies, status codes,
  and body limits are not in the models.
- Timing and liveness are out of scope. Retries, backoff, HMAC freshness,
  session expiry, worker shutdown, and "a queued job is eventually claimed" are
  not checked. The models would need fairness and time to state those.
- Worker/network failure modes are abstracted: a job failure is a modeled
  transition, not a timeout; an external effect (webhook POST, snapshot file,
  provider call) is atomic with job completion and can be attempted again after
  a retry. The implementation must keep the claim atomic and the effects
  idempotent enough for at-least-once delivery.
- The journal model abstracts before-image encoding and FTS trigger mechanics:
  the index is a derived set, not an FTS5 table, and the model checks that the
  restore leaves it consistent rather than checking trigger SQL.
- The schemas check shape, not semantics. A query string of 512 characters can
  still be nonsense; the Haskell parser is the deeper check. The decoder
  contract is covered: `server/test/ViewContractSpec.hs` (run by
  `cabal test all`) decodes every example document with the real server codecs
  and rejects every `spec/bad/` fixture. That test is part of the normal test
  suite; `scripts/check-specs.sh` still checks JSON shape and the TLA+ model
  only.
- The authorization matrix for current routes is a separate M0 workstream. The
  models cover the multi-user and extension transitions only.

## Running the checks

Inside the development shell, which provides `tlc` and `jq`:

```bash
devenv shell -- spec
devenv shell -- bash scripts/check-specs.sh
```

Outside the shell, point the script at the TLA+ tools jar:

```bash
TLA2TOOLS_JAR=/path/to/tla2tools.jar bash scripts/check-specs.sh
```

The script finds TLC in this order: `$TLA2TOOLS_JAR`, the `tlc` command, a
`tla2tools.jar` under a nix profile, then `nix build nixpkgs#tlaplus`. It fails
with a clear message when no TLC is available. The dev shell pins `tlaplus`
1.7.4 from nixpkgs, which ships TLC 2.19.

A single model can be checked directly:

```bash
cd spec
tlc -config MultiUser.cfg MultiUser.tla
tlc -config Extensions.cfg Extensions.tla
```

The JSON fixtures can be inspected directly:

```bash
jq -e . spec/schema/view.schema.json
jq -e . spec/examples/graph-view.json
```

## Changing the models

Keep the state space small. Add a bound to the `.cfg` file rather than a new
constant when a model needs another account, view, or event. Run
`scripts/check-specs.sh` after any change. The `bad/` fixtures exist so a schema
edit that accepts an invalid document is noticed by the script.

The schema assumptions that need review:

- `slug` is lowercase letters, digits, and hyphens, at most 48 characters.
- `ledger.definition.sort` accepts `created`, `added`, or `opened`, matching the
  bookmarks API sort parameter.
- `is_default` is optional and defaults to false. The bounded model still
  treats a missing default as no default.
- `webhook.enabled` is required in the document. A request may set it to false
  to create a stopped webhook.
- `webhook.url` accepts `http` and `https` only.
