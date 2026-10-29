# Commit cloud — requirements

**Purpose.** This is the requirement baseline for the multi-tier commit cloud. It records what the operator asked for, in the operator's terms, so that it can be read and corrected independently of any design. The design proposal (`multi-tier-commit-cloud.md`) must satisfy it; where they disagree, this document wins until the operator changes it.

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
- **RQ-5** The same design works at any tier depth with the same binary. Depth is configuration, not a different architecture.

## 3. Roles and topology

- **RQ-6** Exactly two roles: **authority** and **replica**. No third role, no "edge" role.
- **RQ-7** Roles are bound per (node, repository), not per node. One node may be authority for repo A and replica for repo B.
- **RQ-8** The authority is the repo's durable owner and the only place truth is decided: immutability, bookmark policy, op-head compare-and-swap, merge, repo identity, garbage collection. It **may have no upstream at all**; that is a first-class, fully supported configuration (local-first development with no cloud).
- **RQ-9** A replica has exactly one upstream for that repo, is **not durable**, may be emptied wholesale at any time, and is never a backup.
- **RQ-10** Topology for v1 is a tree: one upstream per (node, repo). Multi-upstream and fan-in are deferred, but must not be structurally foreclosed.
- **RQ-11** One node serves N repositories and M mounts. Multi-user machines are supported with per-user isolation.
- **RQ-12** A workspace has exactly one writer. The **client** is responsible for not running two writers against one workspace; the **authority** enforces, at push time, that only the holder of the current fence may write. The node stores the workspace-to-working-copy-commit mapping and the fence as metadata; it never stores a working copy's files. *(Today's code already keeps a registry row per (repo, user, workspace): `WorkspaceState` in `common/proto/workspace.proto`, table `workspaces` in `server/db/schema_sqlite.sql`. Whether the MVP keeps that registry is OQ-9.)*
- **RQ-13** Repository identity is human-chosen and authority-scoped, in the shape a forge uses: `<authority>/<owner>/<name>`. The creator picks it when the repository is registered, and the authority enforces uniqueness within itself. Transport is **not** part of identity: the same repository reached over a Unix socket and over HTTPS is one repository, while a different authority is a different repository. Renaming is out of scope for the MVP. *(Contradicts the proposal's D18, which makes the id opaque and server-assigned. Today's code lets the client pass `repo_id` and falls back to server assignment: `lib/src/cc_backend.rs:55-64`.)*

## 4. Reads

- **RQ-14** A sequence of reads sees **one consistent state** of the repository. When a client starts reading — a directory listing, then the files in it — it names the operation it is reading from, and every call in that sequence is answered from that operation. The operation is **held** for the duration, so garbage collection cannot remove it underneath the reader while the sequence is running. *(A CLI command already does this implicitly: it reads one state from start to finish. The VFS has no command boundary, so it holds per open handle instead.)*
- **RQ-15** If that state is too old to serve, the call fails with an explicit retryable "stale" error. It never silently mixes two states. *(The failure being ruled out: `stat` reports 100 bytes, `read` returns 90 with no error, because a commit landed between the two calls.)*
- **RQ-16** Metadata is served by the local node from what it holds: the operation log, the heads, commit headers, tree manifests and the attributes the VFS needs. A metadata read never depends on a network round trip. *(**Open (OQ-10):** whether the operation log belongs in the commit cloud at all. With a git backend it never leaves the machine; this design assumes it is shared.)*
- **RQ-17** Blobs are fetched lazily. A read of a blob that is not local blocks up to a timeout and then returns a retryable error.
- **RQ-18** `stat` never lies. Size, mode and mtime come from metadata, never from fetching content.
- **RQ-19** Attributes are deterministic: given one operation, size, mtime, executable bit and directory ordering always have the same values. *(Agreed as stated. Deferred: which timestamp an mtime carries — content time, commit time or checkout time — is a policy choice, not part of this requirement.)*
- **RQ-20** Prefetching is optional and deferred. If a node implements it, it may warm its cache with content it used before, but it must never fetch every blob of an operation on a large repository.
- **RQ-21** A **cache hint** (the design calls it a *pin*) keeps a blob from being evicted while a client is reading it. It is scoped per user and per client, expires on its own, and is **never** an input to garbage collection. It is unrelated to the hold in RQ-14, which protects an operation rather than a blob.

## 5. Writes, acknowledgements and durability

- **RQ-22** A node serializes operation creation per repository: at most one local client is creating and appending an operation at a time. Two clients on the same node must never race to append, because the loser has to rebuild its operation against a new parent and therefore produces a new operation id.
- **RQ-23** Every hop's log is append-only: once a node has accepted an operation it is never rewritten, re-identified or reordered. Divergence is resolved by appending a merge operation or by parking — never by editing history.
- **RQ-24** The operation model is multi-writer and content-addressed: simultaneous lineages converge by DAG merge, never by last-write-wins. Forks are expected to be rare because exactly one workspace has a writer.
- **RQ-25** An operation is never announced before every blob it references is retrievable at the announcing node. No dangling references, at any tier.
- **RQ-26** Every write acknowledgement reports the durability level actually achieved and the work still pending. The levels are `local`, `upstream` and `authority`; `upstream` is only meaningful at tier 1, and an acknowledgement that has not reached the authority is marked **provisional**.
- **RQ-27** `fsync` returns once the data is locally durable at the node plus a bounded push attempt. It does not wait for the authority.
- **RQ-28** The commit cloud must not debounce or delay acknowledgements. Bursts are accepted; coalescing may happen only after the acknowledgement.
- **RQ-29** Immutability is enforced by the authority, inside the compare-and-swap that advances the heads. A replica never enforces it; a violation is parked, not applied.
- **RQ-30** Bookmark divergence follows a per-bookmark policy: fast-forward-only (default, parking on conflict), authority-wins, or manual. Nothing is silently discarded.
- **RQ-31** Operations rejected by policy are parked, surfaced and recoverable. Re-applying them produces new ids plus a durable old-to-new mapping, and a parked lineage keeps its descendants alive.

## 6. Offline work

- **RQ-32** A replica accepts writes while disconnected and reconciles later. Anything not yet in authority custody is dirty and immune to eviction.
- **RQ-33** A node holding dirty state may not switch origin and may not be emptied wholesale until drained or explicitly abandoned. Abandonment returns an inventory and is recorded.
- **RQ-34** Sync state is a first-class, user-visible concept: pending counts, pending bytes, age, parked operations and their reasons.
- **RQ-35** Reconciliation has exactly three outcomes per operation — applied, parked, or rejected for missing blobs — and only "applied" clears dirty.
- **RQ-36** Offline authorization is **undecided**. Four options are on the table (strict deny, bounded read-only grace, a signed repo-and-user-scoped TTL grant, a local trust boundary); writes while offline always require valid, unexpired authorization.

## 7. Storage, keys and reclamation

- **RQ-37** Objects are keyed by content hash; the operator specified SHA-256. This has a known cost: jj's ids are 16 and 20 bytes today, so a mapping layer is required.
- **RQ-38** For v1 the storage unit is one file per object. Packing, segmentation and key-value storage are deferred, and the trade-offs must be written down rather than decided silently.
- **RQ-39** Store (durable, authoritative) and Cache (evictable, rebuildable) are distinct. The trait boundaries stay in the design, but the MVP ships **one** implementation of each.
- **RQ-40** jj's local index is not replicated. The authority may expose an optional opaque, version-tagged checkpoint; a replica may use it only if it validates, and must otherwise rebuild. The MVP rebuilds.
- **RQ-41** Garbage collection runs only at the authority. Its input is reachability from heads plus parked lineages plus live snapshot holds plus a retention window. Client pins are never an input.
- **RQ-42** Eviction is least-recently-used by bytes, with dirty data never evicted. Retention must exceed the offline window or an offline replica will push onto a collected base.

## 8. Coherence and live updates

- **RQ-43** Synchronization is server push over gRPC streaming, not polling: new operations, head changes, blobs becoming available, replica lag.
- **RQ-44** A client sees operations from other clients on the same node **and** operations that arrive from upstream, without remounting.
- **RQ-45** On a new head, clients refresh metadata and may prefetch the blobs they will need.
- **RQ-46** A bookmark advanced elsewhere propagates up to the authority and then down to every subscribed client.

## 9. The mount is a working copy

- **RQ-47** The mount presents at least one working copy that is read-write and usable as a version-control working copy. **Unsettled:** whether the mount root *is* that working copy, or whether working copies live in subdirectories beneath it (OQ-8).
- **RQ-48** The VFS keeps **no persistent state**: no blob cache, no metadata cache, nothing restored after a crash. Transient buffers are permitted and are simply lost.
- **RQ-49** Writes stream to the local node per call; the VFS does not accumulate file content on the node's behalf.
- **RQ-50** The node acknowledges a write once the bytes are durably staged at the node, before any snapshot exists.
- **RQ-51** A snapshot is taken on a trailing debounce of 0.5–1 s, at a 30 s maximum age, and immediately on `fsync` or `close`. Intervals are runtime-configurable.
- **RQ-52** Propagation runs on a separate clock: on idle, on `fsync`, or every 5–30 s. Runtime-configurable. Reaching the authority is eventual and is not the VFS's concern.
- **RQ-53** Uncommitted bytes live at the node in a mutable staging area; they become content-addressed blobs at snapshot time.
- **RQ-54** `fsync` on the mount is satisfied by local durability at the node.
- **RQ-55** **(derived)** The mount must support what ordinary version-control work needs: create, write, truncate, rename, delete, make and remove directories, change mode, and create symlinks. The proposal currently specifies none of these.

## 10. Protocol and transport

- **RQ-56** gRPC only, over HTTP/2 or a Unix domain socket. The local VFS-to-node path uses a unique socket path, never loopback TCP.
- **RQ-57** The protocol carries durability levels, pending counts, sync state, snapshot holds, custody acknowledgements and a subscription stream. Local-first capabilities are named RPCs, not inferred.
- **RQ-58** Errors carry an explicit retryability and a retry hint. Clients distinguish "retry later" from "this will not work".
- **RQ-59** Server-side reads are pure: no read RPC mutates authoritative state.

## 11. Platform and implementation

- **RQ-60** Linux only for the MVP: one filesystem implementation, no portability layer.
- **RQ-61** One implementation per seam. Seams may exist; shipping a second implementation is not part of this phase.
- **RQ-62** The existing `daemon` crate is not to be reused.
- **RQ-63** The CLI remains a first-class client of the same local node, and the VFS workspace is an ordinary jj workspace that the CLI can see.

## 12. Verification

- **RQ-64** Acceptance criteria must be executable or falsifiable, and one experiment must be able to falsify the design's load-bearing assumption.
- **RQ-65** Tests must not be vacuous, must not depend on wall-clock ordering, must not accept "it didn't crash", and must not use the system under test as their own oracle.
- **RQ-66** The metadata footprint must be measured before the replication plane is built. It is the assumption everything else rests on.

## 13. Documentation and working practice

- **RQ-67** Design documents are bottom-line first, in plain language, with diagrams for flows and edge cases. No framework vocabulary unless it earns its place. Terms are defined before use, and the document includes a reading guide.
- **RQ-68** Design phases do not write production code. Agent work happens in jj workspaces, never in the main checkout, and each deliverable is integrated by moving a bookmark rather than by copying files.

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
| OQ-2 | Offline authorization: which of the four options, and what is the maximum offline write window? | Sets the residual access of a revoked user, and the `lease_ttl` bound |
| OQ-3 | FUSE error for a stale snapshot: `ESTALE` or `EAGAIN`? | Determines whether a long-running tool survives a snapshot rollover |
| OQ-4 | Announcement at a replica: "durable at the announcing node" (impossible for a replica) versus "locally fsynced or in authority custody" | Strict reading makes offline commits invisible to others until reconnect |
| OQ-5 | Accept that authority disk loss without an upstream means repo loss, or bring backup into scope? | One sentence to accept, a subsystem to avoid |
| OQ-6 | **Who constructs an operation:** the node, against its current head, or the client, against whatever base it last saw | Node-built keeps every hop's log linear and makes merges an offline edge case. Client-built makes a fork at the node for every stale base, so merge-and-park becomes steady state and the loser rewrites an id |
| OQ-7 | What "tracking a bookmark" means: a read-only view that moves with the bookmark, or the workspace itself following it | A view can change under a reader; a working copy cannot |
| OQ-8 | Mount layout: is the mount root the working copy, or does the mount expose a directory of workspaces each containing one? | Decides path resolution in the VFS, inode identity across workspaces, and where the CLI expects `.jj`. It must be settled before the write protocol is specified |
| OQ-9 | Does the node keep the workspace registry (`ListWorkspaces`, `CheckWorkingCopyChanges`), or is the workspace purely local apart from its fence? | The registry exists today; keeping it makes the fence natural, dropping it removes a cross-machine listing everyone may expect |
| OQ-10 | Does the operation log belong in the commit cloud, or does each machine keep its own while only commits and bookmarks are shared? | The design's convergence story — pushing an operation, heads compare-and-swap, parked operations — assumes a shared op log. Keeping it local turns the commit cloud into a content store with a remote, which is git's shape, and changes the shape of most of the write path |

---

## Appendix A — questions already answered

These have been asked and answered. Do not re-ask them. Answering is not ratifying: the operator may reopen any of them, and the design must then change.

1. Where the cache lives: a locally running commit-cloud node. The VFS holds no persistent cache. Unix socket, not loopback.
2. The CLI uses the same backend, and has always done so. CLI-to-VFS coordination is out of scope.
3. The two repositories share no caching contract; the commit cloud is simply a backend for each.
4. Object scope: metadata and blobs. VFS snapshots are a separate concern, now in scope as a working copy rather than as snapshot tooling.
5. Pluggable stores are a later concern: SQLite or Spanner for metadata, files or GCS for blobs.
6. Hashing is content-based, SHA-256 by operator instruction, with the id-width cost acknowledged.
7. One file per object in v1; packing is deferred with its trade-offs written down.
8. Snapshots are immutable; revisions evolve; bookmarks can be immutable; the authority enforces it.
9. Staleness: metadata always local, blobs best effort, pinned snapshots, no tearing, explicit retryable stale error.
10. Clients learn of new operations by server push.
11. Offline: accept writes and reconcile later, after being shown the drawbacks.
12. Read-write, not read-only. Debounce belongs to the client side of the boundary, never to the acknowledgement path.
13. Latency targets: metadata near-instant, blobs best effort; concrete numbers are placeholders.
14. Layers above the node: colo/edge, then forge. Arbitrary depth, stores configurable per instance.
15. No hard constraints from the cloud team lead. New dependencies allowed. Do not reuse `daemon`.
16. Exactly two roles, no edge role, roles per repository.
17. An authority with no upstream is first-class.
18. Multiple upstreams are conceptually allowed and deferred in detail.
19. A node serves many repositories and many mounts, multi-user.
20. Concurrent writers on one workspace: impossible by design.
21. Reads are pinned, and a stale token may error rather than tear.
22. Partitioned writes are accepted and reconciled; the drawbacks were explained and accepted.
23. "In sync" means divergent trees eventually replicate; the VFS is notified by push.
24. Metadata is durable with explicit acknowledgements; blobs are eventually consistent.
25. Prefetch is per-node configurable; never all blobs of a head.
26. Dirty data is never evicted.
27. The index is not replicated; an optional validated checkpoint is allowed and documented.
28. Store and cache are one abstraction with a shared trait where that is sound.
29. Repository identity is server-assigned.
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
42. "Seeing other users' work" means metadata and blobs propagate up to the authority and back down; clients refresh and may pre-cache. A workspace with a working copy reconciles rather than following a bookmark.
