# Design notes — what survives the first pass

**What this is.** The first design document and its review are being deleted. This file keeps the parts of them that are not tied to that document's structure: the option space, the trade-offs that were argued once, invariants worth testing in any design, a failure checklist, and the defects that must not recur. It is an input to the next design, not a design, and nothing in it is ratified.

**What was deleted, and why.** `multi-tier-commit-cloud.md` described a system with per-workspace leases, server-assigned repository ids, and a shared log that grew with every snapshot. Three later requirements removed its footings: workspaces are pointers with node-scoped names (RQ-3-7), identity is authority-scoped and chosen (RQ-3-8), and local history is separate from published history (RQ-5-2). With those gone, the document's fences, `LEASE_SUPERSEDED` path, origin-switch rules and per-snapshot publication all described machinery that no longer exists.

---

## 1. The option space

**Option 0 — status quo plus a read cache.** Today's server stays the only authority, a blob cache (optionally a git promisor) sits in front, the daemon stays. No new durability or coherence risk, fastest to build, published precedent. But metadata still crosses the network on every `lookup` and `readdir` because the VFS has no cache, there is no snapshot pinning so long reads tear, and there are no offline writes. Wins when users are always online and repos are small. Fails offline.

**Option B — thin replica.** A local node caches metadata and blobs, serves reads locally, forwards writes synchronously to the authority; no offline writes, no reconcile, no merge. A *configuration* of the chosen option (`accept_offline_writes = false`), not a competing architecture — the wire format is identical. This is the sane first milestone: ship the format, then enable dirty state.

**Option C — symmetric peers.** Every node is an authority and fan-in exists from day one. Symmetric, no tier starvation, but no safe reachability-based GC, no single immutability point, merge on the hot path, and no owner for conflict resolution. Rejected. Its best argument stands and should be answered in any new design: A's asymmetry lets a laptop authority hold data the forge never sees, so "cloud" is partly a courtesy.

**Option D — depth 1.** The chosen option with `max_depth = 1`: same code, less machinery. A deployment profile.

| Dimension | 0 | B | C | Chosen |
|---|---|---|---|---|
| Offline writes | no | deferred | yes | yes |
| Arbitrary depth | no | read-only | yes | yes |
| RPO of an acknowledged write | authority commit | authority commit | node disk | node disk unless the push completed |
| GC safety | one authority | one authority | unsolved | one authority, explicit roots |
| Immutability point | one | one | none | one, inside the compare-and-swap |
| Held reads | no | yes | yes | yes |
| Time to first demo | shortest | short | long | medium |
| Failure surface | network | network | merge storms, GC races | reconcile, conflict resolution, quota |

## 2. Trade-offs already argued — do not re-derive, re-check only if the model changed

### 2a. What `fsync` returns

| | block until upstream-durable | local only | **local + bounded push** |
|---|---|---|---|
| Returns when | the authority holds the operation and its blobs | local fsync | local fsync plus a bounded push attempt |
| RPO | near zero | node disk loss | node disk loss unless the push completed |
| p99 | WAN round trip, unbounded | local fsync | local fsync plus at most a bound |
| Offline | fails | works, diverges silently | works, reported as local and provisional |
| User signal | none | none | pending operations |

Chosen: local plus a bounded push attempt, reporting the level actually reached. The consequence must be stated wherever the behaviour is described: **a machine whose disk dies inside the push window loses acknowledged writes**, and the UI has to say so rather than imply otherwise.

### 2b. Operation visibility against blob readiness

| | announce only when the whole blob set is local | fail fast when a blob is cold | **metadata immediate, blobs lazy** |
|---|---|---|---|
| Visibility | bounded by transferring the tree | immediate | immediate |
| Cold read | never cold | immediate error | blocks up to a timeout, then retryable |
| Failure shape | starvation: a 10 GB tree never appears | false failures, never a hang | bounded stall, then retryable |

Chosen: the third. `mmap` of a cold blob stays unsupported, because a page fault cannot be told to retry.

### 2c. Pinning

| Option | Pros | Cons |
|---|---|---|
| none | zero surface | a readdir-then-read sequence loses blobs under pressure |
| TTL lease RPC | simple, no stream | renewal traffic; silent renewal failure; a crashed client pins for a full TTL |
| handle-bound refcount | exact release; dies with the connection | no open/release in the protocol; a large readdir means thousands of handles |
| **subscription pin set** | reuses the push stream; dies with liveness | coarse: over-pins or truncates, and truncation causes a safe miss |

Chosen: subscription pins, scoped per user and client, ordering eviction only, never an input to GC. Two open defects from review belong here: the pin set must be able to **change during a session** (a unary request plus a server stream cannot express it), and pins must not need a hold that expires sooner than the pin TTL.

### 2d. The jj index

Replicate it as authoritative (fast cold start, but derived state replicated with no validation), rebuild only (always correct, cold start pays O(commits)), or expose an optional opaque, version-tagged checkpoint (fast, deletable, but needs validation and can mislead). Chosen: rebuild in the MVP, leaving the checkpoint additive. Trigger for revisiting: cold start above about 5 s p95 at more than 100k commits.

### 2e. The operation model

Single-writer authority with leased id ranges (no merge, but identity becomes authority-assigned and offline writes need pre-leased ranges), hybrid forward-when-connected / author-when-partitioned (two identity paths and the same rewrite problem on the hot path), or a content-addressed DAG with merge. Chosen: the DAG. It survives the rework; the open half is **who constructs the operation** (OQ-6).

### 2f. mtime policy

Deferred. Record the corrected fact so it is not re-introduced wrongly: Perforce's **default is sync-time mtime**, with `+m`/`modtime` opting into pre-submit time; submit time is never used. An earlier draft claimed the opposite.

## 3. Invariant candidates

These are properties of the problem rather than of the deleted design. Each should either appear in the next document or be consciously dropped.

| Candidate | Statement |
|---|---|
| Truthful locality | "local" means bytes an offline read can serve; "custody" is a separate, explicit promise. Never conflated |
| Held reads | Every read names one operation; a sequence resolves to that operation and cannot tear |
| Explicit staleness | A state too old to serve fails retryably; it never half-applies |
| Pure reads | No read RPC mutates authoritative state |
| Immutability in the write | Immutability is checked inside the compare-and-swap that advances the heads; replicas never enforce it |
| Truthful acknowledgement | The reported level never exceeds the achieved one, and pending counts agree at the same watermark |
| Push order | Blobs before the operation that references them; an operation with an absent blob is rejected |
| Deterministic ids | Content-addressed, computed by the writer, no round trip |
| Integrity | Bytes are verified against the key on write and on serve; size in metadata equals blob length |
| Single-flight | Concurrent demand for one blob collapses into one fetch |
| Deterministic attributes | Size, mtime, mode and order are pure functions of the operation |
| Cursor stability | A cursor is valid only in its issuing state; a foreign cursor is an error, never a silent skip |
| Authorization at serve | Identity and grant are checked before bytes leave, including for cached bytes |
| No acknowledgement debounce | Bursts are accepted; coalescing happens only after the acknowledgement |
| Serialised appends | One operation is created at a time per repository per node |
| Append-only | An accepted operation is never rewritten, re-identified or reordered |
| Local versus published | Local and shared history advance on different clocks |
| Role per repository | One node may be authority for A and replica for B with no leakage |

Two invariants from the old set are **dropped, not deferred**: anything phrased as a fence or a lease (jj has none — see §6), and "a node adopts the upstream's epoch on push", which cannot hold without defining which side is authoritative for the counter.

## 4. Failure checklist

Keep these as test cases regardless of the final design. Each was either in the old matrix or found missing from it.

- Upstream unreachable: writes acknowledged locally, pending counted, work continues.
- Replica disk full: evict clean data, refuse dirty data, return a distinct quota error rather than a generic I/O failure.
- Crash between writing a blob and the operation that references it: orphan blob is harmless and collectable.
- Crash after the acknowledgement but before propagation: the acknowledged data must survive a process restart.
- Disk loss with only local data: the loss must be reportable, and reporting it needs an inventory that exists somewhere other than the lost disk.
- Corrupt or truncated blob at a replica: detected on serve, treated as a miss.
- Two operations from the same parent: merged, never last-write-wins.
- Operation the receiver will not apply: refused with a reason, never silently dropped.
- State collected under a reader: held operations survive; unheld ones may fail retryably.
- Writer offline longer than retention: pushing onto a collected base must fail with a clear signal and a resync path.
- Clock skew: affects grant expiry and any pointer tie-break that depends on wall time.
- Subscription resume after a long absence: full resync, no gap and no duplicate sequence.

## 5. Defects the first draft had — the next one must not repeat them

Found by three independent critics; all three blocked. These are the ones that survive the deletion of that document:

1. **Read-your-writes.** If reads resolve only against a committed operation, a mount cannot see its own unsnapshotted edits: `stat` reports the pre-edit size and a newly created file does not appear until the snapshot. Any design with a read-write mount must say what a read of dirty content returns, and say whether that changes the "held reads" invariant.
2. **Namespace mutation.** `rename`, `unlink`, `mkdir`, `rmdir`, `chmod`, `truncate` and `symlink` were specified nowhere. A deleted file leaves nothing in a staging directory, so deletion needs a tombstone or a diff against the base. No amount of content-addressing fixes this.
3. **Snapshot consistency.** Four unspecified races: a write arriving during the hash (commits a state the file never had), an `fsync` snapshot overlapping a debounce snapshot (forks the workspace), a write arriving between hash and commit (dropped by a naive dirty flag), and `close` on every file (snapshot storm during a build).
4. **Custody without a lifecycle.** An acknowledgement is a promise; the promise must be a garbage-collection input, must relate explicitly to retention, and must be renew or expire. Otherwise a sweep can legally break it.
5. **Holds that stop at one tier.** A hold served by a local node does nothing for a collection that runs at the authority. Either holds relay upward, or local eviction respects them, or the claim is scoped down.
6. **A pin set that cannot change.** A unary request plus a server stream conveys the set once; the design needs it to move per read sequence.
7. **Coordination the library does not have.** jj has no lease, fence or epoch for workspaces; `merge_wc_commit` resolves a contested pointer silently, keeping the earlier operation. Inventing a fence contradicts the library and produces rules no implementation can satisfy.
8. **Untested convergence.** Bookmark and head merge rules were stated in prose with no invariant, no acceptance test, and one of their error codes missing from the taxonomy.
9. **An experiment that cannot decide.** Pass and fail thresholds left an open band in which the plausible result falls, and the pass condition contradicted the hypothesis.
10. **Test anti-patterns worth naming up front**: absolute latency assertions, "it didn't crash", the system under test as its own oracle, accepting a mismatch as a new baseline, retry loops that hide non-idempotency.

## 6. Facts about jj that any design must respect

Verified against jj-lib 0.46.0 at `/home/bogdan/work/google-jj/jj-upstream`.

- **A workspace is a name-to-commit pointer** in the view (`core/src/op_store.rs:193`), not a lock. `WorkspaceName` is a plain string.
- **A contested pointer is resolved silently.** `merge_wc_commit` (`lib/src/repo.rs:1650-1677`) keeps the side whose operation finished first; the tie-break is wall-clock end time (`lib/src/op_heads_store.rs:154`). There is no conflict representation for workspace pointers, unlike bookmarks (`RefTarget = Merge<Option<CommitId>>`, `core/src/op_store.rs:64`).
- **Publishing never checks the current heads.** `publish()` (`lib/src/transaction.rs:231-237`) takes the op-heads lock and appends unconditionally; a stale parent simply creates a second head. Divergence is detected on the next load and reported as "Concurrent modification detected, resolving automatically" (`cli/src/cli_util.rs:830`).
- **The op-heads lock is explicitly not for correctness** (`lib/src/op_heads_store.rs:67-71`); it stops duplicate reconciliation.
- **No lease, fence, epoch or ownership exists** anywhere in `lib/`, `core/`, `cli/` or `frontend/`.
- **Operation ids hash the view id, the parent ids, the metadata (timestamps, hostname, username, description, workspace name) and commit predecessors** (`core/src/op_store.rs:294-321`, `:356-373`). Two machines cannot produce the same id, and an operation names its parents permanently.
- **Conflicts live in the tree.** A commit can carry a conflicted tree, materialised as conflicted content; resolving it is an ordinary edit and the next snapshot records the result. Bookmarks have a separate conflict representation (a ref target with several targets). The two are different mechanisms and should not be conflated.
- **Operations are local state by design**: "Operations and views are not meant to be exchanged between repos or users; they represent local state and history" (`core/src/op_store.rs:285-286`). Publishing them over the wire is something a commit cloud adds, not something jj supports.
- **Pruning operations is real and manual**: `OpStore::gc` "prunes unreachable operations and views" (`core/src/op_store.rs:448-455`), called by `jj util gc` together with the backend GC (`cli/src/commands/util/gc.rs:63-68`). The age floor is a hardcoded 14 days (`cli/src/commands/util/gc.rs:56`) and `--expire` accepts only `now`. There is no top-level `jj gc`.
- **Reachable operations are never expired**, so the op log is unbounded in principle; the age floor applies only to operations unreachable from the current head. No compaction, rotation or operation-count limit exists.
- **The operation log is jj's reflog**: the commit index is built from every reachable operation's references *and* its predecessor map (`lib/src/default_index/store.rs:268-278`, `core/src/operation.rs:141-154`), so a commit referenced only by an old operation stays alive. `jj op abandon` plus `jj util gc` is how that history is cut.
- **A missing operation is a real error path**: `ObjectNotFound` becomes "Failed to load an operation" (`cli/src/command_error.rs:495-498`), tested at `cli/tests/test_util_command.rs:107-119`.
: same change id, same parents, new commit id (`cli/src/cli_util.rs:2208-2243`, `lib/src/commit_builder.rs:229-273`).
- **A stale working copy is a client-layer failure**, not a repository one: the check compares the working copy's operation with the repository's and says "The working copy is stale" (`lib/src/working_copy.rs:361-399`, `cli/src/command_error.rs:276-284`).
- **`jj workspace update-stale` is a repair, not a refresh**: it snapshots the local files onto the operation the checkout was made from and then checks the working copy out at the repository's current working-copy commit (`cli/src/cli_util.rs:657-663`, `:719-738`). It exists only because the working-copy pointer sits in the shared view and can be moved by another process or machine while the files on disk are a materialised tree tied to the old operation. With a client-owned pointer and one writer per workspace, the condition cannot arise; what remains is a voluntary advance and crash recovery on node start.
- **A multi-machine divergence test already exists**: `lib/tests/test_bad_locking.rs:104-150` asserts that commits made on two machines are both visible and that the reconcile operation has two parents.

## 7. Experiment E1′

**Hypothesis.** Tree manifests are at most 512 bytes per file, so a 3-million-file repository needs at most 1.5 GB of metadata and metadata reads stay local. Manifests are content-addressed, so per-operation metadata grows with changed directories, not with repository size.

**Measurement.** A synthetic repository of 200,000 files across 4,000 directories; bytes per file; per-operation growth after 10,000 random single-file changes; `Lookup`, `ListDir` and `GetSnapshot` p99 over 10,000 calls from SQLite plus files, no cache; tier-2 catch-up.

**Known defect to fix before running it.** The original thresholds left the band 512 B to 1 KiB per file and 5 to 20 ms p99 undecided, and its pass condition (2 GB at 3M files, i.e. 715 B/file) contradicted its own hypothesis. The next version must state a single decision boundary, in one unit convention.

**Also undefined.** The manifest record itself was never specified — no field list, no size estimate — which is what the experiment is supposed to measure.

**Timebox.** Two engineer-days, no production code, reusing the existing proto and SQLite store. Non-goals: operation-log volume, cold-start rebuild, real-name entropy, blob locality, inode cost.

## 8. Smaller things worth keeping

- **Metrics** that decide something: acknowledgement latency by level, pending count and bytes, pending age, merge rate per 1k operations, conflict count and age, blob miss ratio and fetch latency, single-flight collapse ratio, corruption count, evictions while pinned, stale-read ratio, metadata bytes per file.
- **Error taxonomy** (~20 codes worth keeping): stale state, invalid cursor, expired subscription, blob not local, blob evicted, missing blobs, head compare-and-swap conflict, immutable violation, size mismatch, quota exhausted, corrupt blob, collected base, pending not drained, grant expired, grant stale, offline read-only, permission denied, protocol version, unimplemented. Drop fence and lease codes.
- **Reversibility**: client-computed operation identity and the two-role model are expensive to change later; visibility and holds are cheap; the key/mapping layer is expensive.
- **Upgrade**: changing the operation envelope changes ids, so canonicalisation must freeze and an envelope change is a stop-the-world event.
- **Evidence corrections** to carry: `common/src/lib.rs` holds the id lengths at 15–17, not 12–14; there is no `[A§15.6]` in the jj-commit-cloud brief; `jj-vfs/src/fuse.rs` maps `ENOENT`, `ENOTDIR`, `EISDIR`, `EINVAL` and falls back to `EIO`, so "EIO-only" is wrong.
- **Review process** worth repeating: three models, three lenses (correctness, consistency, implementability), all read-only, each required to cite `file:line`. It found defects that a single reviewer did not, and it caught sixteen of seventeen checkable claims correctly — but the parent must re-verify factual claims before recording them.
