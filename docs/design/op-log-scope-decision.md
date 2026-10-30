# Operation-log scope: five configurations and the decisions they require

Status: open. This document records facts about jj's current model, enumerates
five configurations for how much of the operation log is replicated, and lists
the decisions that select between them. It does not recommend one.

Audience: engineers who can answer the decisions in §6. Nothing here is a
proposal for a specific implementation.

---

## 1. Scope

The subject is a **commit cloud for jj repositories**: a shared service that
stores jj repositories and serves them to several machines. Git is not part of
that architecture. It appears below only where a field of jj's own data model
refers to a Git repository, because those fields exist in every view whether or
not the repository uses them.

One parameter is undecided: **which parts of each machine's repository state are
replicated, and to whom.**

The parameter is not free. It determines the server's data model, the wire
format, the storage growth rate, what `jj undo` can mean, whether local work
survives server unavailability, and what must be migrated if the answer
changes later. §7 lists what currently depends on it.

---

## 2. Terms

| Term | Meaning |
|---|---|
| **Operation** | jj's record of one change to repository state. Contains a view id, parent operation ids, metadata, and a commit-predecessor map. |
| **View** | A complete snapshot of the repository's pointers after an operation. Content-addressed, immutable. |
| **Op head** | An operation with no successor. Loading a repository resolves all heads; more than one means divergence. |
| **Working-copy pointer** | The commit a named workspace has checked out. Stored in the view (`wc_commit_ids`). |
| **Ref target** | A bookmark's or tag's value, possibly conflicted: `Merge<Option<CommitId>>`. |

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

| # | Field | Type | Contents |
|---|---|---|---|
| 1 | `head_ids` | `HashSet<CommitId>` | All visible head commits; at least one. |
| 2 | `local_bookmarks` | `BTreeMap<RefNameBuf, RefTarget>` | Local bookmark names and targets. Targets may be conflicted. |
| 3 | `local_tags` | `BTreeMap<RefNameBuf, RefTarget>` | Local tags, same shape. |
| 4 | `remote_views` | `BTreeMap<RemoteNameBuf, RemoteView>` | Remote-tracking state: the last known bookmark and tag position of each configured remote, plus a tracked/untracked flag per ref. A remembered state, not an authority (`docs/bookmarks.md:63-67`). |
| 5 | `git_refs` | `BTreeMap<GitRefNameBuf, RefTarget>` | Interoperation cache: jj's remembered subset of the refs of an underlying Git repository, updated by import and export. Not a live mirror; some refs are excluded, e.g. `refs/notes/` (`lib/src/protos/simple_op_store.proto:105-106`). |
| 6 | `git_heads` | `BTreeMap<WorkspaceNameBuf, RefTarget>` | Interoperation state: the commit each workspace's Git `HEAD` points at. A ref target, so it may be conflicted or absent. |
| 7 | `wc_commit_ids` | `BTreeMap<WorkspaceNameBuf, CommitId>` | The commit each workspace should have checked out. The working-copy directory holds which commit is actually checked out. |

`RefTarget` is `Merge<Option<CommitId>>` (`core/src/op_store.rs:63-64`), so a
bookmark can hold several candidate commits instead of one. Types are those of
`op_store::View`; the in-memory wrapper adds one non-persisted flag
(`core/src/view.rs:44-49`).

Fields 4–6 exist for interoperation with remotes and with Git repositories. A
commit-cloud repository that never interoperates with Git leaves them empty, but
they are part of every view and therefore part of anything replicated.

### 3.4 The fields fall into three categories

This grouping is analytic; it is not in the source.

| Category | Fields | Property |
|---|---|---|
| Repository content pointers | 1–3 | Where history and named refs are. Meaningful to any machine that has the commits. `head_ids` is the visible-head set, not a named ref. |
| Interoperation state | 4–6 | What a remote or a Git repository last reported. `git_heads` belongs here rather than with working state: it merges as a ref target and `jj undo` does not restore it. Empty when no such interoperation is configured. |
| Workspace checkout pointer | 7 | The commit a named workspace should have checked out. The working-copy directory holds which commit is actually checked out. |

A snapshot transaction changes fields from more than one category: it writes a
new working-copy commit and records it in `head_ids` and `wc_commit_ids` in the
same transaction (`cli/src/cli_util.rs:2208-2243`). Where Git interoperation is
configured, the same transaction may also update the interoperation fields.
Replication cannot be decided per category without splitting a single
operation.

---

## 4. The configurations

Five configurations, ordered by how much state is replicated. For each: what is
replicated, what it makes possible, what it costs, and what it breaks.

### Option 1 — Nothing replicated

Replicated: nothing. Each machine holds a complete repository and its own
operation log; nothing is exchanged automatically.

- **Enables:** work on one machine.
- **Storage at the server:** none; there is no server role.
- **Breaks:** no visibility of unpublished work; no shared history of local
  actions; no way to reconstruct what a lost machine was doing; another
  machine's commits and refs are unknown until copied by hand.
- **Available today:** yes, as a baseline.

### Option 2 — Commits and refs replicated; operation logs local

Replicated: commit objects, file blobs, and bookmark and tag targets. Each
machine keeps its own operation log, containing its own snapshots and pointer
moves.

- **Enables:** publication with no separate synchronisation step; other machines
  see published work immediately. `jj undo` continues to operate on local
  history only.
- **Storage at the server:** proportional to published commits, not to save
  frequency. A day of editing that produces one commit costs one commit.
- **Bandwidth:** on publish, the blobs and trees not already present.
- **Breaks:** unpublished work is invisible; loss of a machine loses everything
  not yet published; no cross-machine history; an operation id from another
  machine cannot be resolved.
- **Implementation status:** commits and refs already have a transport model in
  jj; what changes is who the peer is. The work is a new transport, not a new
  model.

### Option 3 — Option 2 plus a replicated working-copy pointer per workspace

Replicated: commits, blobs, bookmark targets, and one small record per
workspace: "workspace `W` of user `U` is at commit `C`". `C` may be unpublished.

- **Enables:** other machines can see where each workspace is, including
  uncommitted work; a lost machine's checked-out commit is known to the server;
  the server has a retention root for unpublished work.
- **Storage at the server:** proportional to the rate at which workspace
  pointers move — roughly once per debounce interval while a workspace is
  actively edited, per workspace, not per file save.
- **Bandwidth:** one small record per pointer movement.
- **Exposes:** the existence, location and current commit of each workspace.
  Not file contents, unless the commits are replicated anyway.
- **Breaks:** the path by which a workspace reached its current commit is still
  not recorded; intermediate states are still unrecoverable.
- **Implementation status:** new. A replicated pointer is not an operation, so it
  needs its own record type, its own merge rule (pointer conflicts have no
  content merge), and a decision about whether the authority may ever move a
  pointer.

### Option 4 — Option 3 plus a replicated log of observable changes

Replicated: everything in option 3, plus an ordered record of changes another
machine could observe: a commit becoming reachable, a bookmark or tag target
changing, a ref deletion. Local-only changes (a pointer move with no commit
change, an intermediate amendment) produce no record.

- **Enables:** a shared, ordered history of published work; answering "what
  changed in this bookmark, and when" without asking the machine that changed
  it; recovery of published work across machines.
- **Storage at the server:** proportional to publishing activity, not to save
  activity, plus the pointer records from option 3.
- **Breaks:** a shared history of intermediate saves. An amendment that is
  overwritten before it becomes reachable is not recorded anywhere.
- **Implementation status:** new. Requires a second record format, a projection
  from local operations to records, and a durable cursor marking how far the
  projection has advanced. jj's ref merge (`core/src/refs.rs:95-118`) supplies
  the conflict semantics for the ref portion; the pointer portion inherits
  option 3's problem.

### Option 5 — The whole operation log replicated

Replicated: every operation from every machine, including every snapshot and
every pointer move. One log, resolved identically everywhere.

- **Enables:** every operation id resolves on every machine; `jj undo` can
  revert an operation performed elsewhere; any snapshot is available with its
  refs; `jj op log` is identical on all machines.
- **Storage at the server:** proportional to the aggregate rate of *saving*.
  - An operation stores a view id; the view is a separate object. Views are
    content-addressed, so identical views store once — but consecutive
    snapshots differ in `head_ids` and `wc_commit_ids`, so deduplication does
    not reduce the per-save cost.
  - Size: a view is dominated by ref names and targets. A scratch repository
    with 50 bookmarks produced an 8.8 KB view counting every field, including the
    interoperation ones;
    without those, expect a few KB. Order of magnitude 10^3–10^4 bytes per
    view, plus a few hundred bytes per operation record. Estimate from one
    measurement, not a benchmark.
  - Rate: 10,000–30,000 operations per day corresponds to one snapshot every
    1–3 seconds for 8 hours. That requires continuous activity, a tree change
    on every snapshot, one operation per save, and no debouncing or coalescing.
    It is the rate of a configured background-snapshot workflow, not of "the
    user saved a file": stock jj snapshots when a command runs, and the
    filesystem-monitor trigger coalesces events.
  - Combined: at those rates, on the order of 10^8 bytes (tens to a few hundred
    megabytes) of view data per active workspace per day, before pruning.
- **Breaks:** operation ids contain local metadata, so a replicated log is not
  deduplicated across machines for identical logical changes. Concurrent
  operations must be merged on receipt; the merge rule for working-copy pointers
  is a silent tie-break, not a content merge (§5). No local work is visible to
  other machines unless the server accepted it.
- **Implementation status:** new, and the largest. `OpStore` and `OpHeadsStore`
  are traits, so a network-backed implementation is possible; the stock `jj`
  binary registers only built-in implementations (`cli/src/cli_util.rs:4129`),
  so this requires either a custom binary or an upstream change.

### Modifiers independent of the option

- **Retention.** Any replicated history may be retained indefinitely, for a
  window, or until an explicit prune. Retention determines what "the server has
  it" means, and it is a separate decision from what is replicated.
- **Scope.** Replicated state may be visible to an organisation, a team, or named
  users. Scope affects exposure, not storage.
- **Encryption.** End-to-end encryption is incompatible with server-side
  reasoning over history (deduplication by content, conflict detection,
  retention by reference).

---

## 5. Two properties that constrain options 3–5

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
remain conflicted (`lib/src/repo.rs:2072-2078`), but it is populated only under
Git interoperation.

Consequence: any option that replicates `wc_commit_ids` replicates a value with
a timing-based tie-break and no content merge.

### 5.2 Workspace names are the only key, and there is no machine identity

Every per-workspace map is keyed by workspace name (`core/src/op_store.rs:186-193`).
A view carries no machine identifier. Two machines that both use a workspace
named, for example, `default` occupy the same map entry when their views meet;
two differently named workspaces travel as separate entries. Replicating views
without changing the key makes workspace identity repository-global.

## 6. Decisions required

Each item is a question about what must be replicated. The listed options are
the configurations from §4; the note after each answer states the technical
consequence.

**D1. Is the working-copy pointer replicated?**
No → options 1–2. Yes → options 3–5, and the tie-break in §5 becomes part of
the system's behaviour.

**D2. Is unpublished work visible to other machines?**
Its existence and location → option 3. Its contents → option 5 (or option 3
plus content replication of the tip commit). Not at all → options 1–2.

**D3. Is a history of intermediate saves required, as opposed to a history of
published changes?**
Published only → options 1–4. Every save → option 5.

**D4. Must an operation id from one machine resolve on another?**
No → options 1–4. Yes → option 5.

**D5. Must `jj undo` be able to revert an action performed on another machine?**
No → options 1–4. Yes → option 5.

**D6. What must survive the loss of a machine?**
Published work → options 2–5. Work since the last save → options 3 and 5.
Nothing beyond the working tree → option 1 also suffices.

**D7. Must local work continue while the server is unreachable?**
Yes → options 1–4, with a local queue. Any option can queue locally, but only
options 1–2 keep the server out of the local read path.

**D8. What is the acceptable server storage growth per active workspace per
day?**
Growth proportional to publishing → options 2 and 4. Growth proportional to
editing → options 3 and 5. This is the cost decision; the placeholder arithmetic
in §4 is the input.

**D9. Which fields of the view are visible to other users?**
Commits and refs only → options 1–2. Plus workspace identity and location →
options 3–5. Plus every intermediate state → option 5. Scope (§4, modifiers)
applies independently.

**D10. What is the retention rule, and who may delete replicated history?**
Independent of the option, and required before any option is implementable,
because it determines whether a replicated record is a durable fact or a
temporary one.

---

## 7. What depends on these answers

The following cannot be specified without them, because each has a different
shape per option:

- the server's data model and its conflict semantics (§5);
- the wire format and its versioning;
- the storage growth model and therefore capacity planning;
- the recovery model after machine loss;
- the privacy model, including whether workspace identity is user-visible;
- the offline behaviour of the client;
- the migration path if the answer changes later — options differ in the format
  of the data at rest, not only in code.

---

## Appendix — sources

- Operations and views are local state: `core/src/op_store.rs:282-286`.
- View fields and types: `core/src/op_store.rs:172-194`.
- `RefTarget` definition: `core/src/op_store.rs:63-64`.
- Operation structure: `core/src/op_store.rs:294-320`.
- Working-copy pointer merge rule: `lib/src/repo.rs:1650-1676`, `lib/src/repo.rs:883`,
  `lib/src/op_heads_store.rs:154`.
- Git-head merge rule (ref-target semantics): `lib/src/repo.rs:2072-2078`.
- Snapshot transaction touching heads and pointer together:
  `cli/src/cli_util.rs:2208-2243`.
- Ref target merge: `core/src/refs.rs:95-118`.
- Remote views are a remembered state: `docs/bookmarks.md:63-67`.
- Operation log and undo: `docs/operation-log.md`.
- Built-in store registration: `cli/src/cli_util.rs:4129`.
