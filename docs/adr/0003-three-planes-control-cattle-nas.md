# ADR-0003: Three planes — control / cattle workers / NAS artifacts

**Status:** Accepted (2026-06-15; reconstructed 2026-08-13)

> Dated to PR #2 (2026-06-15), the earliest change that makes the artifact plane
> load-bearing by moving per-job reasoning off worker disk onto the NAS. The
> plane separation itself is a standing invariant in `CLAUDE.md` and the README.

## Context

An agent fleet has three fundamentally different kinds of state, and conflating
them is how you end up with pets. Where work *originates* (a human or a cron
dropping a job spec) is not where work *runs* (a worker executing `claude -p`),
and neither is where the *durable results* live (the queue, transcripts,
registry, and per-project memory). If any durable state ends up on a worker's
local disk, that worker stops being interchangeable — rebuilding it loses data,
and you now have a pet to nurse.

The concrete pressure that forced this into the open: Claude Code writes each
job's full reasoning trajectory (assistant messages, thinking blocks, tool
calls/results) to the worker's local `~/.claude/projects/.../<session-id>.jsonl`
— ephemeral, scattered by working directory, keyed by session-id rather than
runid, and lost if the worker is rebuilt (PR #2, "Capture each job's full
reasoning transcript to the NAS").

## Decision

**The system is three deliberately separated planes** (named as such in the
README "How a job flows"):

- **Control plane** — where work originates. A laptop / cron / HA / a script is a
  thin client that drops job specs; it does prompt-engineering, not execution.
- **Worker plane** — N interchangeable worker LXCs, **cattle not pets**. The "hat"
  a worker wears is a field in the job, not the box's identity; there is no
  per-worker identity beyond hostname (used only as a metrics label and heartbeat
  filename).
- **Artifact plane** — the NAS: the job queue, the results, the project registry,
  and per-project memory. Durable and portable; survives any worker being rebuilt.

**Nothing durable lives on a worker.** PR #2 wired `run-job` to copy each job's
transcript to `logs/<runid>.transcript.jsonl` on the NAS and to record the
`session_id` in the `.meta` so the runid↔transcript link is explicit — making the
reasoning durable, portable, and joinable to the runid, "the same 'don't trap it
on a pet' principle as the rest of the system." PR #11 ("bake the live fleet
transcript shipper into the worker image", 2026-06-18) then baked the separate
Loki *transcript shipper* into the worker image, so a fresh or `pct clone`d worker
ships its reasoning stream to Grafana Cloud automatically — worker-side plumbing
kept out of any hand-run per-box step.

## Alternatives

### Recorded at the time

- **Leave transcripts on worker-local disk** (the pre-PR#2 status quo). Rejected
  in PR #2: local `.jsonl` files are ephemeral, session-id-keyed, and lost on
  rebuild — the opposite of the portability the rest of the system already has.
- **Vendor the transcript-shipper config into this repo.** Rejected in PR #11 in
  favor of cloning the canonical config from `homelab-observability` and
  self-syncing, to avoid a second copy that could drift — keeping observability
  logic in its home repo rather than baking project knowledge into the worker.

### Retrospective — not considered at the time

- **Sticky per-project workers** (pin each project to a dedicated box that keeps a
  warm checkout and local state) — *worse.* It would shave a little checkout cost
  and let a worker "specialize," but it recreates pets: durable state lands on a
  specific box, rebuilds lose it, and capacity can no longer be treated as a
  fungible pool. It directly contradicts the cattle invariant and the portable-context
  rule (`CLAUDE.md`: "Never bake project knowledge into a worker image"). The
  warm-but-reset clean checkout already captures the caching benefit without the
  pet cost. Worse.
- **A dedicated artifact service / object store in front of the NAS** (e.g. an S3
  gateway for transcripts and results) — *lateral, and premature here.* It would
  give real object semantics and lifecycle policies, but it adds a service to run
  for state that a plain SMB mount already holds durably and portably. It solves a
  scale problem this fleet doesn't have; it neither strengthens nor weakens the
  plane separation. Lateral.

## Consequences

- **Any worker can be rebuilt at any time** with zero data loss — the defining
  benefit of keeping the artifact plane on the NAS.
- **Portability is uniform:** transcripts, results, registry, and memory all reach
  any worker, so a job can run anywhere and its output is joinable by runid
  regardless of which box ran it.
- The rule generalizes: project conventions belong in the target repo's `CLAUDE.md`
  (reviewed, versioned), and cross-run learnings belong in `projects/<name>/memory.md`
  on the NAS — never baked into a worker image. This ADR is why.
- Because reasoning is durable and runid-keyed, a "drill into this job's reasoning"
  affordance (dashboard link to the transcript) is trivial to add later.
