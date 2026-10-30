# A shared log of observable change

Status: **proposal for discussion.** Nothing here is ratified, and it is not a
requirement. It is one answer to a question the requirement baseline leaves
open (`OQ-10`, `OQ-13`), written down so it can be argued with.

**Reading guide.** If you have five minutes, read the bottom line and §4 (what
a record contains). If you are deciding, read §7–§9 (pros, cons, cost). §10 says
how this changes the requirements, §11 lists what is still undecided.

---

## 1. Bottom line

Keep jj's operation log **exactly as jj intends it: local, and never
transmitted.** Add a second, commit-cloud-specific log — a log of _observable
change_ — and propagate only that. The second log is derived from the first, so
it cannot disagree with it, and jj is not modified at all.

This costs a second format, a durable cursor, a rule for materialising received
change back into local operations, and a decision about whether workspace tips
are shared. It buys the property the whole design has been circling: **nothing
has to be filtered out of jj's log, because nothing unobservable ever enters the
shared one.**

---

## 2. The problem it answers

Three requirements currently pull against each other:

- **RQ-5-3** — every snapshot's content reaches the authority.
- **RQ-5-4** — the upstream log carries only what another client can observe; pointer moves and intermediate amendments should stay local.
- **RQ-8-1** — a client is entitled to learn of observable change without remounting.

Satisfying all three with _one_ log means either publishing everything (and
paying for pointer churn) or filtering an operation that mixes shared and local
effects. jj makes both awkward for a structural reason: **an operation carries a
complete view, so its shared half cannot be separated from its local half**
(`docs/operation-log.md:5-13`).

Two logs avoid the problem entirely, because the shared log is a different kind
of object rather than a filtered copy of the local one.

---

## 3. Terms

- **Operation** — jj's record of a repository state: a view plus parents,
  metadata and a predecessor map (`core/src/op_store.rs:294-320`). Local.
- **View** — a full snapshot of the repository's pointers, not a delta
  (`core/src/op_store.rs:172-194`).
- **Observable** — a change another client could see: a commit becoming
  reachable, a bookmark or tag moving, a removal. Everything else is local.
- **Record** — one entry in the shared log: the commits it introduces, the ref
  changes it makes, and its causal parents. Defined in §4.
- **Projection** — turning a local operation into zero or more records.
- **Materialisation** — turning a received record into a local operation, so
  that `jj log`, `jj status` and `jj undo` see the change.
- **Cursor** — the id of the last local operation already projected. The only
  new durable state the node needs.

---

## 4. What a record contains

A record cannot be a view, because most of a view is local. Here is the whole
inventory (`core/src/op_store.rs:172-194`), with the judgement that matters:

| View field              | What it holds               | Observable by another client?                                                  |
| ----------------------- | --------------------------- | ------------------------------------------------------------------------------ |
| `head_ids`              | the visible head commits    | **Partly.** Names shared commits; the _set_ is this machine's visibility rule. |
| `local_bookmarks`       | bookmark name → `RefTarget` | **No.** Local intent; others see it only after propagation or Git export.      |
| `local_tags`            | tag name → `RefTarget`      | **No.** Same.                                                                  |
| `remote_views`          | last-seen remote positions  | **No.** Explicitly a cache (`docs/bookmarks.md:63-67`).                        |
| `git_refs`, `git_heads` | mirrors of Git refs         | **No.** Local mirrors.                                                         |
| `wc_commit_ids`         | workspace → commit          | **No.** Local workspace state.                                                 |

So the only genuinely shared things in a view are **the commits** and **the
bookmark and tag targets**. That is the whole content of the shared log.

A record, minimally:

```
Record {
  id          content hash of the rest of this record
  parents     other record ids (causal order, usually one)
  author      node id, user id             // who, for accountability
  time        wall clock                   // advisory only; never an ordering key
  commits     commit ids introduced        // their blobs must be present first
  refs        [ { name, from: RefTarget, to: RefTarget } ]
  tips        [ { workspace, commit } ]    // optional; see OQ-2 below
  removes     [ object ids ]               // soft and hard removals, see RQ-7-4
}
```

`RefTarget` is `Merge<Option<CommitId>>` (`core/src/op_store.rs:63-64`), so a
record can express a _conflicted_ bookmark, not only a winner. `from` is
carried so that two concurrent records touching the same ref can be merged
against a known base.

**What a record deliberately does not carry:** hostname, workspace name,
command-line arguments, `is_snapshot`, or the predecessor map. All of those are
local, and two of them are private (`attributes["args"]` holds the full command
line, `cli/src/cli_util.rs:3072-3114`).

---

## 5. The two flows

### 5.1 Outbound: local operation → records

```
jj op log (local, untouched)
  op 41  snapshot        ──┐
  op 42  snapshot        ──┤  projection
  op 43  move @          ──┘  (compare consecutive views)
                             │
                             ▼
                   only shared fields changed?
                       no ──► advance cursor, write nothing
                       yes ─► Record ──► upstream
```

For each operation after the cursor, the projector compares its view with the
previous one and asks: did any commit become reachable, did any bookmark or tag
target change, was anything removed? If the answer is no — a pointer move, an
intermediate amendment that changed nothing shared — **no record is written and
the cursor advances**. That is why RQ-5-4 stops being a policy: an unobservable
operation produces no record because there is nothing to put in one.

Ordering is preserved by `parents`: a node's records form a chain in the order
its operations happened.

### 5.2 Inbound: record → local operation

```
Record ──► validate (commits and blobs present, RQ-5-7)
       ──► apply as an ordinary local operation
             (set ref targets, add heads)
       ──► never projected back out  ← echo suppression
```

The result is a normal jj operation on the receiving node. That is what makes
`jj log` show a colleague's commits and `jj undo` behave sanely.

**Echo suppression is the one subtle part.** An applied record produces a local
operation, and the projector scans local operations. Without a rule, every
received change would be re-projected and sent back. The rule can be a flag in
the operation's `attributes` (already an extensible field,
`core/src/op_store.rs:355-373`), or the cursor can advance over applied records
explicitly. Either works; it must be decided and tested, because the failure is
an infinite loop between two nodes.

### 5.3 Edge cases

| Case                                                                 | Behaviour                                                                                                                                                                   |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crash after writing a record, before advancing the cursor            | The record is re-projected on restart. Records are idempotent by content hash.                                                                                              |
| Crash after applying a record, before its local operation is durable | The record is re-applied; applying is "set to these targets", not "advance", so it converges.                                                                               |
| Two nodes change the same bookmark concurrently                      | Two records, same causal parent, different targets. Applying both yields a conflicted bookmark — jj's `merge_ref_targets` over the common base (`core/src/refs.rs:95-118`). |
| A record arrives before the commits it names                         | Rejected as retryable; records may not be announced before their content (RQ-5-7).                                                                                          |
| A node is offline for a week                                         | Its records queue with the cursor; on reconnect it pushes them and pulls the rest. Nothing is dropped (RQ-5-3).                                                             |
| The authority prunes a record                                        | Nodes learn of it and drop it (RQ-5-5). Records already applied stay applied locally.                                                                                       |

---

## 6. Why merging is easier here than in jj

Two divergent operation heads force jj to merge **views**, including workspace
pointers, and that merge picks a side silently for pointers
(`lib/src/repo.rs:1670-1672`). Two divergent _records_ touch only refs and
commits, and ref merging is already a first-class, ancestry-aware operation that
can represent disagreement instead of discarding it.

So the shared log needs no merge record at all: its state is the fold of its
records, and concurrent ref updates fold into a conflicted bookmark. The one
thing to be careful about is that jj's ref merge **can** drop a side when one
target is an ancestor of the other (`core/src/refs.rs:140-175`). That is correct
for "where does this bookmark point" and wrong for "who tried to move it". If
the design needs the latter, records must carry the attempts, not just the
resulting target.

---

## 7. Pros

1. **No change to jj.** Operations stay local, which is what jj documents
   (`core/src/op_store.rs:282-286`). Nothing has to be redefined, re-parented or
   minted, and no upstream review has to accept a new meaning for a view.
2. **RQ-5-4 becomes structural.** Nothing unobservable can be propagated,
   because the format has nowhere to put it. No filter, no policy list, no
   drift.
3. **The receive path already exists.** `jj op integrate` is
   `update_op_heads(op.parent_ids(), op.id())` plus `resolve_op_heads`
   (`cli/src/commands/operation/integrate.rs:51-56`), and the op-heads update
   tolerates parents it does not have. Adoption, divergence and merging are
   built.
4. **No missing-ancestor problem.** Records parent on records, not on
   operations, so a shared record never descends from a local-only one.
5. **The record stream is also the change feed.** RQ-8-1's entitlement, pruning
   announcements (RQ-5-5) and removal lists (RQ-7-4) all travel as the same kind
   of object, so `OQ-12`/`OQ-15` become questions about _how to consume_ it
   rather than what it contains.
6. **It fits every topology under discussion.** Whether the log lives at the
   node or at the VFS, the records are the same; §11's open question about
   where the log lives does not change the format.
7. **Rebuildable.** The shared log is a projection of the local one. Lose it,
   rebuild it from the cursor.

## 8. Cons and risks

1. **Two formats, two versions, two test suites.** The record format needs its
   own encoding, id scheme and version tag, and its own compatibility rules.
2. **A new durable cursor, and it is load-bearing.** If it advances before the
   record is durable, change is lost; if it never advances, records duplicate
   (harmless) and the log grows. At-least-once plus idempotence is the only safe
   design, and it has to be tested with crashes in the middle.
3. **Echo suppression is a correctness hazard.** A mistake is an infinite
   propagation loop between two nodes.
4. **Received change costs local operations.** Each inbound record materialises
   as an operation on the receiving node, so `jj op log` grows on read too. That
   is the price of `jj undo` working.
5. **Metadata privacy is the design's job.** jj's `username` is an unauthenticated
   claim and `attributes["args"]` holds command lines and paths. The projector
   must whitelist fields rather than blacklist them.
6. **jj's ref merge is lossy by design.** "Who moved this bookmark" is not
   recoverable from final state. If audit is required, records must carry
   attempts.
7. **Intermediate snapshots are still a decision.** A record per snapshot makes
   every save visible at the authority and gives garbage collection a root for
   offline work — at the cost of a shared log that grows at the snapshot rate.
   A record per batch is cheaper but leaves intermediate snapshots unnamed and
   therefore collectable.
8. **It does not provide cross-machine undo**, nor a shared history of
   intermediate states, unless records are that fine-grained.
9. **Submodules are outside the model.** No view field covers them
   (`core/src/op_store.rs:172-194`); submodule ids live inside trees. Covering
   them needs a format extension.

---

## 9. What implementing it entails

**New state at each node**

- the projection cursor (last projected local operation id);
- the record store (records by id, plus the causal graph);
- the inbound-applied marker, or the equivalent echo-suppression flag.

**New code**

1. **Record format** — encoding, content-addressed id, version tag, and a
   canonical serialisation so two nodes computing the same record get the same
   id.
2. **Projector** — diff two consecutive views, extract commit and ref deltas,
   skip empty ones, write a record, advance the cursor. Must be idempotent.
3. **Applier** — validate, materialise as a local transaction, mark as applied.
4. **Ref merge over records** — fold concurrent ref updates into `RefTarget`,
   with the last common record as base.
5. **Transport** — push records, pull records since a point, and (optionally)
   subscribe. Same service, three shapes.
6. **Removal propagation** — soft and hard removal lists ride in records
   (RQ-7-4), which also needs the hard-removal deny-list on the receive side.

**What it does not need**

- Any change to `OpStore`, `OpHeadsStore`, `Backend` or `View`.
- Any second `jj` binary.
- Any minting, re-parenting or filtering of operations.

**Testing that would actually pin the behaviour**

- Project a pointer-only operation and assert **zero** records.
- Kill the process between writing a record and advancing the cursor; assert
  exactly one effective record after restart.
- Apply the same record twice; assert one effective local operation.
- Two nodes move one bookmark concurrently; assert a conflicted bookmark, not a
  winner, and assert both nodes converge.
- Two nodes project each other's applied records; assert the loop terminates and
  the logs stop growing.
- Records arriving before their commits are refused and retried, not applied.

**Rough order for a spike**, cheapest-falsifying first: format and projector in
one process → two-process push/pull → concurrent ref merge → applier and echo
suppression → removals. If the first two steps do not produce a clean round trip,
the idea is wrong and nothing later matters.

---

## 10. What this does to the requirements

| Requirement                                                     | Effect                                                                                                                 |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **RQ-5-1** concurrent appends accepted, log forks and merges    | Applies to records: they fork and refold. Simpler, because refs merge without touching workspace pointers.             |
| **RQ-5-2** merge rate kept low                                  | Unchanged in intent; now measured on records rather than operations.                                                   |
| **RQ-5-3** every snapshot's content reaches the authority       | Satisfied by records naming commits. Whether every _snapshot_ is named depends on decision (7) above.                  |
| **RQ-5-4** upstream log carries only observable change          | **Becomes structural** — nothing to enforce.                                                                           |
| **RQ-5-5** pruning is the authority's decision and is announced | Records carry the announcement.                                                                                        |
| **RQ-7-4** soft and hard removal                                | Records carry the lists; hard removal also needs the receive-side deny-list.                                           |
| **RQ-8-1** entitled to learn of observable change               | The record stream _is_ the feed. `OQ-12` and `OQ-15` become questions about consumption.                               |
| **OQ-10** does the operation log belong in the cloud?           | Answered in a third way: **jj's log never leaves the machine; a different log is shared.** Worth recording in `OQ-10`. |
| **OQ-13** should the upstream log carry only observable change? | Dissolved.                                                                                                             |

---

## 11. Open questions this raises

- **OQ-A. Does a record name workspace tips?** If yes, the authority knows where
  every workspace is: garbage collection gets a root for offline work, and other
  clients can see work in progress. If no, intermediate snapshots are unnamed
  and collectable, and offline work is invisible until it is published.
- **OQ-B. One record per snapshot, or per propagation batch?** Snapshot-rate
  records give the strongest promise and the largest log.
- **OQ-C. Where does the shared log live** — at the commit-cloud node, or in the
  VFS daemon? This is the same topology question already open; the record format
  does not change with the answer, but ownership and authentication do.
- **OQ-D. Does the shared log need an audit trail of ref attempts**, given that
  jj's ref merge discards one side when one target is an ancestor of the other?
- **OQ-E. What is a node's identity in a record?** jj has no repository id, no
  client id and no sequence number (`ViewId` and `OperationId` are content
  hashes that include local state, so they are not shared identities).

---

## 12. What would falsify this

- A round trip — project, push, apply, re-project — that cannot be made
  echo-free without tagging operations in a way the node cannot distinguish from
  local work.
- Concurrent ref updates that fail to converge under jj's own ref merge when
  applied through records, in a test with three or more nodes.
- A requirement, discovered later, that shared history must include local-only
  operations — which this design cannot carry at all.
