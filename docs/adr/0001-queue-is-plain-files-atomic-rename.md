# ADR-0001: The queue is plain files on the NAS; claims are atomic rename

**Status:** Accepted (2026-06, from the project's inception; reconstructed 2026-08-13)

> No single commit introduces this — it is a standing invariant recorded in
> `CLAUDE.md` (§ "Architecture invariants") and the README from the earliest
> history. The date above is the earliest firm evidence (the queue was already
> load-bearing when PR #2 landed on 2026-06-15).

## Context

The fleet needs a work queue that many interchangeable workers can pull from
without two of them processing the same job. The substrate available is a NAS
SMB share, bind-mounted to `/srv/jobs` on each worker. The whole point of the
system is to stay dependency-light (`jq`, `curl`, `openssl`, `git`, `gh`) and to
keep anything durable on the NAS rather than on a worker's local disk, so that
workers stay cattle — rebuildable at any time with nothing of value lost.

A job is just a file dropped into `inbox/`. Producers write to a `*.partial`
name and `rename` it into place; the poller skips `*.partial`/`*.tmp`, so a
half-written job is never read.

## Decision

**The queue is plain files on the shared NAS mount, and a claim is an atomic
`mv inbox/<job> → processing/<runid>`.** There is no message broker, no lock
service, and no database. Single-winner semantics come entirely from the
kernel's `rename` atomicity: exactly one worker's `mv` succeeds, the rest fail
and move on. The per-worker `flock` in `bin/process-inbox` is *local* sanity
only (it stops one worker racing itself) and is explicitly **not** cross-worker
coordination.

Two supporting choices fall out of this:

- **Workers are co-located on one host.** Because a single kernel arbitrates the
  `rename`, single-winner is guaranteed without depending on cross-*host* SMB
  rename semantics — which are deliberately left untested (see ADR-0006 and the
  README "Caveats"). The queue-core CI harness runs on tmpfs, so cross-client
  CIFS rename atomicity is unexercised by design.
- **Discovery is polling, not `inotify`.** `systemd/claude-inbox.timer` fires
  every 15s; its unit description calls it a "CIFS-safe trigger" and
  `bin/process-inbox` is annotated "flock-guarded (CIFS-safe; polled)". A short
  timer poll is chosen over a filesystem watch because a watch on a mounted SMB
  share does not reliably observe writes made by *other* clients — the very
  case that matters when jobs are dropped from elsewhere on the LAN.

## Alternatives

### Recorded at the time

- **Broker or lock service (kept out on purpose).** `CLAUDE.md` states the
  invariant as a prohibition — "Don't add a broker or a lock service. Single-winner
  comes from `mv inbox→processing` on the shared mount." The alternative of adding
  coordination infrastructure was considered and rejected as unearned complexity
  for a homelab fleet; the shared mount already provides the one primitive
  (atomic rename) the design needs.
- **`inotify`/filesystem watch instead of polling.** Rejected because a watch
  cannot see SMB writes originating from other hosts; polling a `*.partial`→rename
  drop-folder is the CIFS-safe equivalent and is what the timer implements.

### Retrospective — not considered at the time

- **Redis / RabbitMQ / SQS as the queue** — *worse here.* Any of these would give
  real queue semantics (acks, visibility timeouts, dead-letter), but each is a new
  stateful service to run, secure, back up, and monitor — precisely the operational
  weight this design refuses. The homelab doesn't earn a broker: the workload is a
  handful of minutes-long jobs, and the shared mount already provides atomic claims
  for free. A hosted queue (SQS) would also drag the on-prem fleet's control path
  into the cloud for no benefit. Lateral at best on correctness, clearly worse on
  operational cost.
- **GitHub Actions as the dispatcher** (jobs as `workflow_dispatch` / repo events)
  — *worse fit.* The artifacts a job produces and consumes — the clean checkout,
  the per-runid transcripts, the project memory — live on the NAS, not in a CI
  runner's ephemeral workspace. Bending the queue around Actions would mean shuttling
  those artifacts in and out of a system whose data model doesn't want them, and it
  would couple job dispatch to GitHub availability. Worse fit for a NAS-artifact
  fleet.

## Consequences

- The queue has **no operational surface of its own**: nothing to run, patch, or
  page on. Its correctness rests on one kernel primitive that is easy to reason
  about and cheap to test.
- **Co-location is load-bearing, not incidental.** Distributing workers across
  hosts would move the claim onto cross-client SMB rename semantics that the design
  has never validated. Any future multi-host expansion must revisit this ADR and the
  ADR-0006 boundary first.
- Producers **must** honor write-then-rename; any code path that drops a job and
  skips the `*.partial` step can expose a partial read. This is enforced by
  convention and by the queue-core bats harness (`test/queue.bats`), not by the
  filesystem.
- Because there is no broker to hold delivery state, at-least-once semantics and
  the heartbeat/reaper/janitor recovery path (ADR-0006) are what make the plain-file
  queue crash-safe.
