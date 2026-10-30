# Commit cloud — requirements

**Purpose.** This is the requirement baseline for the multi-tier commit cloud. It records what the operator asked for, in the operator's terms, so that it can be read and corrected independently of any design. Any design of this system must satisfy it; where a design and this document disagree, the document wins until the operator changes it.

**Status.** No design decision is ratified. This document is not a decision record: it is the set of requirements the decisions have to serve. A requirement marked **(derived)** was not stated word for word; it follows from something that was, and is flagged so it can be struck.

**How to correct it.** Strike a requirement, rewrite it, or add one. Each is numbered so it can be cited as `RQ-n` in review or in the design.

---

## 1. The idea, in plain terms

A developer works in a jj repo whose history and contents live on a server. Instead of reaching the server for every metadata lookup, the machine runs its own small commit-cloud **node**. The node holds the repo's metadata and a working set of its bytes, so `stat`, `ls` and `log` are answered locally, and only genuinely missing content costs a network trip.

A node is either the repo's **owner** — the authority, the only durable copy — or a **copy** — a replica, with exactly one upstream, which may be emptied at any time and is never a backup. Copies are stacked: laptop, colo, forge. Each talks only to its own neighbour, and the authority is the only place truth is decided.

The mount is not a read-only window. It is the working copy: files are edited there, the node snapshots them seconds later, and those snapshots flow upward in the background while the developer keeps working — on a train, behind a VPN, or with the network off entirely.

Other people's work flows the other way: up to the authority, then back down to everyone, so a client sees new commits and bookmarks without being remounted.

---

## 2. Goals

- **RQ-1** The system is a commit cloud for jj repositories: it stores history metadata and file contents, and serves them to a CLI and to one or more FUSE mounts.
- **RQ-2** Metadata reads are served from the local node and are near-instant. A `stat`, a directory listing or a history view must not depend on a network round trip.
- **RQ-3** File contents are served locally when the node has them. When it does not, the read blocks for a bounded time and then returns a retryable error; it never returns a partial or torn file.
- **RQ-4** Work continues while disconnected, **including writes**. Offline work is reconciled later without loss and without silent rewriting.
- **RQ-5** The same design works at any depth, with the same binary. Depth is a property of who points at whom, not a separate architecture: a node's tier is derived, being 0 for the authority and one more than its upstream otherwise.

## 3. Roles and topology

- **RQ-6** Exactly two roles: **authority** and **replica**. No third role, no "edge" role.
- **RQ-7** Roles are bound per (node, repository), not per node. One node may be authority for repo A and replica for repo B.
- **RQ-8** The authority is the repo's durable owner and the only place truth is decided: immutability, bookmark policy, op-head compare-and-swap, merge, repo identity, garbage collection. It **may have no upstream at all**; that is a first-class, fully supported configuration (local-first development with no cloud).
- **RQ-9** A replica has exactly one upstream for that repo, is **not durable**, may be emptied wholesale at any time, and is never a backup.
- **RQ-10** Topology for v1 is a tree: one upstream per (node, repo). Multi-upstream and fan-in are deferred, but must not be structurally foreclosed.
- **RQ-11** One node serves N repositories and M mounts. Multi-user machines are supported with per-user isolation.
- **RQ-12** Workspaces are **unique by construction**, and a workspace is a pointer in the view, not a lock.
  - *Unique.* A workspace is named for the node that owns it, so two nodes cannot name the same workspace. Copying a workspace to another node creates a **new** workspace at a commit, not a second writer of the same one. A node's identity is generated once, is stable across restarts, and must not be copied with its data; a duplicate identity is a configuration error that the node should refuse rather than half-support.
  - *Pointer.* The view maps a workspace name to a working-copy commit. There is no lease, fence or ownership anywhere in the repository, and none is added. A node admits one writer per workspace at a time; that admission is in-process and is the only lock in the system.
  - *Why the rule exists.* If two nodes did share a name, `merge_wc_commit` would keep one side silently — the operation that finished first — and the other client's working copy would be reported stale. Nothing would be lost: the losing commit stays in the graph. The failure is merely confusing, so it is designed out rather than handled.
- **RQ-13** Repository identity is human-chosen and authority-scoped, in the shape a forge uses: `<authority>/<owner>/<name>`. The creator picks it when the repository is registered, and the authority enforces uniqueness within itself. Transport is **not** part of identity: the same repository reached over a Unix socket and over HTTPS is one repository, while a different authority is a different repository. Renaming is out of scope for the MVP. *(This replaces the opaque, server-assigned id: today the client may pass `repo_id` and the server otherwise assigns one, `lib/src/cc_backend.rs:55-64`.)*

## 4. Reads

- **RQ-14** The view a client reads is the client's **own commit**, and it moves only when the client moves it. Another client's work may advance the repository's heads and bookmarks, but it never moves this client's working-copy pointer or the tree its reads resolve to. Two clients editing the same commit therefore produce two commits with the same parent — a fork, which the operation model expects. A read sequence is pinned to the commit it began on, so a directory listing and the reads that follow it cannot tear. Advancing is therefore a decision, not a background event: when the client does advance, the switch is atomic, handles already open keep the commit they opened, and only the operation that asked to advance waits.
- **RQ-15** The only way a state a client is reading becomes unavailable is **collection**: its commit or its blobs are no longer retained. That fails with an explicit "collected" error and the client chooses a newer commit. Nothing ever half-applies, and no server-side event moves the view.
- **RQ-16** Metadata is served by the local node from what it holds: the operation log, the heads, commit headers, tree manifests and the attributes the VFS needs. A metadata read never depends on a network round trip. *(**Open (OQ-10):** whether the operation log belongs in the commit cloud at all. With a git backend it never leaves the machine; the rest of these requirements assume it is shared.)*
- **RQ-17** Blobs are fetched lazily. A read of a blob that is not local blocks up to a timeout and then returns a retryable error.
- **RQ-18** `stat` never lies. Size, mode and mtime come from metadata, never from fetching content.
- **RQ-19** Attributes are deterministic: given one operation, size, mtime, executable bit and directory ordering always have the same values. *(Agreed as stated. Deferred: which timestamp an mtime carries — content time, commit time or checkout time — is a policy choice, not part of this requirement.)*
- **RQ-20** Prefetching is optional and deferred. If a node implements it, it may warm its cache with content it used before, but it must never fetch every blob of an operation on a large repository.
- **RQ-21** A blob with an **open reader** is never evicted by the local node. This is a local rule, not a protocol concept: there are no pins, no pin TTLs and no pin stream. *(Evicting a blob from under an active read is not corrupting, but it forces a refetch and is impossible offline; keeping open blobs resident is simpler than a pin protocol, and it removes a whole class of expiry and cap rules.)*

## 5. Writes, acknowledgements and durability

- **RQ-22** A node serializes operation creation per repository: at most one local client is creating and appending an operation at a time. Two clients on the same node must never race to append, because the loser has to rebuild its operation against a new parent and therefore produces a new operation id.
- **RQ-23** Every hop's log is append-only: once a node has accepted an operation it is never rewritten, re-identified or reordered. Divergence is resolved by appending a merge operation or by parking — never by editing history.
- **RQ-24** **Every snapshot reaches the authority; the node chooses when, never which.** Local history is the window between a snapshot and its publication — durable on the node, not yet replicated. The window is bounded (placeholder: five minutes) and the bound applies only while the node can reach its upstream; an explicit publish request shortens it, and going offline suspends it while the queue keeps its order. Publishing may put many operations into one transport message, but each operation is still applied and acknowledged individually and the published prefix preserves their order. Nothing in the window may be dropped, coalesced away or superseded: an intermediate snapshot is not a draft to be improved on. *(This is what makes a snapshot a promise rather than a best effort. The cost is that the shared log grows at the aggregate snapshot rate — so retention, not upload policy, is what keeps it bounded.)*
- **RQ-25** The operation model is multi-writer and content-addressed: simultaneous lineages converge by DAG merge, never by last-write-wins. Forks are expected to be rare because exactly one workspace has a writer.
- **RQ-26** An operation is never announced before every blob it references is retrievable at the announcing node. No dangling references, at any tier.
- **RQ-27** Every write acknowledgement reports the durability level actually achieved and the work still pending. The levels are `local`, `upstream` and `authority`; `upstream` is only meaningful at tier 1, and an acknowledgement that has not reached the authority is marked **provisional**.
- **RQ-28** `fsync` returns once the data is locally durable at the node plus a bounded push attempt. It does not wait for the authority.
- **RQ-29** The commit cloud must not debounce or delay acknowledgements. Bursts are accepted; coalescing may happen only after the acknowledgement.
- **RQ-30** Immutability is enforced by the authority, inside the compare-and-swap that advances the heads. A replica never enforces it; a violation is parked, not applied.
- **RQ-31** Bookmark divergence follows a per-bookmark policy: fast-forward-only (default, parking on conflict), authority-wins, or manual. Nothing is silently discarded.
- **RQ-32** An operation that a node will not apply, but must not lose, is **parked**: stored, surfaced to the user, and left unpublished until someone re-applies or discards it. Parking is the third outcome between applying and rejecting, and it exists because the decision is a human one — divergent bookmark moves under a fast-forward-only policy, an immutable bookmark, or a `manual` policy. A workspace pointer that moved is **not** a parking case: nothing is lost, and the losing client reconciles its working copy instead. It is never used for transient failures (missing blobs, a lost compare-and-swap, a collected base), which are rejected or retried instead. Re-applying a parked operation produces new ids plus a durable old-to-new mapping; the parked operations themselves are never edited, and a parked lineage keeps its descendants alive and out of garbage collection.

## 6. Offline work

- **RQ-33** A replica accepts writes while disconnected and reconciles later. Anything not yet in authority custody is dirty and immune to eviction.
- **RQ-34** A node holding dirty state may neither be emptied wholesale nor be re-bound to a different repository identity until that state is drained or explicitly abandoned. Abandonment returns an inventory and is recorded. *(There is no "origin switch" any more: identity includes the authority, so a different authority is a different repository.)*
- **RQ-35** Sync state is a first-class, user-visible concept: pending counts, pending bytes, age, parked operations and their reasons.
- **RQ-36** Reconciliation has exactly three outcomes per operation — applied, parked, or rejected with a reason (missing blobs, a collected base, authorization, protocol version) — and only "applied" clears dirty.
- **RQ-37** Offline authorization is **undecided**. Four options are on the table (strict deny, bounded read-only grace, a signed repo-and-user-scoped TTL grant, a local trust boundary); writes while offline always require valid, unexpired authorization.

## 7. Storage, keys and reclamation

- **RQ-38** Objects are keyed by content hash; the operator specified SHA-256. This has a known cost: jj's ids are 16 and 20 bytes today, so a mapping layer is required.
- **RQ-39** For v1 the storage unit is one file per object. Packing, segmentation and key-value storage are deferred, and the trade-offs must be written down rather than decided silently.
- **RQ-40** Store (durable, authoritative) and Cache (evictable, rebuildable) are distinct. The trait boundaries stay in the design, but the MVP ships **one** implementation of each.
- **RQ-41** jj's local index is not replicated. The authority may expose an optional opaque, version-tagged checkpoint; a replica may use it only if it validates, and must otherwise rebuild. The MVP rebuilds.
- **RQ-42** Garbage collection runs only at the authority. Its input is reachability from heads, plus every working-copy commit a node reports as current, plus parked lineages, plus any custody the authority has already granted, plus a retention window. Nothing about a client's read position is an input, because a read is pinned to a commit that stay reachable until the client moves it. *(The custody term is derived: an acknowledgement is a promise, and retention must last at least as long as the promise.)*
- **RQ-43** Eviction is least-recently-used by bytes, with dirty data never evicted. Retention must exceed the offline window or an offline replica will push onto a collected base.

## 8. Coherence and live updates

- **RQ-44** Synchronization is server push over gRPC streaming, not polling: new operations, head changes, blobs becoming available, replica lag.
- **RQ-45** A client sees work from other clients on the same node **and** work that arrives from upstream — commits, bookmarks, heads — without remounting. Seeing the repository advance is not the same as its own view moving: RQ-14 still holds, and `@` only moves when the client moves it.
- **RQ-46** On a new head, a client may refresh what it knows about the repository — history, bookmarks, what is available — while its own reads continue at its commit. Warming the cache ahead of a read is optional and deferred (RQ-20).
- **RQ-47** A bookmark advanced elsewhere propagates up to the authority and then down to every subscribed client.

## 9. The mount is a working copy

- **RQ-48** The mount presents at least one working copy that is read-write and usable as a version-control working copy. **Unsettled:** whether the mount root *is* that working copy, or whether working copies live in subdirectories beneath it (OQ-8).
- **RQ-49** The VFS keeps **no persistent state**: no blob cache, no metadata cache, nothing restored after a crash. Transient buffers are permitted and are simply lost.
- **RQ-50** Writes stream to the local node per call; the VFS does not accumulate file content on the node's behalf.
- **RQ-51** The node acknowledges a write once the bytes are durably staged at the node, before any snapshot exists.
- **RQ-52** A snapshot is taken on a trailing debounce of 0.5–1 s, at a 30 s maximum age, and immediately on `fsync` or `close`. Intervals are runtime-configurable.
- **RQ-53** Propagation runs on a separate clock: on idle, on `fsync`, or every 5–30 s. Runtime-configurable. Reaching the authority is eventual and is not the VFS's concern.
- **RQ-54** Uncommitted bytes live at the node in a mutable staging area; they become content-addressed blobs at snapshot time.
- **RQ-55** `fsync` on the mount is satisfied by local durability at the node.
- **RQ-56** **(derived)** The mount must support what ordinary version-control work needs: create, write, truncate, rename, delete, make and remove directories, change mode, and create symlinks.

## 10. Protocol and transport

- **RQ-57** Conflicts are **first-class data, not errors**. When an advance or a rebase cannot apply cleanly, the result is a commit whose tree carries the conflict, materialised in the mount as conflicted content that the user resolves by editing; the next snapshot records the resolution. Nothing is refused and nothing is lost. *(jj already represents conflicts inside the tree, so this needs no new mechanism; the mount must materialise conflicted content and treat an edit as its resolution.)*
- **RQ-58** Advancing a mount's view is a **policy**, not an obligation: never, on request, or automatically when the mount is idle. An automatic advance must never run while there are unsnapshotted writes, and must be rate-limited so a busy upstream cannot churn the mount. *(An advance of a clean working copy is a checkout, not a rebase, and therefore cannot conflict. Only an advance that has to re-apply local edits can.)*
- **RQ-59** gRPC only, over HTTP/2 or a Unix domain socket. The local VFS-to-node path uses a unique socket path, never loopback TCP.
- **RQ-60** The protocol carries durability levels, pending counts, sync state, custody acknowledgements and a subscription stream. Local-first capabilities are named RPCs, not inferred.
- **RQ-61** Errors carry an explicit retryability and a retry hint. Clients distinguish "retry later" from "this will not work".
- **RQ-62** Server-side reads are pure: no read RPC mutates authoritative state.

## 11. Platform and implementation

- **RQ-63** Linux only for the MVP: one filesystem implementation, no portability layer.
- **RQ-64** One implementation per seam. Seams may exist; shipping a second implementation is not part of this phase.
- **RQ-65** The existing `daemon` crate is not to be reused.
- **RQ-66** The CLI remains a first-class client of the same local node, and the VFS workspace is an ordinary jj workspace that the CLI can see.

## 12. Verification

- **RQ-67** Acceptance criteria must be executable or falsifiable, and one experiment must be able to falsify the design's load-bearing assumption.
- **RQ-68** Tests must not be vacuous, must not depend on wall-clock ordering, must not accept "it didn't crash", and must not use the system under test as their own oracle.
- **RQ-69** The metadata footprint must be measured before the replication plane is built. It is the assumption everything else rests on.

## 13. Documentation and working practice

- **RQ-70** Design documents are bottom-line first, in plain language, with diagrams for flows and edge cases. No framework vocabulary unless it earns its place. Terms are defined before use, and the document includes a reading guide.
- **RQ-71** Design phases do not write production code. Agent work happens in jj workspaces, never in the main checkout, and each deliverable is integrated by moving a bookmark rather than by copying files.

---

## 14. Non-goals and deferred work

Stated as out of scope now, without prejudice to later phases:

1. Encryption at rest, and TLS for non-local peers.
2. Backup and restore. **Consequence:** an authority whose disk is lost and which has no upstream loses the repo. This is a stated exposure and needs explicit acceptance (OQ-5).
3. Packing, segmentation, compaction, key-value storage.
4. Ranged reads and large-file chunking. Whole-object reads make a small read at a large offset expensive.
5. `mmap` of a cold blob: a page fault cannot be told to retry.
6. Multi-upstream and fan-in.
7. Live reflection was deferred once and is now **in scope** for the MVP.
8. The VFS `/commits/` virtual directory may be removed; nothing depends on it.
9. CLI-to-VFS coordination beyond the socket.

## 15. Open questions

| # | Question | Why it blocks |
|---|---|---|
| OQ-1 | Custody acknowledgement: is `provisional` a flag on the three levels, or a fourth level? | Changes the wire shape; rejecting the idea means offline writes are refused |
| OQ-2 | Offline authorization: which of the four options, and what is the maximum offline write window? | Sets the residual access of a revoked user, and how long a node may keep writing without contacting the authority |
| OQ-3 | FUSE error for a state that has been collected: `ESTALE` or `EAGAIN`? | Determines how a long-running tool reacts when the commit it is reading is no longer retained |
| OQ-4 | Announcement at a replica: "durable at the announcing node" (impossible for a replica) versus "locally fsynced or in authority custody" | Strict reading makes offline commits invisible to others until reconnect |
| OQ-5 | Accept that authority disk loss without an upstream means repo loss, or bring backup into scope? | One sentence to accept, a subsystem to avoid |
| OQ-6 | **Who constructs an operation:** the node, against its current head, or the client, against whatever base it last saw | Node-built keeps every hop's log linear and makes merges an offline edge case. Client-built makes a fork at the node for every stale base, so merge-and-park becomes steady state and the loser rewrites an id |
| OQ-7 | What "tracking a bookmark" means: a read-only view that moves with the bookmark, or the workspace itself following it | A view can change under a reader; a working copy cannot |
| OQ-8 | Mount layout: is the mount root the working copy, or does the mount expose a directory of workspaces each containing one? | Decides path resolution in the VFS, inode identity across workspaces, and where the CLI expects `.jj`. It must be settled before the write protocol is specified |
| OQ-9 | Does the node keep a separate workspace registry (`ListWorkspaces`, `CheckWorkingCopyChanges`), or is a workspace simply an entry in the view with no extra bookkeeping? | With node-scoped names the view already answers "which workspaces exist"; a separate registry would only add `CheckWorkingCopyChanges`. Dropping it removes a surface nobody has asked for |
| OQ-10 | Does the operation log belong in the commit cloud, or does each machine keep its own while only commits and bookmarks are shared? | Pushing an operation, the heads compare-and-swap and parked operations only exist if the log is shared; keeping it local turns the commit cloud into a content store with a remote, which is git's shape, and changes most of the write path |
| OQ-11 | Does the shared log carry a working-copy pointer for every workspace, or only bookmarks and heads, with each workspace's pointer local? Related: are the intermediate snapshots, whose commits amendment makes unreachable, retained as history or pruned with the operations that point at them? | If pointers are shared, every workspace's pointer merge is a conflict surface; if they are local, a workspace is only visible where it is used. Retaining intermediate snapshots turns the cloud into a reflog with a per-save archive; pruning them keeps the op log a bounded window and makes publication a visibility guarantee, not a preservation one |

---

## Appendix A — questions already answered

These have been asked and answered. Do not re-ask them. Answering is not ratifying: the operator may reopen any of them, and the design must then change.

1. Where the cache lives: a locally running commit-cloud node. The VFS holds no persistent cache. Unix socket, not loopback.
2. The CLI uses the same backend, and has always done so. CLI-to-VFS coordination is out of scope.
3. The two repositories share no caching contract; the commit cloud is simply a backend for each.
4. Object scope: metadata and blobs. The mount is now a working copy, so VFS snapshot capture is in scope; VFS tooling for browsing snapshots is not.
5. Pluggable stores are a later concern: SQLite or Spanner for metadata, files or GCS for blobs.
6. Hashing is content-based, SHA-256 by operator instruction, with the id-width cost acknowledged.
7. One file per object in v1; packing is deferred with its trade-offs written down.
8. Snapshots are immutable; revisions evolve; bookmarks can be immutable; the authority enforces it.
9. Staleness: metadata always local, blobs best effort. A client's view is its own commit and never moves underneath it; only collection can end it, and that is an explicit error.
10. Clients learn of new operations by server push.
11. Offline: accept writes and reconcile later, after being shown the drawbacks.
12. Read-write, not read-only. The debounce sits on the snapshot path, never on the acknowledgement path.
13. Latency targets: metadata near-instant, blobs best effort; concrete numbers are placeholders.
14. Layers above the node: colo/edge, then forge. Arbitrary depth, stores configurable per instance.
15. No hard constraints from the cloud team lead. New dependencies allowed. Do not reuse `daemon`.
16. Exactly two roles, no edge role, roles per repository.
17. An authority with no upstream is first-class.
18. Multiple upstreams are conceptually allowed and deferred in detail.
19. A node serves many repositories and many mounts, multi-user.
20. Concurrent writers on one workspace: impossible by construction, because a workspace belongs to one node and that node admits one writer at a time.
21. A client reads its own commit, pinned for the sequence; the pointer moves only when the client moves it.
22. Partitioned writes are accepted and reconciled; the drawbacks were explained and accepted.
23. "In sync" means divergent trees eventually replicate; the VFS is notified by push.
24. Metadata is durable with explicit acknowledgements; blobs are eventually consistent.
25. Prefetch is per-node configurable; never all blobs of a head.
26. Dirty data is never evicted.
27. The index is not replicated; an optional validated checkpoint is allowed and documented.
28. Store and cache are one abstraction with a shared trait where that is sound.
29. Repository identity is chosen by the creator and scoped to the authority (`<authority>/<owner>/<name>`); the authority enforces uniqueness, and transport is not part of it. (The earlier answer, "server-assigned id", is superseded.)
30. Identity is delegated and propagated; replicas refuse unauthorized clients; per-user namespaces.
31. Deliverable shape: one design document plus a deferred-decisions section, in `docs/design/`.
32. Pins are subscription-stream based and order eviction only; GC ignores them.
33. fsync: local durability plus a bounded push attempt, reporting the achieved level.
34. Operation visibility: metadata immediately, blobs lazily, blocking read then retryable error.
35. Offline authorization: undecided, four options documented with a recommendation.
36. The document must be readable: plain-language preamble, diagrams for flows and edge cases, self-contained appendices.
37. Nothing is ratified. Every decision is a proposal until the operator says otherwise.
38. The MVP is a usable version-control working copy on Linux: read and write, snapshot and propagate behind the scenes, and see other users' updates from the same node and from upstream.
39. The VFS keeps no persistent state; transient buffers are allowed and never restored.
40. Writes stream to the local node per call; the node acknowledges local durability; propagation is eventual and not the VFS's concern.
41. Snapshots use a trailing debounce with a maximum age and an immediate snapshot on `fsync`/`close`; propagation runs on a separate, runtime-configurable clock.
42. "Seeing other users' work" means metadata and blobs propagate up to the authority and back down; clients refresh and may pre-cache. A workspace with a working copy reconciles rather than following a bookmark; whether a read-only view may follow one is OQ-7.
