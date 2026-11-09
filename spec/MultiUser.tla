---------------------------- MODULE MultiUser ----------------------------
\* Bounded TLA+ model of the planned multi-user design.
\*
\* The control database holds one row per account:
\*   users(id, username UNIQUE, db_path UNIQUE, role, credential_handle, ...)
\* Every account owns a separate SQLite database. Credentials and library rows
\* stay in the user database.
\*
\* The model checks five safety properties of that design:
\*
\*   1. NoCrossUserAccess     - a resolved request for user u reads db(u) only.
\*   2. SessionStableUser     - a session token resolves to the user id in its
\*                              u<id>_<random> prefix; a token whose prefix was
\*                              swapped matches no stored hash.
\*   3. DisabledUserNoSession - disabling a user deletes their sessions and
\*                              bearer tokens.
\*   4. SoleUserFallbackOnly  - a legacy unprefixed credential resolves only
\*                              while the control database has exactly one
\*                              enabled user.
\*   5. AtLeastOneAdmin       - once any account exists, at least one enabled
\*                              account has the admin role.
\*
\* The bounds are the CONSTANTS below: at most two accounts, two database
\* paths, two usernames, and two nonces for token material. One resolved
\* request and one failed login are enough to state the invariants; more only
\* grow the reachable state space without changing what is checked.
\*
\* This is a design model. The Haskell server is not proved to refine it; see
\* spec/README.md for the exact scope and for the assumptions the model makes.

EXTENDS Naturals, FiniteSets

CONSTANTS
    Users,      \* account ids, e.g. {u1, u2}
    Dbs,        \* per-user database paths, e.g. {db1, db2}
    Usernames,  \* control-database usernames, e.g. {alice, bob}
    Nonces      \* random token material, e.g. {n1, n2}

\* Values that are not parts of the bound. They are strings so that a record,
\* a model value, and the "none" marker stay distinguishable.
Roles == {"admin", "member"}
NoUser == "none"
NoDb == "none"
NoRole == "none"
NoRequest == [kind |-> "none", user |-> NoUser, db |-> NoDb]
NoAuth == [outcome |-> "none", user |-> NoUser]

\* A prefixed token is u<id>_<random>: the prefix is an account id and the
\* random part is a nonce. Unprefixed legacy tokens use the "none" prefix.
Prefixes == Users \cup {NoUser}
TokenSpace == Prefixes \X Nonces

\* Request kinds match the three authenticated route classes plus the legacy
\* fallback. The database path is part of the record because the invariant is
\* stated over the database a resolution actually opened.
RequestKinds == {"none", "session", "bearer", "share", "legacy"}
RequestRecords == [kind : RequestKinds, user : Users \cup {NoUser}, db : Dbs \cup {NoDb}]
AuthOutcomes == {"none", "ok", "denied"}
AuthRecords == [outcome : AuthOutcomes, user : Users \cup {NoUser}]

VARIABLE
    registry,    \* control-db rows: SUBSET (Usernames \X Users \X Dbs);
                 \* a username maps to one (user, db_path) row
    role,        \* [Users -> Roles \cup {NoRole}], set when the account is created
    disabled,    \* SUBSET Users
    sessions,    \* [TokenSpace -> Users \cup {NoUser}], rows in user databases
    tokens,      \* [TokenSpace -> Users \cup {NoUser}], API and share tokens
    lastRequest, \* NoRequest | [kind, user, db] of the most recent resolution
    lastAuth     \* NoAuth | [outcome, user] of the most recent login attempt

vars == <<registry, role, disabled, sessions, tokens, lastRequest, lastAuth>>

--------------------------------------------------------------------------------
\* Derived state
--------------------------------------------------------------------------------

Registered(u) ==
    \E un \in Usernames, db \in Dbs : <<un, u, db>> \in registry

RegisteredUsers == {u \in Users : Registered(u)}

DbOf(u) ==
    IF Registered(u)
    THEN CHOOSE db \in Dbs : \E un \in Usernames : <<un, u, db>> \in registry
    ELSE NoDb

EnabledUsers == RegisteredUsers \ disabled

\* A prefixed token has a user id in its u<id>_<random> prefix. The full token
\* byte string is hashed, so a token with a rewritten prefix is a different
\* string and finds no stored row.
Genuine(t) == t[1] \in Users

--------------------------------------------------------------------------------
\* Initial state: empty control database, no credentials, no accounts.
--------------------------------------------------------------------------------

Init ==
    /\ registry = {}
    /\ role = [u \in Users |-> NoRole]
    /\ disabled = {}
    /\ sessions = [t \in TokenSpace |-> NoUser]
    /\ tokens = [t \in TokenSpace |-> NoUser]
    /\ lastRequest = NoRequest
    /\ lastAuth = NoAuth

--------------------------------------------------------------------------------
\* Actions
--------------------------------------------------------------------------------

\* Claim the instance with the first account, or add an account from an
\* enabled admin session. The first account must be an admin. The username and
\* database path are unique across the control database.
CreateUser(newUser, username, dbPath, newRole) ==
    /\ newUser \in Users
    /\ username \in Usernames
    /\ dbPath \in Dbs
    /\ newRole \in Roles
    /\ ~Registered(newUser)
    /\ username \notin {a[1] : a \in registry}
    /\ dbPath \notin {a[3] : a \in registry}
    /\ \/ /\ RegisteredUsers = {}
          /\ newRole = "admin"
       \/ /\ RegisteredUsers # {}
          /\ \E actor \in EnabledUsers : role[actor] = "admin"
    /\ registry' = registry \cup {<<username, newUser, dbPath>>}
    /\ role' = [role EXCEPT ![newUser] = newRole]
    /\ disabled' = disabled
    /\ sessions' = sessions
    /\ tokens' = tokens
    /\ lastRequest' = NoRequest
    /\ lastAuth' = lastAuth

\* Disabling a user deletes the user's sessions and bearer tokens and leaves
\* the account in place. The last enabled admin cannot be disabled.
DisableUser(target) ==
    /\ target \in RegisteredUsers
    /\ target \notin disabled
    /\ \/ role[target] # "admin"
       \/ \E other \in EnabledUsers \ {target} : role[other] = "admin"
    /\ disabled' = disabled \cup {target}
    /\ sessions' = [t \in TokenSpace |-> IF sessions[t] = target THEN NoUser ELSE sessions[t]]
    /\ tokens' = [t \in TokenSpace |-> IF tokens[t] = target THEN NoUser ELSE tokens[t]]
    /\ lastRequest' = NoRequest
    /\ lastAuth' = NoAuth
    /\ UNCHANGED <<registry, role>>

\* A valid password login creates a session row in the user's database. The
\* token must be fresh, prefixed with the user's id, and the user must exist
\* and be enabled.
LoginValid(token) ==
    /\ token \in TokenSpace
    /\ Genuine(token)
    /\ token[1] \in EnabledUsers
    /\ sessions[token] = NoUser
    /\ sessions' = [sessions EXCEPT ![token] = token[1]]
    /\ lastAuth' = [outcome |-> "ok", user |-> token[1]]
    /\ UNCHANGED <<registry, role, disabled, tokens, lastRequest>>

\* A failed login creates no session and no bearer token. The attempt only
\* records the denial.
LoginInvalid(token) ==
    /\ token \in TokenSpace
    /\ lastAuth' = [outcome |-> "denied", user |-> NoUser]
    /\ UNCHANGED <<registry, role, disabled, sessions, tokens, lastRequest>>

\* An enabled user issues a prefixed API token or share token. The row lives
\* in the user's database, so the prefix names the database to open.
IssueToken(token) ==
    /\ token \in TokenSpace
    /\ Genuine(token)
    /\ token[1] \in EnabledUsers
    /\ tokens[token] = NoUser
    /\ tokens' = [tokens EXCEPT ![token] = token[1]]
    /\ UNCHANGED <<registry, role, disabled, sessions, lastRequest, lastAuth>>

\* Resolve a cookie session: look the full token hash up in the database named
\* by the prefix. Only a live row for an enabled user resolves.
RequestSession(token) ==
    /\ token \in TokenSpace
    /\ sessions[token] # NoUser
    /\ sessions[token] \in EnabledUsers
    /\ lastRequest' =
         [kind |-> "session", user |-> sessions[token], db |-> DbOf(sessions[token])]
    /\ UNCHANGED <<registry, role, disabled, sessions, tokens, lastAuth>>

\* Resolve a bearer API token. Same prefix routing as a session.
RequestBearer(token) ==
    /\ token \in TokenSpace
    /\ tokens[token] # NoUser
    /\ tokens[token] \in EnabledUsers
    /\ lastRequest' =
         [kind |-> "bearer", user |-> tokens[token], db |-> DbOf(tokens[token])]
    /\ UNCHANGED <<registry, role, disabled, sessions, tokens, lastAuth>>

\* Resolve a public share token. Same prefix routing as a bearer token.
RequestShare(token) ==
    /\ token \in TokenSpace
    /\ tokens[token] # NoUser
    /\ tokens[token] \in EnabledUsers
    /\ lastRequest' =
         [kind |-> "share", user |-> tokens[token], db |-> DbOf(tokens[token])]
    /\ UNCHANGED <<registry, role, disabled, sessions, tokens, lastAuth>>

\* A legacy unprefixed credential (session, token, or share) resolves only
\* while the control database has exactly one enabled user.
LegacyFallback ==
    /\ Cardinality(EnabledUsers) = 1
    /\ LET u == CHOOSE user \in EnabledUsers : TRUE
       IN lastRequest' = [kind |-> "legacy", user |-> u, db |-> DbOf(u)]
    /\ UNCHANGED <<registry, role, disabled, sessions, tokens, lastAuth>>

Next ==
    \/ \E newUser \in Users, username \in Usernames, dbPath \in Dbs, newRole \in Roles :
           CreateUser(newUser, username, dbPath, newRole)
    \/ \E target \in Users : DisableUser(target)
    \/ \E token \in TokenSpace : LoginValid(token)
    \/ \E token \in TokenSpace : LoginInvalid(token)
    \/ \E token \in TokenSpace : IssueToken(token)
    \/ \E token \in TokenSpace : RequestSession(token)
    \/ \E token \in TokenSpace : RequestBearer(token)
    \/ \E token \in TokenSpace : RequestShare(token)
    \/ LegacyFallback

Spec == Init /\ [][Next]_vars

--------------------------------------------------------------------------------
\* Invariants
--------------------------------------------------------------------------------

TypeOK ==
    /\ registry \subseteq Usernames \X Users \X Dbs
    /\ role \in [Users -> Roles \cup {NoRole}]
    /\ disabled \subseteq Users
    /\ sessions \in [TokenSpace -> Users \cup {NoUser}]
    /\ tokens \in [TokenSpace -> Users \cup {NoUser}]
    /\ lastRequest = NoRequest \/ lastRequest \in RequestRecords
    /\ lastAuth = NoAuth \/ lastAuth \in AuthRecords

\* A resolved request for user u touched db(u), and u is a real account.
NoCrossUserAccess ==
    lastRequest.kind = "none"
    \/ /\ lastRequest.user \in RegisteredUsers
       /\ lastRequest.db = DbOf(lastRequest.user)

\* A session token resolves to the account id encoded in its prefix. Because
\* the full token is hashed, a token whose prefix was rewritten matches no
\* stored row; the model represents that as a token that never enters
\* @sessions@.
SessionStableUser ==
    \A t \in TokenSpace :
        sessions[t] # NoUser =>
            /\ Genuine(t)
            /\ sessions[t] = t[1]
            /\ sessions[t] \in RegisteredUsers

\* API tokens and share tokens follow the same prefix rule as sessions.
TokenStableUser ==
    \A t \in TokenSpace :
        tokens[t] # NoUser =>
            /\ Genuine(t)
            /\ tokens[t] = t[1]
            /\ tokens[t] \in RegisteredUsers

\* A disabled user keeps no session and no bearer token.
DisabledUserNoSession ==
    /\ \A t \in TokenSpace : sessions[t] \notin disabled
    /\ \A t \in TokenSpace : tokens[t] \notin disabled

\* A legacy credential resolves only while exactly one account is enabled, and
\* it resolves to that account.
SoleUserFallbackOnly ==
    lastRequest.kind # "legacy"
    \/ /\ Cardinality(EnabledUsers) = 1
       /\ lastRequest.user \in EnabledUsers

\* Once the control database holds an account, an enabled admin exists.
AtLeastOneAdmin ==
    RegisteredUsers = {} \/ \E u \in EnabledUsers : role[u] = "admin"

\* users.username UNIQUE and users(id) primary key.
AccountKeysUnique ==
    \A a1, a2 \in registry :
        a1 # a2 => (a1[1] # a2[1] /\ a1[2] # a2[2])

\* users.db_path UNIQUE.
DbPathsUnique ==
    \A a1, a2 \in registry : a1 # a2 => a1[3] # a2[3]

\* Every account has a role, and no other id does. Account creation sets both.
RoleRegistered ==
    \A u \in Users : (role[u] # NoRole) <=> Registered(u)

\* A successful login left a session for the user it reported; a failed login
\* left no session behind.
LoginAuthConsistent ==
    lastAuth.outcome = "none"
    \/ /\ lastAuth.outcome = "denied" => lastAuth.user = NoUser
       /\ lastAuth.outcome = "ok" =>
            /\ lastAuth.user \in RegisteredUsers
            /\ \E t \in TokenSpace : sessions[t] = lastAuth.user

=============================================================================
