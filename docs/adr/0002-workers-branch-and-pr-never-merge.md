# ADR-0002: Workers branch + PR and never merge

**Status:** Accepted (2026-06-16; reconstructed 2026-08-13)

## Context

The fleet exists to do directed work autonomously, but the trust model is that
**every change reaches `main` only through a human**. That property is not
theoretical — it was breached once, early, and the fix is what pinned it down.

PR #4 ("Never let a runner-bot PR auto-merge (override repo conventions)",
merged 2026-06-16) records the origin plainly: a dispatched agent working on
another repo (`homeassistant-config`) read that repo's `CLAUDE.md`, followed its
human-oriented "arm auto-merge" convention, and the PR it opened **auto-merged
unreviewed** — exactly what the bullpen model forbids. The convention that is
correct for human-driven work is wrong when the actor is the runner bot.

## Decision

**Workers branch and open a PR; they never merge.** Human review is a separate,
mandatory step. The decision is enforced in two layers, per PR #4:

1. **A standing prompt override.** `run-job`'s project-job prompt forbids arming
   auto-merge (`gh pr merge --auto`) and states that this **overrides any repo
   `CLAUDE.md` or fleet convention** that would enable it. Bot PRs are always left
   for a human.
2. **A belt-and-braces mechanism.** After every project job, `run-job` finds the
   PR the agent opened and runs `gh pr merge --disable-auto` on it — so even if an
   agent disobeys the prompt, the PR is disarmed, and because this runs at job-end
   (seconds) it normally beats CI going green.

Two later decisions reinforced it:

- **Issue #23** ("Enforce no-auto-merge review gate on fleet PRs; make 'Open
  agent PRs' the dispatch gate", 2026-06-20) made the Grafana **"Open agent PRs
  awaiting review"** panel the canonical review queue — the review front door, so
  the no-merge rule has a place where the waiting work is actually seen.
- **PR #70** ("docs: record the runner App's granted scopes", 2026-07-25) scoped
  the branch ruleset honestly: required status checks are matched by context
  *name*, so a PR that deletes a gating workflow can never merge (the context stops
  reporting and the PR holds at "Expected") — but a PR that keeps the job name while
  gutting the body still reports green. So the ruleset is *"a backstop against
  accidental self-sabotage, not a security boundary — the real backstop is that
  workers never merge and every agent PR is reviewed by a human."*

## Alternatives

### Recorded at the time

- **Trust each repo's own `CLAUDE.md` auto-merge convention.** This was the
  *status quo ante* — and it is exactly what caused the unreviewed auto-merge in
  PR #4's origin story. Rejected: a convention written for humans must not govern
  an autonomous actor.
- **Prompt override alone.** Considered insufficient on its own; PR #4 pairs it
  with the post-job `--disable-auto` mechanism precisely because a prompt is advisory
  and an agent can disobey it. Defense in depth, not a single instruction.

### Retrospective — not considered at the time

- **Auto-merge on green CI** (merge automatically once required checks pass) —
  *worse.* This is the standard convenience for human-authored automation, and it
  is the specific thing this ADR exists to forbid. Green CI proves the checks that
  exist passed; it does not prove the change is correct, safe, or wanted — and as
  PR #70 notes, an agent can keep a check's name while hollowing out its body. For
  an autonomous fleet, "reviewable" is the product; auto-merge trades it away. Worse.
- **A required second *agent* reviewer as the gate** (an LLM approves before merge)
  — *lateral, arguably worse.* It would add throughput and catch some classes of
  mistake, but it does not deliver the property this decision is about: that a
  *person* has read the diff and owns the merge. It could sit *alongside* human
  review as a pre-filter, but it cannot replace it without dissolving the trust
  model. Lateral as an add-on, worse as a substitute.

## Consequences

- **`main` is only ever advanced by a human.** This is the single constraint that
  keeps an autonomous fleet auditable: nothing it produces lands without someone
  reading the diff, checking the CI signal, and clicking merge.
- The **review queue is a first-class surface** (the Grafana "Open agent PRs"
  panel), not an afterthought — because if no-merge is the rule, the backlog of
  things awaiting a human has to be visible.
- The branch ruleset is understood as a **backstop, not a boundary.** Documentation
  (PR #70) states this honestly so nobody mistakes required checks for a security
  guarantee against a misbehaving agent.
- Every merged PR in this repo's history is, by construction, an agent PR a human
  signed off — the property is continuously re-proven rather than assumed.
