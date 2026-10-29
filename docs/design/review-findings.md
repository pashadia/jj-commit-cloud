# Review findings — consolidated adversarial review

**What this is.** The objections raised against `multi-tier-commit-cloud.md` by three independent critics, deduplicated, verified where verification was cheap, and mapped to repair work. It is an input to the next revision, not a revision itself.

**What was reviewed.** `docs/design/multi-tier-commit-cloud.md` at commit `c52038ba` (the version with the read-write mount added), against the requirement baseline in `requirements.md` and against the two code repositories at `47688804`.

**Who reviewed.**

| Id | Model | Lens | Verdict |
|---|---|---|---|
| R1 | `ollama/kimi-k3:cloud` | distributed-systems correctness: custody, levels, fences, GC roots, ordering, epochs, depth ≥ 2 | **BLOCK** |
| R2 | `ollama/glm-5.3:cloud` | internal consistency, evidence integrity, readability | **BLOCK** |
| R3 | `ollama/deepseek-v4.1-flash:cloud` | implementability of the MVP: protocol sufficiency, scheduler, testability | **BLOCK** |

**All three blocked, on different grounds.** None proposed a different architecture. The role model, the custody split, the push order and the GC root set were accepted as sound; what failed was the document's internal consistency and the specification of the read-write mount.

**Verification convention.** Each finding carries `[verified]` when the parent session re-checked it against the code or the text, `[claimed]` when it rests on the reviewer's reading alone. Of the factual claims re-checked, seventeen held and one did not (F1).

---

## Part A — blocking, found by more than one reviewer

| Id | Finding | Sources | Impact | Fix |
|---|---|---|---|---|
| **B1** | **AC1 still asserts the pre-scope-change scope.** "*(VFS writes are out of scope; the VFS mounts read-only [B§6].)*" contradicts §3, D32 and AC23–AC27. `[verified]` | R2, R3, R1 | A tester cannot tell what is being built; no AC exercises the MVP's write path | edit |
| **B2** | **The read-write path has no protocol.** `WriteFile` and `SnapshotDone` exist only inside the D-11 diagram; `PushBlobs` is used four times and declared nowhere; `ResolveOpHeads` is required by I7 and declared nowhere. `[verified]` | R3, R1, R2 | An implementer's only write RPC is `CommitOp`, which is OQ-6's *rejected* shape | decision + design |
| **B3** | **Appendix A contradicts the body.** D7(a) defines dirty as "not durable upstream" (the pre-custody-split definition, which is false at tier ≥ 2); D11 omits the tier-1 restriction; D14 keeps debounce in the VFS; D25 calls live reflection parked. `[verified]` | R2 (blocking), R1, R3 | The appendix is labelled authoritative, and the operator is asked to argue against it item by item | edit |
| **B4** | **AC17 cannot execute.** Its precondition (`lease_ttl ≥ offline window`) makes "writes continue after the lease expires" unreachable, and its second branch makes startup fail. `[verified]` | R1, R3 | A criterion that can never fail, covering the offline-expiry case that is genuinely undefined | decision + edit |
| **B5** | **E1′ cannot return a verdict.** Pass ≤ 512 B/file, fail > 1 KiB, nothing in between; and the pass threshold (2 GB ⇒ 715 B) contradicts the stated hypothesis (512 B). `[verified]` | R2, R3 | The document says E1′ gates the replication plane; it can answer "undecided" in the plausible band | edit |

## Part B — blocking, found by one reviewer and confirmed

| Id | Finding | Source | Impact | Fix |
|---|---|---|---|---|
| **B6** | **The mount cannot read its own writes.** Reads resolve only against the pinned operation (I5, I20), so after truncating a file `stat` still reports the old size, and a newly created file is invisible until the snapshot. "stat never lies" becomes false for dirty files. `[verified from the text]` | R3 | The core promise of the project breaks in the MVP's normal case | **decision** |
| **B7** | **No namespace mutation.** `rename`, `unlink`, `mkdir`, `rmdir`, `chmod`, `truncate`, `symlink` appear nowhere; a deleted file leaves nothing in the staging directory, so deletion is unrepresentable without a tombstone. `[verified]` | R3 | "Usable as a version-control system" is false | decision + design |
| **B8** | **The snapshot scheduler is undefined at its boundaries.** Write during hash produces a blob of a state the file never had; an `fsync` snapshot can overlap a debounce snapshot and fork the workspace, contradicting D5; a write arriving between hash and commit is dropped; `close` on a clean fd can fire a snapshot storm. `[verified from the text]` | R3 | Silent corruption or a fork the design says cannot happen | design |
| **B9** | **Custody acknowledgements are not a GC input.** I15's root set is heads, parked lineages, holds and retention; an acknowledged blob whose operation never arrived is unreachable and sweepable inside its own retention promise. `[verified]` | R1 | The authority can legally break a promise it already reported as `authority` — worse than the stated provisional RPO | design |
| **B10** | **Holds do not cross tiers.** `HoldSnapshot` is served by the local node; GC runs at the authority; nothing relays a hold, and the eviction veto list omits them. `[verified]` | R1 | The matrix claims "no data-loss risk for held snapshots"; a replica hold of a non-head op can be torn | design |
| **B11** | **Epoch adoption is incoherent at depth ≥ 2.** "A replica adopts the upstream's `heads_epoch` on push" can move the counter backwards, violating I9, while offline-issued tokens carry the old value. `[verified from the text]` | R1 | The shipping topology is three tiers; this is the middle hop | design |
| **B12** | **§8f inverts its own citation.** The evidence says Perforce defaults to *sync-time* mtime and `+m` preserves pre-submit time; the document claims the reverse. `[verified against the research brief]` | R2 | A design rule justified by a false statement about prior art | edit |
| **B13** | **`[A§15.6]` is dangling.** Brief A's §15 is "five biggest structural obstacles", items 1–5. The code claim behind it is true; the citation is not. `[verified]` | R2 | Breaks the document's own rule against dangling citations | edit |
| **B14** | **§8g's defaults violate its own constraint.** Pin TTL is 5 min + 60 s grace, while the per-CLI snapshot hold is 60 s, and the table requires `P < H`. `[verified by arithmetic]` | R2 | Every CLI sequence's pins outlive its hold fivefold; the 60 s pin grace becomes unsatisfiable | edit |
| **B15** | **"Reported with ids" after disk loss is impossible.** The ids were on the lost disk. The matrix conflates a process crash (data survives) with disk loss (nothing to report from). `[verified]` | R2, R3 | False capability claim in the exact data-loss story the operator must accept for OQ-5 | edit |
| **B16** | **The merge rules are untested.** §4.7's five field rules have no invariant and no AC, and `BOOKMARK_CONFLICT` appears once and is missing from the error taxonomy. `[verified: grep count = 1]` | R2 | The headline offline scenario — two bookmark moves that both park — is tested by nothing | edit |
| **B17** | **Two required sections are missing.** The operator asked for a reading guide and for terms defined before use; the rewrite dropped the guide, and "custody", "fence", "provisional" and "dirty" appear before their definitions. `[verified]` | R2 | An explicit requirement, and the operator's original complaint was opacity | edit |
| **B18** | **Pins cannot change on a live subscription.** `Subscribe` takes one unary request and returns a stream, but the pin set must change per read sequence, and the cap drops the oldest pin. `[verified]` | R3 | The blob-pin path has no wire, though AC3 and the eviction diagram depend on it | design |

## Part C — non-blocking

| Id | Finding | Sources |
|---|---|---|
| N1 | AC1's "within 50 ms p99" is an absolute latency assertion, which §12.7 forbids | R2, R3 |
| N2 | §4.4 presents reconciliation as "one of three things" while the matrix has a fourth outcome (`BASE_GC`/`OP_GONE`) | R2 |
| N3 | R8 and R11 are the same risk (authority disk loss) with differently worded resolutions | R2 |
| N4 | §11 items 5 and 6 duplicate each other after the scope edit | R2, R3 |
| N5 | Diagram D-9 labels two different nodes "3" | R2 |
| N6 | The test-prefix taxonomy (`TC`/`PT`/`IT`/`MT`/`FI`/`FU`) is used but never defined | R2 |
| N7 | Open questions get presumptive answers in adjacent text (`ESTALE` for OQ-3; `G = W = 12 h` for OQ-2) | R2 |
| N8 | Diagram labels `D-1…D-11` collide with decisions `D1…D11`; "D-8" is both custody and bookmark divergence | R3 |
| N9 | The prior-art brief warns that writable FUSE is where POSIX semantics break (SlothFS); the design makes the mount writable without confronting it | R2 |
| N10 | Option 0's "can corrupt when the promisor remote is absent" is uncited | R2 |
| N11 | Close-triggered snapshots can fire once per file under a build, contradicting I29's "one operation per burst" | R2 |
| N12 | Citation drift: `common/src/lib.rs` ids are at 15–17 not 12–14; jj-vfs load-once is 48–50 not 49–51; `hash_utils.rs:193-225` runs past `hash_operation`; the channel is per call in `client.rs`, not `util.rs` | R1, R3 (`[verified]`) |
| N13 | "EIO-only error mapping" is wrong: `fuse.rs` maps `ENOENT`, `ENOTDIR`, `EISDIR`, `EINVAL`, then `EIO` | R3 (`[verified]`) |
| N14 | `SIZE_MISMATCH` is non-retryable while `CORRUPT_BLOB` is retryable, though a refetch fixes both | R2 |
| N15 | `CcError` to `tonic::Status` mapping is unspecified, though layer 1 tests "the error taxonomy over every code" | R3 |
| N16 | AC20 is an "or": two different outcomes both pass | R3 |
| N17 | Conflict representation is promised ("conflicted files") but the manifest shape has no conflict variant, and the shipped proto's `TreeValue` does | R3 |
| N18 | At tier 1 the upstream *is* the authority, so `UPSTREAM` and `AUTHORITY` are indistinguishable; no sentence says which to report | R3 |
| N19 | Storage is keyed by `project_id` (client-supplied), not `repo_id`, which undermines per-repo isolation (I26, AC22) | R3 |
| N20 | The superseded ADR still sits in `docs/design/`, and Appendix C's description of it (385 lines) no longer matches the file (860 lines) | R1, R3 (`[verified]`) |

## Part D — reviewer errors

| Id | Claim | Reality |
|---|---|---|
| **F1** | R1 reported that `common/src/lib.rs` holds the id lengths at lines 12 and 14 | They are at 13–18 (`COMMIT_ID_LENGTH` 13, `CHANGE_ID_LENGTH` 14, `OPERATION_ID_LENGTH` 15, `VIEW_ID_LENGTH` 16). R3 had this right. The document's own citation (12–14) is also wrong |

## Part E — where the reviewers disagreed

- **B6 has two repairs.** R3 would amend I5/I20 so the view is "(pinned operation, staged overlay)". R1 would leave the invariants and treat staged content as dirty state excluded from snapshot purity. They are not in conflict, but the choice changes what "pinned read" means everywhere else, so it is a decision, not an edit.
- **B10 has three repairs.** Relay holds upstream as TTL'd GC roots (R1), veto local eviction of a held closure (wedge risk, cf. R6), or scope the claim down to "the hold validates closure liveness at hold time". R1 did not choose.
- **B8 was rated non-blocking by R2** (as a close-storm concern) and blocking by R3 (as an unspecifiable scheduler). R3's reading is the stronger one: a write during hashing commits a state that never existed.

## Part F — decisions these findings force

| Decision | Findings | Question |
|---|---|---|
| Read-your-writes | B6 | Does the mount serve staged content, and if so what happens to I5/I20? |
| Write protocol shape | B2, B7, B18 | Named RPCs for staging, namespace mutation, fsync/close, pins |
| Snapshot consistency | B8 | Quiesce or copy-then-hash; serialise snapshots per workspace; generation counters |
| Custody lifecycle | B9, B11, B15 | Acks as GC roots; retention relationship; return path; epoch issuance |
| Holds across tiers | B10 | Relay, veto, or scope down |
| Offline admission expiry | B4 | What happens at lease TTL and grant expiry mid-partition |
| E1′ definition | B5 | Manifest record layout, band rule, what the two days actually measure |

## Part G — task backlog

| # | Task | Type | Depends on | Size |
|---|---|---|---|---|
| T1 | Consistency pass: B1, B3, B12, B13, B14, B15, B16, B17, N1–N8, N12–N14, N20; rename diagrams to `Fig-1…11` | edit, no decisions | — | 0.5 day |
| T2 | Decide read-your-writes (B6) and amend I5/I20 accordingly | **operator decision** | — | 1 hour + 1 page |
| T3 | Specify the write protocol (B2, B7, B18): file identity, create/unlink/rename/truncate/chmod/symlink, fsync/close, pin updates | design | T2 | 1 day |
| T4 | Specify snapshot consistency (B8): quiesce or copy-then-hash, per-workspace serialisation, generation counters, close semantics | design | T3 | 0.5 day |
| T5 | Custody lifecycle (B9): acks as GC roots, `retained_until_ms` against retention, renewal, return path, batching | design | — | 1 day |
| T6 | Epoch rules at depth ≥ 2 and mid-tier push admission (B11) | design | — | 0.5 day |
| T7 | Offline admission expiry (B4) and rewrite AC17 | decision + edit | T5 | 2 hours |
| T8 | Pins and holds (B10, B18): bidi or `SetPins`; hold relay or scoped claim | design | T5 | 0.5 day |
| T9 | Merge rules (B16): one invariant, one AC, `BOOKMARK_CONFLICT` in the taxonomy | edit | T1 | 2 hours |
| T10 | E1′ (B5): define the manifest record, close the band, drop tier-2 catch-up from the box | edit | T1 | 3 hours |
| T11 | Reading guide and glossary order (B17) | edit | T1 | 1 hour |
| T12 | Delete the superseded ADR; correct Appendix C's description of it | operator + edit | — | minutes |

**Order.** T1 and T12 first: a day of editing with no decisions, and every contradiction the reviewers found disappears. Then T2 alone, because it decides what a pinned read is. T3–T8 are one coherent pass over the write path and the custody lifecycle and should be done together. T9–T11 fold into whatever revision comes out of that.

**What not to do.** Do not ratify anything, and do not start E1′, until T1 is done: the contradictions land in exactly the sections the operator is asked to approve.

## Appendix — reviewer artifacts

| Model | Artifact id |
|---|---|
| kimi-k3 | `c870dfbc-3db4-4277-8a4b-6a85ed3a1a23` |
| glm-5.3 | `b8d15ba5-194e-4615-8bec-b46c6a8aa257` |
| deepseek-v4.1-flash | `3e44ff01-72e7-40e5-92e0-4a4aea796554` |

Retained under `~/.pi/agent/sessions/--home-bogdan-work-google-jj--/subagent-artifacts/`.
