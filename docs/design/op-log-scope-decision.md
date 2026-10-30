# How much of the operation log must be shared?

**A decision brief. It contains no decisions — it asks for them.**

Status: open. Written because the answer is a product decision, not an
engineering one, and because three separate engineering questions are currently
blocked on it.

---

## 1. Why this document exists

We are building a system in which a jj repository lives behind a shared server,
and several machines — laptops, a shared office machine, a build server — work
on it. One question has never been settled by anyone with the authority to
settle it:

> **How much of each machine's local repository state must be visible to the
> other machines?**

Everything downstream depends on the answer: how much data the server stores,
how much bandwidth a developer consumes, what a colleague can see of your work
before you publish it, whether work continues when the server is down, what
"undo" means, and what support can investigate after an incident.

It is tempting to treat this as an implementation detail and let engineers pick
a sensible default. That is what has happened so far, and it is why the design
keeps stalling: each engineer assumes a different answer, and the answers are
not compatible.

---

## 2. What jj does today, and why it is the way it is

jj records every change to a repository as an **operation**. Editing a file,
moving a bookmark, creating a commit, rebasing — each is an operation. The
operation log is what makes `jj undo`, `jj op log` and recovery possible.

Two properties of that log create the difficulty.

### 2.1 The log is deliberately local

jj's own source says it plainly:

> "Operations and views are not meant to be exchanged between repos or users;
> they represent local state and history."
> — `core/src/op_store.rs:282-286`

This is not an oversight. It is why the log can contain anything, including
half-finished work and machine-specific details, without those becoming someone
else's problem.

### 2.2 Each operation points at a complete view

An operation does not record "this changed". It records the **whole state of the
repository's pointers** after the change — called a view — and the operation
points at it.

That has a consequence which is easy to miss and which shapes everything that
follows: **a view cannot be partly shared.** It is one object. If you share an
operation, you share all of its view, including the parts that only matter on
the machine where it was created.

### 2.3 Every field of a view

| # | Field | Type | What it holds |
|---|---|---|---|
| 1 | `head_ids` | set of commit ids | Every commit that is currently visible. At least one. |
| 2 | `local_bookmarks` | name → ref target | Local bookmark names and where they point. A target may be conflicted. |
| 3 | `local_tags` | name → ref target | Local tags, same shape. |
| 4 | `remote_views` | remote → {bookmarks, tags} | The last known position of each remote's bookmarks and tags, plus whether each is tracked. A memory of what a server said, not an authority. |
| 5 | `git_refs` | ref name → ref target | Mirrors of the underlying Git repository's refs. |
| 6 | `git_heads` | workspace → ref target | The commit each workspace's Git `HEAD` points at. |
| 7 | `wc_commit_ids` | workspace → commit id | The commit that each workspace has checked out. |

All seven are stored together, as one view, for every operation.

### 2.4 The view mixes three different kinds of thing

This is the root of the confusion, stated plainly:

- **Shared content pointers** — fields 1–3. Where the repository's history and
  named refs actually are. Other people would recognise these.
- **Mirrors of other systems** — fields 4–5. A local cache of what a remote or
  a Git repository last said. Useful to the machine that holds it, meaningless
  to anyone else.
- **Per-machine working state** — fields 6–7. Which commit *this* workspace is
  looking at. Only meaningful on the machine where that workspace lives.

A single operation typically changes one field from each group: you edit a file
(the working-copy commit, field 7, changes and a new commit appears, field 1),
and perhaps a bookmark moves (field 2). **The parts you might want to share and
the parts you certainly do not are welded together in the same object.**

---

## 3. The space between "mine" and "everyone's"

The two extremes are easy to describe.

- **Everything local.** Each machine has its own log. Sharing happens the way it
  does with Git: you push commits and bookmark positions somewhere, and others
  fetch them. Nothing else moves.
- **Everything shared.** One log at the server. Every operation from every
  machine goes up, comes down to everyone, and any client can point at any
  other client's head, workspace or snapshot. `jj op log` is the same
  everywhere.

Between them there is a wide range, and most real systems sit in the middle.
The rest of this document describes five positions on that range. They are
**not** implementation alternatives of one idea; they are different products.

```
  local only                                              fully shared
      │                                                        │
   ┌──┴──┐      ┌────────┐      ┌────────┐      ┌────────┐   ┌──┴──┐
   │  1  │──────│   2    │──────│   3    │──────│   4    │───│  5  │
   └─────┘      └────────┘      └────────┘      └────────┘   └─────┘
  today's       shared        + where each      + the        one log,
  jj            content       workspace is      history of   everyone
                and refs      (tips only)       what was     sees all
                                                published
```

---

## 4. The five positions

Each position says: what is shared, what a user gains, what it costs, and where
it stops working.

### Position 1 — Everything local

**What is shared:** nothing except what you deliberately push to a Git remote.

**What a user gains:** nothing new. This is jj as it exists today.

**What it costs:** nothing. No server state beyond a Git remote.

**Where it stops:** a colleague cannot see your work until you push, and even
then cannot see where your workspace is pointing, what you have not published,
or what you were doing ten minutes ago. Support cannot reconstruct what happened
on a machine that was lost.

**Who this suits:** teams that are happy with Git's collaboration model and want
the server to be a dumb store.

---

### Position 2 — Shared content and refs

**What is shared:** commits, file contents, and bookmark positions. The server
holds the repository; each machine keeps its own operation log.

**What a user gains:** push and fetch, but without a Git remote in the middle.
A colleague can see everything you have published, immediately, without you
running a separate synchronisation step.

**What it costs:** storage proportional to **published** work, not to how often
people save. An afternoon of typing that ends in one commit costs one commit.

**Where it stops:** nobody sees work in progress. If your laptop dies between
publishing, the unpublished work is gone. There is no shared history of saves,
so no cross-machine undo and no way to answer "what did this look like an hour
ago on that machine".

**This is roughly Git's model with a better server.** It is the cheapest
position that still feels collaborative.

---

### Position 3 — Shared content, refs, and where each workspace is

**What is shared:** everything in position 2, plus one small fact per workspace:
"the `dev` workspace on Alice's laptop is at commit X". The commit may be
unpublished.

**What a user gains:** you can see what colleagues are working on right now,
including work they have not published. You can point at their commit. If their
machine dies, the server knows which commit was checked out, so nothing is lost
that had been saved.

**What it costs:** a small record per workspace per change of commit — not per
file save. Roughly, one small message per handful of seconds while someone is
actively editing, per workspace. (Exact volume is an engineering measurement,
not an assumption.)

**What it exposes:** that a person is working, where, and on which commit. Not
the file contents unless they are also published.

**Where it stops:** you can see the current position but not the path that led
there. "How did this file get like this, one save at a time?" still cannot be
answered from the server.

**This is the smallest position that makes work-in-progress visible.** It is
also the first one where privacy becomes a real question rather than a
theoretical one.

---

### Position 4 — Shared observable history

**What is shared:** position 3, plus a record of every change that others could
see: a commit becoming reachable, a bookmark moving, a ref being deleted. Not
your private pointer moves, not the intermediate versions of a commit you were
still writing. Only what changed something someone else could have observed.

**What a user gains:** a shared history of published work — who published what,
in what order, and what the repository looked like at each step. Cross-machine
recovery becomes possible for published work. "What changed in this bookmark
yesterday?" is answerable without asking the person who changed it.

**What it costs:** a second log to maintain and to keep consistent with the
local one. Storage grows with publishing activity rather than with typing. More
machinery: two formats, two versions, a rule for reconciling them after a crash.

**Where it stops:** it still does not give you a shared history of *saves*. If
someone wants to know what a file looked like at 14:03 before it was committed,
positions 1–4 cannot tell them, because that intermediate state was never
shared.

**This is the first position that is genuinely a new capability** rather than a
cheaper way of doing something Git already does.

---

### Position 5 — One log, fully shared

**What is shared:** every operation, from every machine, including every save
and every working-copy pointer move. Every client holds the same log and can
reference any other client's head, workspace or snapshot, immediately.

**What a user gains:** a single, complete, consistent history of everything that
happened anywhere — every save, every pointer move, every ref change — visible
to everyone, with `jj undo` able to undo an action performed on another machine.

**What it costs:** the log grows at the aggregate rate at which people *save*,
not at which they publish. Every save from every workspace of every developer is
written to the server and delivered to every interested client. As a placeholder
estimate: an active developer saving once every few seconds for a working day
produces on the order of 10,000–30,000 operations a day, and each carries a full
view — a small object, but one per save, per person. Storage, delivery and
retention all scale with that number.

**What it exposes:** everything. Every save, every half-finished thought, every
machine name, every workspace. Privacy becomes a design constraint rather than a
footnote.

**Where it breaks:** it makes the server a hard dependency for local work. If
the server is unreachable, a developer cannot save in a way that other machines
will ever see. It also makes every concurrent action a potential merge of
repository state, including the per-machine parts — which are exactly the parts
that have no meaningful merge.

**This is the only position in which "any snapshot is immediately available with
all the local refs" is literally true.** It is also the most expensive and the
most invasive, by a wide margin.

---

### Modifiers that apply to any position

- **Retention.** Any shared history can be kept forever, or for a window, or
  until someone prunes it. Deciding *how long* is separate from deciding *what*
  is shared, but it decides what "the server has it" actually means.
- **Scoping.** Shared state can be visible to the whole organisation, to a
  team, or to named people. Scoping does not reduce storage; it reduces
  exposure.
- **Encryption.** Content can be encrypted at rest or end to end. End-to-end
  encryption and "the server can answer questions about history" are mutually
  exclusive.

---

## 5. Trade-offs, side by side

| | 1 local | 2 content+refs | 3 + tips | 4 + observable history | 5 full log |
|---|---|---|---|---|---|
| Colleagues see published work | after a push | yes | yes | yes | yes |
| Colleagues see work in progress | no | no | **yes** | yes | yes |
| Shared history of saves | no | no | no | no | **yes** |
| Undo someone else's action | no | no | no | partly | **yes** |
| Survives laptop loss | only published | only published | since last save | since last publish | since last save |
| Works when server is down | yes | mostly | mostly | reduced | **no** |
| Storage grows with | publishing | publishing | editing | publishing | **saving** |
| Privacy exposure | minimal | minimal | location + commit | + history | **everything** |
| New engineering | none | moderate | moderate | **substantial** | large |
| Answerable to "who changed this?" | no | partly | partly | yes | yes |

---

## 6. The questions we need answered

Each question is a product question. The parenthetical notes say which
positions answer "yes".

**Q1. Must a colleague be able to see your work in progress, before you
publish it?**
No → position 2. That you are working, and where → position 3. The content too
→ position 5. *(3, 4, 5)*

**Q2. Must someone be able to undo an action performed on a different machine?**
No → position 2 or 3. For published actions → position 4. For anything,
including saves → position 5. *(4 partly, 5 fully)*

**Q3. Is the history of intermediate saves a product feature — something a user
or support could ask for — or is published history enough?**
Enough → positions 1–4. Required → position 5 only. *(5)*

**Q4. If a laptop is lost, what is the maximum acceptable loss?**
Nothing published → positions 2–5. Nothing since the last save → positions 3
and 5. Nothing at all, including unsaved buffer contents → no position; that is
an editor problem. *(3, 5)*

**Q5. Must a developer be able to keep working when the server is unreachable?**
Yes → positions 1–4, with a local queue. No → position 5 is acceptable.
*(1–4)*

**Q6. Who may see that a person is working, on what, and when?**
Nobody → position 2. Their team → any position with scoping. Everyone → 3–5.
*(scoping decision, independent of position)*

**Q7. What storage growth per developer per day is acceptable?**
Storage proportional to publishing → positions 2 and 4. Proportional to typing
→ positions 3 and 5. *(this is the cost question; it usually decides the
argument)*

**Q8. Must an identifier seen on one machine resolve on another?**
For commits and bookmarks → position 2 onwards. For operation ids → position 5
only. *(2+, 5)*

**Q9. Is the operation log a user-facing and support-facing artifact, or purely
internal machinery?**
Internal → any position. Something support inspects after an incident → position
4 at least, position 5 for the full picture. *(4, 5)*

**Q10. How long must shared history be retained, and who may delete it?**
This does not choose a position, but it decides whether "the server has it"
means "forever" or "for a while", and it must be answered alongside Q1–Q9.

---

## 7. How answers combine

There is no position that satisfies every "yes". The combinations that occur in
practice:

| If the answers are… | The position is |
|---|---|
| "Collaboration is publishing; work in progress is private." | 2 |
| "We want to see what each other are doing, not read each other's drafts." | 3 |
| "We need an auditable shared history of what was published and by whom." | 4 |
| "We need a single complete history of everything, everywhere." | 5 |
| Mixed answers | Usually 3 or 4, with retention and scoping doing the rest |

---

## 8. What we are not asking

- **Not** asking to approve a design, a format, or a technology.
- **Not** asking about user interface, commands or naming.
- **Not** asking whether the system should exist. That is settled.
- **Only** asking: which of the five positions is the product, and what are the
  answers to Q1–Q10 that select it?

Until those are answered, any engineering choice on this subject is a guess, and
guesses here are expensive to reverse: the position determines the server's data
model, the client's protocol, the privacy story and the offline story, and none
of those can be swapped later without a migration.

---

## Appendix — where the facts in this document come from

- Operations and views are local state, not an exchange format:
  `core/src/op_store.rs:282-286`.
- A view is a complete snapshot, not a delta, and is stored as its own object
  referenced by the operation: `core/src/op_store.rs:170-200`, `:294-320`.
- The seven view fields, their types and meanings: `core/src/op_store.rs:172-194`.
- A bookmark or tag target may be conflicted, and is represented as a merge of
  candidate commits: `core/src/op_store.rs:63-64`.
- Remote views are a remembered last-seen state, not an authority:
  `docs/bookmarks.md:63-67`.
- The operation log is the mechanism behind undo and recovery:
  `docs/operation-log.md`.
