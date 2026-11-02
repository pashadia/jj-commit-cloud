I would use these questions to turn the proposal into an explicit contract: **what the system preserves, when that state becomes durable, who may advance it, and what happens when something fails.**

The **★ questions should be answered first** because they can change the architecture substantially. For numerical questions, use concrete targets—“restore a 2 GB project within 30 seconds”—rather than “fast” or “seamless.”

One clarification to my previous proposal: `jj-bundle-v1` was a placeholder for a **custom capture-and-restore adapter**. Its ability to preserve the required jj state must be demonstrated with a prototype.

Start with the experience you want users to be able to rely on.

1. **★ What exactly must be present after the user clicks “Resume” on another computer?**

   Consider a session with modified code, three agent conversations, an unsaved editor buffer, a running test, and a local database. Which must survive?

   **Clarifies:** The unit of recovery.\
   **Architectural impact:** Files and repository history require repository synchronization. Conversations and plans require agent adapters. Unsaved buffers require editor integration. Databases need appropriate capture mechanisms. Continuing running processes introduces execution infrastructure.

2. **Does “continue at any point” mean every jj operation, every agent step, every saved edit, or selected checkpoints?**

   **Clarifies:** Whether the product provides convenient handoff, detailed historical debugging, or continuous recovery.

   **Architectural impact:** Preserving every event requires reliable event capture and retention even when uploads are batched. Periodic checkpoints simplify capture and storage but omit intermediate states. A useful compromise could preserve frequent recent checkpoints and selected older milestones.

3. **★ If the computer suddenly dies while connected, how much recent work may be missing elsewhere?**

   Ask separately about work that the UI already called synchronized and work still pending upload.

   **Clarifies:** The acceptable recovery-point gap.

   **Architectural impact:** A seconds-level target favors frequent capture and incremental background uploads. A minutes-level target permits simpler batching. Guaranteeing that every local change is already remotely durable would require tying acknowledgment of those changes to the network, which affects latency and offline behavior.

4. **★ How long may switching take on an already-used computer versus a completely new computer?**

   For example: five seconds to confirm handoff, fifteen seconds to reopen a warm workspace, and two minutes to prepare a new machine.

   **Clarifies:** Separate targets for upload completion, code availability, and environment readiness.

   **Architectural impact:** Tight targets may require prefetching, local caches, selective restoration, and prebuilt environments. More relaxed targets make complete checkpoint bundles and environment reconstruction more practical.

5. **★ When the laptop shuts down, must its agents keep working or simply resume later?**

   **Clarifies:** Whether the product preserves task state or uninterrupted execution.

   **Architectural impact:** Resume-later fits local daemons and checkpoints. Keep-working requires a remote worker or another always-on computer, plus scheduling, credentials, compute accounting, and execution ownership. This is a major expansion of the proposed service.

6. **Must users explicitly prepare to switch, or should closing the lid normally be sufficient?**

   **Clarifies:** Whether handoff is an explicit operation or a continuously maintained condition.

   **Architectural impact:** Explicit preparation can pause managed writers and wait for publication. Automatic handoff relies on frequent background synchronization and clear pending-state indicators. Shutdown hooks alone cannot guarantee a final upload because power loss or suspension can interrupt them.

Next, establish what a session represents and how concurrent work should behave.

7. **Is this initially a personal product, or can teams and organizations own and share sessions?**

   **Clarifies:** Ownership and the authorization boundary.

   **Architectural impact:** Personal sessions support a simpler account-scoped model. Organizational ownership requires membership, roles, offboarding, administrative recovery, and audit history. This affects database keys, encryption boundaries, and access checks from the beginning.

8. **What defines a session: one agent conversation, one feature, one repository, or a collection of workspaces?**

   Consider a feature that starts in one repository and later expands into three.

   **Clarifies:** The object users discover, name, restore, and share.

   **Architectural impact:** Feature-oriented sessions need stable identities and versioned membership. Conversation-oriented sessions depend more heavily on agent tooling. Repository-oriented sessions simplify storage but make cross-repository work harder to present coherently.

9. **Can two sessions share the same underlying jj repository, and should changes in one affect the other?**

   **Clarifies:** The intended isolation between activities.

   **Architectural impact:** Shared repositories reduce duplication but can share repository history and interact through rewrites and workspace positions. Independent repositories improve isolation at the cost of more local storage and explicit integration. The checkpoint model must distinguish repository state from session membership.

10. **★ May the user intentionally run agents on two computers within the same session?**

    For example, the desktop runs tests while the laptop modifies a different workspace.

    **Clarifies:** The correct scope of concurrency control.

    **Architectural impact:** A single session-wide writer lease may block legitimate parallel work. Ownership may instead belong to an agent run, workspace, or continuation. The session then aggregates independently advancing components, with coordination where they share repository state.

11. **When computer A continues offline while B resumes, what should happen when A reconnects?**

    Should the system preserve two continuations, automatically combine compatible changes, or ask the user to select a preferred continuation?

    **Clarifies:** The conflict-resolution contract.

    **Architectural impact:** Preserving named continuations is comparatively simple and predictable. Automatic reconciliation needs separate policies for code, workspace positions, agent conversations, and pending actions. Successfully merging code does not establish that two agents’ plans can also be merged.

12. **How long must offline work remain useful, and what may agents do while offline?**

    Distinguish editing files, running local tools, making external changes, and claiming ownership of shared work.

    **Clarifies:** The availability promised without the service.

    **Architectural impact:** Long offline periods require substantial local retention and resumable uploads. Exclusive shared ownership cannot be newly established without coordination. A lease can restrict server publication, but it cannot physically prevent arbitrary local edits or actions by disconnected processes.

The next questions determine whether checkpoint capture is technically achievable at the promised fidelity.

13. **★ Which jj properties must survive exactly: file contents, change identities, bookmarks, conflicts, or the full operation history with usable undo?**

    **Clarifies:** Repository recovery fidelity.

    **Architectural impact:** Current content and selected revisions permit a smaller transport. Preserving native operation history requires capturing the relevant repository views and all objects they depend on. Jj’s operation log records repository views, including references and workspace working-copy positions, so it represents additional state beyond checked-out files. [Jujutsu operation log](https://docs.jj-vcs.dev/latest/operation-log/)

14. **★ Can the daemon coordinate every writer, or must it coexist with arbitrary editors, terminals, Git commands, and background generators?**

    **Clarifies:** Whether a reliable pause-and-capture boundary is enforceable.

    **Architectural impact:** Managed agents can cooperate with capture barriers. Unmanaged writers require detection and retries, filesystem snapshot support where appropriate, or a weaker consistency guarantee. Jj’s documentation also identifies caveats around synchronizing repository copies, especially with the Git backend; transparent directory replication needs validation. [Jujutsu concurrency documentation](https://docs.jj-vcs.dev/latest/technical/concurrency/)

15. **Must a checkpoint capture a logically complete agent step, or is a recoverable intermediate state acceptable?**

    Suppose an agent changes an API schema in one repository and then updates a client in another.

    **Clarifies:** Whether “consistent” means readable repository state, one coordinated capture boundary, or a completed application-level change.

    **Architectural impact:** A complete-step guarantee requires agent cooperation and explicit boundaries. Capturing independent components is simpler but may preserve an unfinished change. A manifest listing both repositories does not itself make their contents logically consistent.

16. **What should trigger capture, and how much may capture interfere with active work?**

    Candidates include jj operations, completed agent actions, editor saves, periodic timers, and explicit handoff.

    **Clarifies:** The tradeoff between coverage, latency, and workstation overhead.

    **Architectural impact:** Command-based capture needs reliable integration with command execution. Editor-based capture needs plugins. Timers are broadly compatible but leave gaps. A hybrid design can debounce frequent edits while preserving important agent boundaries and prioritizing handoff.

17. **Which state outside tracked source files must move with the session?**

    Classify ignored fixtures, generated assets, large binaries, unsaved buffers, terminal history, and caches as required, reconstructible, optional, or excluded.

    **Clarifies:** The actual checkpoint contents.

    **Architectural impact:** Each required category adds capture and restoration behavior. Repository tracking rules alone are insufficient: jj snapshots working-copy changes during most commands, and ignored files are not automatically tracked. Unsaved editor buffers require a separate integration. [Jujutsu working-copy documentation](https://docs.jj-vcs.dev/latest/working-copy/)

18. **Can the first release constrain jj versions and repository layouts?**

    For example, can it support a tested version range and specific colocated or non-colocated layouts?

    **Clarifies:** The compatibility burden you are willing to own.

    **Architectural impact:** Narrow support makes a versioned adapter feasible sooner. Broad support requires a compatibility matrix, migration paths, and more restoration tests. Jj separates commit storage, operation storage, operation heads, indexes, and working-copy handling; the adapter must account for the required components. [Jujutsu architecture](https://docs.jj-vcs.dev/latest/technical/architecture/)

Agent continuity and environment portability need their own answers.

19. **★ Which agents must be supported, and can they actually export and resume their state?**

    Is reopening the exact native conversation required, or is starting a new conversation with the transcript, plan, and remaining work acceptable?

    **Clarifies:** Exact agent restoration versus reconstructed task continuity.

    **Architectural impact:** Exact restoration requires supported interfaces and compatible agent versions. Reconstruction can use a common session model but needs summaries, provenance, and a clear indication of what was restored. This should be tested against the actual agents before promising support.

20. **What should happen when an interrupted agent action may already have succeeded?**

    Example: a deployment request was accepted, but the computer died before recording the response.

    **Clarifies:** Recovery semantics for external side effects.

    **Architectural impact:** Reliable automatic recovery needs durable action identifiers, intent/result records, idempotency where supported, and action-specific reconciliation. Otherwise, the resumed agent must pause for resolution. Replaying a transcript cannot safely establish whether an external action already occurred.

21. **Which agent permissions and approvals remain valid after switching computers or restoring an old checkpoint?**

    **Clarifies:** Whether authorization belongs to the user, device, session, or individual action.

    **Architectural impact:** Approvals may need to reference specific resources, action parameters, and expiration conditions. Historical checkpoints must distinguish previously completed actions from currently authorized ones. Restoring a checkpoint should not accidentally reactivate consumed approvals or obsolete credentials.

22. **★ Which operating-system and CPU combinations must work, and must the restored project run immediately?**

    For example, macOS ARM to Linux x86, Windows to Linux, or two similar Macs.

    **Clarifies:** Whether portability covers source editing or executable development environments.

    **Architectural impact:** Broad portability requires path mapping, filesystem compatibility checks, rebuilding native dependencies, and reproducible environment definitions. A narrower initial matrix reduces complexity. Projects tied to particular hardware or platforms may need remote execution.

23. **What should happen to local databases, containers, services, ports, and external development resources?**

    **Clarifies:** Which dependencies are copied, recreated, or reconnected.

    **Architectural impact:** Local persistent data may require application-aware snapshots. Reproducible services need environment recipes and startup orchestration. Reusing external resources requires stable identities and coordination so two resumed sessions do not unexpectedly share or overwrite the same development data.

24. **How should secrets become available on the destination computer?**

    Consider API keys, SSH credentials, package-registry access, and environment variables.

    **Clarifies:** The boundary between portable project configuration and device authorization.

    **Architectural impact:** Reauthentication is simpler but adds setup steps. A secret provider enables smoother restoration but requires access policies and credential delivery. Copying credentials inside ordinary checkpoints couples secret exposure and rotation to potentially long-lived history.

Now define precisely what the authoritative service guarantees.

25. **★ Which failures must an acknowledged checkpoint survive?**

    Choose explicitly among one process, one server, one availability zone, and an entire region.

    **Clarifies:** The meaning of “Safe to switch.”

    **Architectural impact:** Stronger failure tolerance changes placement, replication, acknowledgment latency, and cost. Metadata and payloads must satisfy the same guarantee. Asynchronous regional replication has a potential loss window; a zero-loss regional guarantee requires a publication protocol that accounts for regional durability before acknowledgment.

26. **During an authority outage, must users only continue locally, or also restore on a new computer and transfer ownership?**

    **Clarifies:** Availability requirements for different operations.

    **Architectural impact:** Local editing and checkpoint queues can continue independently. New-device restoration needs accessible catalogs, payloads, and authorization. Ownership transfer requires an available authority or controlled failover. Independent servers must not grant conflicting exclusive ownership during a partition.

27. **What evidence must exist before a checkpoint is described as recoverable?**

    Is it sufficient that uploads completed, or must the system verify object references, decode repository state, or perform a restoration?

    **Clarifies:** The validation behind the user-facing guarantee.

    **Architectural impact:** Checksums and reference validation can run on every publication. Actual restore tests cost more and may run selectively or asynchronously. The product should distinguish storage durability from demonstrated restoration compatibility, particularly when introducing new adapter versions.

28. **When restoring, may the destination already contain unsynchronized work for the same session?**

    Also decide whether restoring an old checkpoint creates a new continuation or moves the current continuation backward.

    **Clarifies:** Whether restoration is reconstruction, reconciliation, or rollback.

    **Architectural impact:** Fresh-directory restoration is easier to make transactional. Updating existing directories requires detecting local changes, preserving them, coordinating active agents, and supporting rollback. Creating a new continuation from an old checkpoint preserves subsequent history naturally.

29. **How long must checkpoints remain restorable, and what does deletion mean?**

    Distinguish removing a session from the UI, expiring recovery points, and removing retained content.

    **Clarifies:** Retention and erasure semantics.

    **Architectural impact:** Garbage collection must account for shared objects and incremental dependencies. A newer repository bundle may still contain historical content from deleted checkpoints. Removing manifest records therefore does not necessarily remove the underlying history; replicas and backups need explicit retention policies too.

30. **Which mistakes must the system recover from beyond infrastructure failure?**

    Examples include a faulty client publishing bad state, accidental deletion, a broken adapter release, and an administrative mistake.

    **Clarifies:** The recovery scope beyond availability.

    **Architectural impact:** Replication alone can propagate mistakes. Recovery may require immutable historical manifests, delayed deletion, independently retained backups, adapter rollback, and recovery tooling. Metadata and payload recovery must be coordinated so restored catalogs do not reference objects already deleted.

Trust and deployment choices affect the storage format and integrations early.

31. **★ May the service operator read source code and agent conversations?**

    Also decide whether server-side search, previews, validation, and AI assistance are required.

    **Clarifies:** The trust boundary.

    **Architectural impact:** Server-readable encrypted storage permits those server capabilities. End-to-end encryption moves interpretation toward clients or explicitly trusted workers and introduces device-key enrollment, recovery, sharing, and rotation. This choice affects manifests, indexing, deduplication, and remote execution.

32. **At what granularity can access differ: organization, project, session, repository, or transcript?**

    For example, may a collaborator see code while being unable to read private agent conversations?

    **Clarifies:** Authorization granularity.

    **Architectural impact:** Fine-grained permissions require separately addressable payloads and access checks. A single opaque session bundle is awkward if its components have different readers. Storage namespaces, encryption keys, caching, and download authorization must follow the chosen boundaries.

33. **What should enrolling or revoking a device guarantee?**

    Does revocation block future synchronization, invalidate agent credentials, or also attempt to protect previously downloaded data?

    **Clarifies:** Device trust and credential lifecycle.

    **Architectural impact:** Per-device credentials support targeted revocation. Short-lived access tokens limit continued server access. Local data protection needs separate encryption and key management; server revocation cannot recall plaintext already downloaded. Tool credentials may need independent revocation.

34. **What may execute automatically when a checkpoint is restored?**

    Consider setup scripts, dependency installation, development containers, and resumed agent tools.

    **Clarifies:** Whether restoring data also authorizes execution.

    **Architectural impact:** Automatic execution improves convenience but requires a defined trust model and isolation. Separating materialization from execution supports inspection before activation. Shared sessions and organization-managed environments may need different execution policies.

35. **Will the service be hosted by you, self-hosted by customers, or support both?**

    Include requirements about storage regions and customer-controlled storage.

    **Clarifies:** Deployment and operational ownership.

    **Architectural impact:** One hosted environment permits tighter assumptions about identity, storage behavior, and upgrades. Self-hosting requires packaging, migrations, diagnostics, and supported infrastructure combinations. Supporting both does not inherently require federation; each installation can remain its own authority.

Finally, quantify the workload and establish how the product remains understandable and operable.

36. **What does a representative workload look like, and what is the largest supported workload?**

    Measure repository size, changed bytes per minute, file count, workspaces, concurrent agents, transcript growth, and checkpoint rate.

    **Clarifies:** What dominates resource consumption.

    **Architectural impact:** Large histories favor deduplication; high churn favors incremental transfer; many tiny files stress scanning and metadata; many agents increase event and coordination volume. These measurements determine whether complete bundles are viable even for the first release.

37. **What resource budget may the daemon consume while the user works?**

    Specify acceptable CPU, disk I/O, memory, battery impact, and temporary disk usage.

    **Clarifies:** The cost the local experience can tolerate.

    **Architectural impact:** Tight budgets favor incremental scanning, adaptive scheduling, and deferred compression. Aggressive checkpoint frequency can conflict with battery life and responsiveness. Capture latency should be measured while realistic builds and agents are running.

38. **How should synchronization behave on slow, metered, or intermittent networks?**

    Should the latest recoverable state take priority over uploading every intermediate checkpoint?

    **Clarifies:** Upload scheduling and the relationship between freshness and historical completeness.

    **Architectural impact:** Prioritizing the latest state improves handoff readiness but may delay history availability. Strict ordered uploads can create a long backlog. Resumable transfer, dependency-aware scheduling, bandwidth controls, and separate retention of pending local history may be necessary.

39. **What should happen when local disk space or the server storage quota runs out?**

    **Clarifies:** Whether capacity limits can block development, checkpointing, or only synchronization.

    **Architectural impact:** The daemon needs explicit behavior for queue limits and reserved working space. Possible policies include pausing capture, pruning eligible history, or continuing with a visible reduced guarantee. Unpublished work must be distinguishable from safely uploaded material when reclaiming space.

40. **What must the user be able to understand from the history view?**

    Examples: “Which agent introduced this change?”, “What happened before the tests failed?”, and “Which computer has my latest work?”

    **Clarifies:** The tracking experience.

    **Architectural impact:** A list of checkpoint timestamps is insufficient for causal inspection. Record device identity, agent run, triggering action, repository revisions, and test results linked to the exact state tested. Searchable explanations need structured events and indexes.

41. **What information is needed to diagnose a failed or confusing switch?**

    For example: the destination appears stale, an agent resumes twice, or a checkpoint exists but cannot restore.

    **Clarifies:** Observability and support requirements.

    **Architectural impact:** Correlation identifiers should connect capture, upload, publication, lease changes, and restore attempts. Metrics should expose synchronization lag and restore failures. Diagnostics should distinguish operational metadata from potentially sensitive code and transcripts.

42. **Must users recover their work without the service, or migrate it to another provider?**

    **Clarifies:** Portability and dependence on the authority.

    **Architectural impact:** Independent recovery requires a documented export format, available decryption material where relevant, and a restoration tool that works without the API. A database containing the only interpretation of otherwise opaque payloads makes migration and offline recovery harder.

43. **What monthly cost per active user must the system support, under which workload?**

    Include storage, historical versions, transfer, validation, backups, and any remote execution.

    **Clarifies:** The economic limits of the product promises.

    **Architectural impact:** Low fixed-price plans may need bounded retention, artifact policies, deduplication, and quotas. Usage-based pricing needs accurate metering. The cost model should include repeated restoration and high-churn agents, not just stored repository size.

44. **★ What can the team realistically build and maintain for the first release?**

    Identify team capacity, delivery time, and the acceptable number of operating systems, jj versions, agents, and deployment modes.

    **Clarifies:** The sustainable initial scope.

    **Architectural impact:** A narrow compatibility matrix can make the core recovery guarantee achievable. Supporting many combinations multiplies integration and testing work. This answer should determine which adapters and environments ship first, and whether incremental transport is essential immediately.

45. **What concrete evidence will qualify the first release as reliable enough to trust with ongoing work?**

    **Clarifies:** The acceptance criteria for the architecture.

    **Architectural impact:** Define tests around observable guarantees: recover after power loss during capture, retry publication after a lost acknowledgment, preserve offline divergence, restore across supported machines, and recover after an infrastructure failure. These tests drive transaction boundaries, idempotency, compatibility checks, and recovery tooling.

Several answers should come from experiments rather than preference:

| Experiment                                                                                           | What it should establish                                                      | Decision it informs                                    |
| ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------ |
| Restore a jj repository containing rewrites, conflicts, multiple workspaces, and retained operations | Which native properties survive relocation and supported version changes      | Repository adapter and fidelity promise                |
| Capture while managed and unmanaged processes modify files                                           | Which consistency guarantees are actually enforceable                         | Writer coordination and supported integrations         |
| Disconnect A, resume on B, then reconnect A                                                          | Whether both histories and agent states remain understandable and recoverable | Ownership scope and divergence model                   |
| Measure capture, upload, and restore on representative projects and slow connections                 | Whether latency and workstation budgets are achievable                        | Bundle format, incrementality, caching, and scheduling |
| Kill processes at each publication stage and simulate a lost response                                | Whether retries preserve one durable result without losing work               | Publication protocol and recovery behavior             |

For each answer, record **the required behavior, one concrete example, a measurable acceptance condition, and whether it is required in the first release**. That gives you an architectural decision record you can implement and test, rather than a collection of preferences.
