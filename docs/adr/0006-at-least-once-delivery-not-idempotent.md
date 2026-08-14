# ADR-0006: Crash-safe at-least-once delivery, one retry, deliberately not idempotent

**Status:** Accepted (2026-06, from the project's inception; reconstructed 2026-08-13)

> At-least-once delivery is a standing property of the plain-file queue (ADR-0001),
> recorded in the README "Caveats". The recovery machinery was hardened over time —
> the reaper is longstanding; the janitor was added by PR #76 on 2026-08-09. The
> date above marks the property; the dated evidence for the hardening is cited inline.

## Context

The queue is plain files with atomic-rename claims (ADR-0001) and no broker to
hold delivery state. A worker can die at any point in a job's lifecycle, so the
system has to decide what "crash recovery" means: is the guarantee that a job runs
*at most once*, *exactly once*, or *at least once*? The two failure modes are
asymmetric. A **lost job** is invisible and bad — work silently never happens. A
**duplicated job** is cheap and human-visible — at worst a worker that died after
opening a PR re-runs and opens a second PR, which a reviewer immediately sees in
the "Open agent PRs" queue and closes.

## Decision

**Deliver at-least-once, retry once, and do not make jobs idempotent.** The design
optimizes against the expensive failure (lost work) and accepts the cheap one
(a duplicate PR), because a duplicate is bounded, visible, and easy to reconcile,
whereas a lost job is none of those.

Crash-safety comes from a heartbeat + reaper + janitor chain, not from delivery
acknowledgements:

- **Heartbeat.** Each worker writes `workers/<host>.alive` every 30s
  (`claude-heartbeat.timer`, `OnUnitActiveSec=30s`).
- **Reaper.** `process-inbox` reaps jobs whose owner has gone stale (>90s),
  requeues them **once** (`.retry`), then fails them if stranded again.
- **Janitor (PR #76, 2026-08-09).** The reaper iterates only `processing/*.owner`
  files, so it is structurally blind to an *ownerless* processing entry — a state
  that is reachable when `run-job` clears the owner as its last step even though the
  preceding terminal `mv` silently failed under `|| true` (a transient NAS error),
  stranding a completed job forever (issue #73, a month-old orphan). The janitor runs
  **before** the reaper and files such an entry terminally **only with completion
  proof** (`logs/<runid>.meta` exists, written only at run-job's very end) and no live
  owner, routing to done/failed per the recorded exit code. Janitor-before-reap
  matters: a completed-but-dead-owner entry would otherwise be requeued and
  double-run.

The queue core is **CI-tested**: since issue #61, the bats harness (`test/queue.bats`,
inbox faked on tmpfs; landed in PR #62) covers claim-by-rename races, crash-mid-job
recovery, at-least-once delivery, and write-then-rename discipline on every PR.

## Alternatives

### Recorded at the time

- **Repo-side idempotency** (before opening a PR, check whether a branch/PR already
  exists for this job) — **named and deliberately deferred.** The README "Caveats"
  records it explicitly: "Repo-side idempotency (does a branch/PR already exist?) is
  the fix when wanted." It is the recognized path to exactly-once *effects*; it was
  not built because the duplicate-PR cost is low and human-visible, so the work
  hasn't earned its place yet.
- **Cap retries at one vs. retry indefinitely.** Chosen: one retry, then fail. A job
  that fails twice is stranded deliberately (surfaced as a failure) rather than
  looped forever, which would risk repeated side effects from a genuinely poisoned
  job.

### Retrospective — not considered at the time

- **Exactly-once delivery via a broker with acks / visibility timeouts** — *worse
  here.* It would eliminate the duplicate-PR window, but only by adding the very
  broker ADR-0001 refuses, and it would trade a cheap visible failure (a second PR)
  for an expensive operational surface (a stateful queue service to run and page on).
  The asymmetry of the two failure modes is what makes at-least-once the right call;
  a broker inverts the cost without improving the outcome that matters. Worse.
- **At-most-once** (never retry; a crashed job is simply dropped) — *worse.* It makes
  the queue trivially idempotent, but it optimizes against the *cheap* failure and
  accepts the *expensive* one — silently losing work — which is exactly backwards for
  this fleet. Worse.

## Consequences

- **No job is silently lost** to a worker crash: the heartbeat/reaper/janitor chain
  recovers stranded and orphaned entries, and every claim/recovery path is exercised
  by CI.
- **A duplicate PR is possible and accepted.** A worker that dies after opening a PR
  but before filing the result will re-run on its one retry and may open a second PR.
  This is bounded (capped at one retry) and visible (the review queue), and closing
  the second PR is the reconciliation.
- **The idempotency boundary is documented, not hidden.** The README states it as a
  deliberate residual boundary alongside the concurrent-`memory.md`-append and
  cross-host-SMB-rename caveats — so the "at-least-once, not idempotent" contract is
  something a dispatcher can rely on rather than be surprised by.
- If duplicate PRs ever become more than a minor annoyance, the deferred repo-side
  idempotency check is the pre-identified fix — this ADR is where that trade would be
  revisited.
