# Operation-log scope

**This document asks for four decisions.** Each is a question about what the
commit cloud stores on a user's behalf, and each changes the answer to the
others. The cloud stores the repository; what is undecided is what else it
stores, and on what terms.

**1. Does it store where each working copy is, as well as what has been committed?**
Storing the repository makes committed work visible to other machines. Storing
each working copy's position also makes uncommitted work visible, and turns a
per-machine fact into replicated state.

**2. Does it store a history of changes, or only the current state?**
Current state answers "where is the repository now". A history answers "how did
it get here, and who moved it". A history of *every* local change additionally
answers "what did this look like before the last save", and is the only form
from which an action taken on another machine can be undone.

**3. How long is what it stores kept?**
Retention decides whether a stored record is a durable fact or a temporary one,
and therefore whether a client may rely on it.

**4. Who may see what it stores?**
Visibility is independent of storage, and decides what a user exposes by working
in the cloud rather than locally.

**The baseline.** §4.2 also describes one configuration that answers none of
these questions: no replication at all, which is what jj does today with a Git
backend. It is included as the reference point the other cells are measured
against, not as a candidate.

**Why these need answers.** Together they determine the server's data model, the
wire format, what survives the loss of a machine, whether work continues while
the server is unreachable, what `jj undo` can mean across machines, and how
storage grows. They are expensive to change later: the configurations differ in
the format of the data at rest, not only in code.

**How to read the rest.** §4 sets out the combinations these answers produce and
gives each one a name; §6.2 states what each combination implies. Questions 1–2
select a combination. Questions 3–4 apply to every combination.

**Audience.** Engineers who can answer these four. Nothing here proposes an
implementation, and no option is recommended.

---

## 2. Terms

| Term                     | Meaning                                                                                                                          |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| **Operation**            | jj's record of one change to repository state. Contains a view id, parent operation ids, metadata, and a commit-predecessor map. |
| **View**                 | A complete snapshot of the repository's pointers after an operation. Content-addressed, immutable.                               |
| **Op head**              | An operation with no successor. Loading a repository resolves all heads; more than one means divergence.                         |
| **Working-copy pointer** | The commit a named workspace has checked out. Stored in the view (`wc_commit_ids`).                                              |
| **Ref target**           | A bookmark's or tag's value, possibly conflicted: `Merge<Option<CommitId>>`.                                                     |

---

## 3. Facts about the current model

### 3.1 The operation log is local by design

> "Operations and views are not meant to be exchanged between repos or users;
> they represent local state and history."
> — `core/src/op_store.rs:282-286`

Consequences:

- No wire format for operations exists; they are written to and read from local
  storage. A replicated log is new work, not a configuration change.
- Nothing in an operation identifies a repository, a client, or a position in a
  sequence. Normal `ViewId` and `OperationId` values are content hashes, and
  `OperationId` includes local metadata (`hostname`, `workspace_name`,
  wall-clock time), so two machines produce different ids for the same logical
  change. The synthetic root operation and root view use fixed zero ids.
- `OperationMetadata.username` is unauthenticated free text, and an operation
  has no signature field. Commit objects do have an optional signature;
  operations do not.

### 3.2 An operation references a complete view, not a diff

Each operation stores `view_id` and points at a stored view object
(`core/src/op_store.rs:294-320`). "Complete" means complete heads, bookmarks,
tags, remembered remote positions and workspace pointers — not commit or tree
data. `jj op diff` computes a difference by comparing two views.

The operation object also carries `commit_predecessors`, which maps rewritten
commits to their predecessors. It is optional (absent for operations written
before jj 0.30) and records commit rewrites only, not ref or pointer changes, so
it is not a view delta.

Direct consequence: **a view cannot be partially replicated.** Replicating an
operation replicates all of its view.

### 3.3 The seven view fields

`core/src/op_store.rs:172-194`:

| # | Field             | Type                                    | Contents                                                                                                                                                                                                                                |
| - | ----------------- | --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | `head_ids`        | `HashSet<CommitId>`                     | All visible head commits; at least one.                                                                                                                                                                                                 |
| 2 | `local_bookmarks` | `BTreeMap<RefNameBuf, RefTarget>`       | Local bookmark names and targets. Targets may be conflicted.                                                                                                                                                                            |
| 3 | `local_tags`      | `BTreeMap<RefNameBuf, RefTarget>`       | Local tags, same shape.                                                                                                                                                                                                                 |
| 4 | `remote_views`    | `BTreeMap<RemoteNameBuf, RemoteView>`   | Remote-tracking state: the last known bookmark and tag position of each configured remote, plus a tracked/untracked flag per ref. A remembered state, not an authority (`docs/bookmarks.md:63-67`).                                     |
| 5 | `git_refs`        | `BTreeMap<GitRefNameBuf, RefTarget>`    | Interoperation cache: jj's remembered subset of the refs of an underlying Git repository, updated by import and export. Not a live mirror; some refs are excluded, e.g. `refs/notes/` (`lib/src/protos/simple_op_store.proto:105-106`). |
| 6 | `git_heads`       | `BTreeMap<WorkspaceNameBuf, RefTarget>` | Interoperation state: the commit each workspace's Git `HEAD` points at. A ref target, so it may be conflicted or absent.                                                                                                                |
| 7 | `wc_commit_ids`   | `BTreeMap<WorkspaceNameBuf, CommitId>`  | The commit each workspace should have checked out. The working-copy directory holds which commit is actually checked out.                                                                                                               |

`RefTarget` is `Merge<Option<CommitId>>` (`core/src/op_store.rs:63-64`), so a
bookmark can hold several candidate commits instead of one. Types are those of
`op_store::View`; the in-memory wrapper adds one non-persisted flag
(`core/src/view.rs:44-49`).

Fields 4–6 exist for interoperation with remotes and with Git repositories. A
commit-cloud repository that never interoperates with Git leaves them empty, but
they are part of every view and therefore part of anything replicated.

### 3.4 The fields fall into three categories

This grouping is analytic; it is not in the source.

| Category                    | Fields | Property                                                                                                                                                                                                                |
| --------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Repository content pointers | 1–3    | Where history and named refs are. Meaningful to any machine that has the commits. `head_ids` is the visible-head set, not a named ref.                                                                                  |
| Interoperation state        | 4–6    | What a remote or a Git repository last reported. `git_heads` belongs here rather than with working state: it merges as a ref target and `jj undo` does not restore it. Empty when no such interoperation is configured. |
| Workspace checkout pointer  | 7      | The commit a named workspace should have checked out. The working-copy directory holds which commit is actually checked out.                                                                                            |

A snapshot transaction changes fields from more than one category: it writes a
new working-copy commit and records it in `head_ids` and `wc_commit_ids` in the
same transaction (`cli/src/cli_util.rs:2208-2243`). Where Git interoperation is
configured, the same transaction may also update the interoperation fields.
Replication cannot be decided per category without splitting a single
operation.

---

## 4. The configuration space

### 4.1 Two axes

**Breadth — whether working-copy positions are stored as well.**

| | |
|---|---|
| nothing | no server role; every machine holds a complete repository |
| content and refs | commit objects, file blobs, bookmark and tag targets |
| content, refs and positions | the above, plus one record per workspace saying which commit it has checked out |

**Depth — whether a history is stored, and of what.**

| | |
|---|---|
| current state only | the latest value of each thing, and nothing about how it got there |
| observable history | an ordered record of changes another machine could see: a commit becoming reachable, a ref target changing, a ref removed |
| all history | an ordered record of every local change, including pointer moves and intermediate amendments |

The axes are not fully independent. **All history requires positions**, because a
record of pointer moves is itself a replication of pointer state. **Observable
history does not**, because a pointer move is not observable.

A third dimension exists but is not an axis: the **representation** of a history,
as compact records or as full operation objects each carrying a complete view. A
full-operation representation always carries positions, so it is a variant of a
cell rather than an independent choice.

### 4.2 The grid

| | current state only | observable history | all history |
|---|---|---|---|
| **content, refs, positions** | **C** | **E** | **F** |
| **content and refs** | **B** | **D** | — inconsistent |
| **nothing** | **A** | — | — |

Partial order: A < B < C < E < F, and B < D < E.

**F is not C plus D.** E is C plus D. F adds the one thing neither contains:
unobservable history — pointer moves and intermediate amendments — which is the
only source of cross-machine undo.

### 4.3 The cells

**A — nothing replicated. Baseline, not a candidate.**
Replicated: nothing. Each machine holds a complete repository and its own
operation log; sharing happens by explicit transfer — today, through a Git
remote. This is what jj does with a Git backend, and it is here as the reference
point the other cells are measured against.
- Enables: work on one machine.
- Cost: none; there is no server role.
- Breaks: no visibility of unpublished work; no shared history; a lost machine
  cannot be reconstructed; another machine's commits and refs are unknown until
  copied by hand.

**B — content and refs, current state.**
Replicated: commit objects, blobs, bookmark and tag targets. Each machine keeps
its own operation log with its own snapshots and pointer moves.
- Enables: publication with no separate synchronisation step; other machines see
  published work immediately. `jj undo` remains local.
- Cost: proportional to published commits, not to save frequency.
- Breaks: unpublished work is invisible; loss of a machine loses it; no
  cross-machine history; an operation id from another machine cannot be
  resolved.
- Status: commits and refs already have a transport model in jj; the work is a
  new transport and a new peer, not a new model.

**C — content, refs and positions, current state.**
Replicated: B, plus one record per workspace — "workspace `W` of user `U` is at
commit `X`", where `X` may be unpublished.
- Enables: other machines see where each workspace is, including uncommitted
  work; the server can retain unpublished work as a garbage-collection root; a
  lost machine's checked-out commit is known.
- Cost: proportional to pointer movements — roughly once per debounce interval
  while a workspace is edited, per workspace, not per file save.
- Breaks: no record of how a workspace reached its position; intermediate states
  remain unrecoverable.
- Status: new. Needs a record type, a two-way merge rule for positions (§5.1),
  and a decision on whether the authority may move one.

**D — content and refs, observable history.**
Replicated: B, plus an ordered record of observable change.
- Enables: a shared, ordered history of published work; "what changed in this
  bookmark, and when" answerable without the machine that changed it; recovery
  of published work across machines.
- Cost: proportional to publishing activity, plus a second format and a durable
  cursor.
- Breaks: a shared history of intermediate saves. An amendment overwritten
  before it becomes reachable is recorded nowhere.
- Status: new. Requires a record format, a projection from local operations, and
  a cursor marking how far the projection has advanced.

**E — content, refs and positions, observable history.**
C plus D. Costs are additive, and the two-way merge of §5.1 applies to every
replicated position.

**F — all history.**
Replicated: every operation from every machine, each with a complete view.
- Enables: every operation id resolves everywhere; `jj undo` can revert an
  operation performed elsewhere; any snapshot is available with its refs;
  `jj op log` is identical on all machines.
- Cost: proportional to the aggregate rate of *saving*.
  - An operation stores a view id; the view is a separate object. Views are
    content-addressed, so identical views store once — but consecutive snapshots
    differ in `head_ids` and `wc_commit_ids`, so deduplication does not reduce
    the per-save cost.
  - Size: a view is dominated by ref names and targets. A scratch repository
    with 50 bookmarks produced an 8.8 KB view counting every field, including
    the interoperation ones; without those, expect a few KB. Order of magnitude
    10^3–10^4 bytes per view, plus a few hundred bytes per operation record.
    Estimate from one measurement, not a benchmark.
  - Rate: 10,000–30,000 operations per day corresponds to one snapshot every
    1–3 seconds for 8 hours. That requires continuous activity, a tree change on
    every snapshot, one operation per save, and no debouncing or coalescing. It
    is the rate of a configured background-snapshot workflow, not of "the user
    saved a file": stock jj snapshots when a command runs, and its
    filesystem-monitor trigger coalesces events.
  - Combined: at those rates, on the order of 10^8 bytes (tens to a few hundred
    megabytes) of view data per active workspace per day, before pruning.
- Breaks: operation ids contain local metadata, so identical logical changes are
  not deduplicated across machines; concurrent operations must be merged on
  receipt, and that merge is the two-way merge of positions required by §5.1 —
  not jj's end-time tie-break. The consequence is disproportionate: with every
  operation replicated, divergent heads stop being an exception, so every load
  reconciles views and the merge runs on the path every command takes. jj's
  merge path moves from recovery to the hot path. No local work is visible to
  others until the server has accepted it.
- Status: the largest, and larger than the transport suggests. `OpStore` and
  `OpHeadsStore` are traits, so a network-backed implementation is possible, and
  the stock `jj` binary registers only built-in implementations
  (`cli/src/cli_util.rs:4129`), so this requires either a custom binary or an
  upstream change. Separately, §5.1's two-way merge cannot be performed on the
  current representation: `wc_commit_ids` maps each workspace to a single commit
  and has no way to hold two candidates, so the persisted view and its merge
  code both change.

### 4.4 Modifiers independent of the cell

- **Retention.** Any replicated history may be kept indefinitely, for a window,
  or until an explicit prune. Retention determines what "the server has it"
  means.
- **Scope.** Replicated state may be visible to an organisation, a team, or named
  users. Scope affects exposure, not storage.

## 5. Two properties that constrain cells C, E and F

### 5.1 Working-copy pointers have a tie-break, not a merge

When two views disagree about a `wc_commit_ids` entry, `merge_wc_commit` keeps
`self_id` unless one side is absent or a trivial merge applies
(`lib/src/repo.rs:1650-1676`). "Self" is the view being merged into: the local
view during a transaction, and during automatic reconciliation the earliest head
by end time, after which the remaining heads are merged in order
(`lib/src/repo.rs:883`, `lib/src/op_heads_store.rs:154`). No conflict object is
created and no user is asked. The winner is determined by operation end times,
not by which machine is local.

`git_heads`, the other per-workspace field, merges as a ref target and can
remain conflicted (`lib/src/repo.rs:2102-2108`), but it is populated only under
Git interoperation.

Consequence: cells C, E and F cannot inherit that rule. A replicated workspace
position needs a representation that can hold both sides of a disagreement, and
an explicit two-way merge over them — the shape jj already uses for a conflicted
bookmark, rather than the end-time tie-break `merge_wc_commit` applies. A
timing-based resolution is defensible for one machine reconciling its own
operations; it is not defensible as the cloud's merge rule, because the loser is
chosen by clock skew rather than by anything a person can inspect.

### 5.2 Workspace names are the only key, and there is no machine identity

Every per-workspace map is keyed by workspace name (`core/src/op_store.rs:186-193`).
A view carries no machine identifier. Two machines that both use a workspace
named, for example, `default` occupy the same map entry when their views meet;
two differently named workspaces travel as separate entries.

**Required constraint:** machine identity must form part of the workspace name,
for example `<machine>/<workspace>`, so that uniqueness is a property of the
name rather than an assumption about how the system is deployed. jj provides no
machine identifier to fall back on, so one is generated per node and embedded in
the names that node creates.

The costs are explicit: machine identity becomes visible in a user-facing
identifier, and renaming or replacing a machine renames its workspaces, leaving
the old entries behind. The alternative is worse — a silent collision in which
two machines' workspaces share one map entry and one of them is discarded by
§5.1's tie-break.

## 6. Decisions required

### 6.1 The two choices that place a configuration in the grid

**Choice 1 — breadth.** Are working-copy positions stored, or only the
repository? Content and refs → **B** or **D**. Content, refs and positions →
**C**, **E** or **F**, and the two-way merge of §5.1 becomes part of the
system's behaviour.

**Choice 2 — depth.** Current state only → **B** or **C**. Observable history →
**D** or **E**. All history → **F**.

**A** is not reachable through these choices: it is the no-server baseline.

### 6.2 What each cell implies

| Cell | Operation id resolves elsewhere | Undo another machine's action | Survives loss of a machine | Works while the server is unreachable | Storage grows with | Unpublished work visible |
|---|---|---|---|---|---|---|
| **A** | no | no | nothing | yes | nothing | no |
| **B** | no | no | published work | yes | publishing | no |
| **C** | no | no | work since the last save | yes | publishing + pointer movement | position only |
| **D** | no | no | published work | yes | publishing | no |
| **E** | no | no | work since the last save | yes | publishing + pointer movement | position only |
| **F** | yes | yes | work since the last save | no | saving | content and position |

"Operation id resolves elsewhere" is a consequence of depth, not of breadth: an
id identifies an operation, and only a repository of operations can answer for
it. That is why only F satisfies it.

### 6.3 Decisions independent of the cell

**I1. Retention.** How long replicated state is kept, and who may delete it.
Required for every cell above A, because it decides whether a replicated record
is a durable fact or a temporary one.

**I2. Scope.** Who may see replicated state. Independent of storage; can be
answered per deployment.

## 7. What depends on these answers

The following cannot be specified without them, because each has a different
shape per cell:

- the server's data model and its conflict semantics (§5);
- the wire format and its versioning;
- whether a **second, replicated log** is introduced alongside jj's own: cells C,
  D and E carry information that jj keeps no cross-machine record of — a
  workspace position, or an ordered history of observable change — so they need
  a new record type with its own format, identity, ordering and reconciliation
  rules, maintained next to the local operation log rather than derived from a
  replicated one. Cell F avoids the new type by replicating jj's operations
  themselves, and pays for it as described in §4.3;
- the storage growth model and therefore capacity planning;
- the recovery model after machine loss;
- the privacy model, including whether workspace identity is user-visible;
- the identity and authentication model for records and clients, which jj does
  not provide and which no cell can borrow;
- the offline behaviour of the client;
- the migration path if the answer changes later — cells differ in the format of
  the data at rest, not only in code.

---

## Appendix — sources

- Operations and views are local state: `core/src/op_store.rs:282-286`.
- View fields and types: `core/src/op_store.rs:172-194`.
- `RefTarget` definition: `core/src/op_store.rs:63-64`.
- Operation structure: `core/src/op_store.rs:294-320`.
- Working-copy pointer merge rule: `lib/src/repo.rs:1650-1676`, `lib/src/repo.rs:883`,
  `lib/src/op_heads_store.rs:154`.
- Git-head merge rule (ref-target semantics): `lib/src/repo.rs:2102-2108`.
- Snapshot transaction touching heads and pointer together:
  `cli/src/cli_util.rs:2208-2243`.
- Ref target merge: `core/src/refs.rs:95-118`.
- Remote views are a remembered state: `docs/bookmarks.md:63-67`.
- Operation log and undo: `docs/operation-log.md`.
- Built-in store registration: `cli/src/cli_util.rs:4129`.
