# ADR-0007: Observability is log-event-native; Pushgateway explicitly rejected

**Status:** Accepted (2026-06-15; reconstructed 2026-08-13)

> Dated to the roadmap research pass of 2026-06-15 (`docs/roadmap.md` § "Live job
> radiator"), which is where the Pushgateway rejection and the log-native posture
> are argued from primary sources. The emit path (`bin/cr-emit` → Loki) is the
> running expression of that decision.

## Context

Each job needs to emit operational signal — cost, turns, duration, status, repo,
`pr_url`, worker — so the fleet is observable (spend, success rate, throughput,
duration, and open PRs awaiting review). The stack is already Loki-centric:
workers POST JSON to the lab Alloy Loki receiver → Grafana Cloud. The open
question the roadmap examined was whether to introduce a Prometheus metrics path
(and specifically a Pushgateway) for per-job metrics, or to stay log-native.

## Decision

**Observability is log-event-native.** Every job emits a `job_complete` event as
a JSON log line to the Alloy Loki receiver; Grafana renders spend, success rate,
throughput, duration, and the "open agent PRs awaiting review" panel from that
stream. No Prometheus and **no Pushgateway** are introduced.

**A hard cardinality rule accompanies it:** high-cardinality fields — `runid` and
`pr_url` — live **in the JSON log body, never as Loki stream labels**. "Latest
state per runid" is derived at query time. This is the Loki analogue of avoiding
the Pushgateway stale-series trap, and it is exactly what `bin/cr-emit` does today.

The rejection is argued from primary sources in `docs/roadmap.md` (research pass
2026-06-15, adversarially verified):

- **Pushgateway is the wrong tool.** Prometheus' own docs say the only valid use is
  capturing the outcome of a service-level batch job — one aggregate, not per-runid.
  For a fleet it becomes "a single point of failure and a potential bottleneck," and
  it "never forgets series … and will expose them to Prometheus forever unless
  manually deleted." Per-runid pushes would pile up stale series forever — the exact
  opposite of "show live jobs."
- **`statsd_exporter` is the less-wrong Prometheus path** (it has a per-metric TTL)
  *if* a Prometheus metric were ever independently wanted — but it "adds a service for
  zero UX gain" over the Loki path that already exists. Recorded as available, not
  adopted.

## Alternatives

### Recorded at the time

- **Prometheus Pushgateway for per-job metrics** — examined in detail and **rejected**
  as a settled anti-pattern (no TTL, stale-series accumulation, SPOF/bottleneck for a
  fleet). This is the headline rejection of the decision.
- **`statsd_exporter` (push-to-scrape bridge with TTL) → Prometheus** — the "less
  wrong" Prometheus option, kept on the shelf: only worth it if a Prometheus metric is
  ever independently wanted, and even then it adds a service for no UX gain over Loki.
  The roadmap's recommendation matrix lists it as "Medium effort, no UX gain here."
- **Bespoke SSE/WebSocket page** — considered for sub-second "glow" latency, deferred
  as high-effort and unjustified for jobs that run minutes; a few-second Grafana
  auto-refresh is adequate.

### Retrospective — not considered at the time

- **OpenTelemetry traces per job** (spans for claim → checkout → run → PR) — *lateral,
  arguably better for one narrow goal, worse on cost.* Tracing would model a job's
  lifecycle more richly than discrete log events and give first-class latency
  breakdowns. But it introduces a collector and a tracing backend for a workload whose
  "trace" is a handful of coarse phases already legible as log events, and the fleet's
  actual questions (spend, success rate, open-PR queue) are aggregate, not
  span-shaped. Better for deep single-job latency analysis; worse on operational
  weight for what's actually asked. Lateral overall.
- **Per-`runid` Loki labels** (label each stream by runid/pr_url for easy filtering)
  — *worse, and explicitly guarded against.* It would make some queries trivially
  filterable, but it explodes stream cardinality — the Loki analogue of the very
  Pushgateway stale-series trap this decision rejects. The chosen posture (IDs in the
  body, derive per-runid at query time) is the deliberate opposite. Worse.

## Consequences

- **One signal path, zero new services.** The metrics story rides the Loki stream the
  fleet already POSTs to; there is no Pushgateway or Prometheus to run, secure, or page
  on for per-job observability.
- **Cardinality stays bounded** by rule: because `runid`/`pr_url` never become labels,
  the stream count doesn't grow with job count — the failure mode the Pushgateway
  rejection was about is designed out on the Loki side too.
- **The dashboard is the review front door.** The same log-native events drive the
  "open agent PRs awaiting review" panel (ADR-0002) — observability and the review
  queue are the same stream, not two systems.
- Adding a Prometheus metric later is *possible* but has a documented bar: it must
  clear "worth a new service for UX the Loki path doesn't already give," with
  `statsd_exporter` (TTL) as the pre-identified less-wrong path if that bar is ever met.
