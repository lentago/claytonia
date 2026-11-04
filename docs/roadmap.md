# bullpen roadmap

Forward-looking work for the fleet. Each item records the **goal**, the **decision**
(and why), and a **concrete implementation sketch** mapped to real code, so a future
session — or a dispatched runner-bot — can pick it up without re-deriving the context.

Status legend: `proposed` → `researched` → `in-progress` → `shipped`.

---

## 1. Live job radiator — amber→green job board with PR links

**Status:** `researched` (2026-06-15) · **Effort:** low · **New deps:** none

### Goal

A live board — on the *Claytonia — Runner Fleet* Grafana
dashboard — where each job **glows amber the instant a worker claims it** and **flips
green (and becomes a clickable link to its PR) when the PR opens**. The classic CI
*build radiator / extreme-feedback-device / information radiator* pattern, applied to
the agent fleet.

### Decision

**Build it Grafana-native and stay log-event-native. Do NOT add Prometheus or a
Pushgateway.** The stack is already ~90% there: workers POST JSON to the Alloy Loki
receiver → Grafana Cloud. The feature is essentially *"emit one more lifecycle event
and render the stream as a state board."*

A bespoke SSE/WebSocket page is **deferred** — only worth it for sub-second glow
latency or a custom aesthetic Grafana panels can't produce. For a fleet whose jobs run
minutes (claim → work → PR), a few-second Grafana auto-refresh is adequate.

### Why (researched 2026-06-15, primary-source verified)

- **Pushgateway is the wrong tool here (settled anti-pattern).** Prometheus' own docs:
  *"the only valid use case for the Pushgateway is for capturing the outcome of a
  service-level batch job"* — one aggregate, not per-runid. For a fleet it warns it
  becomes *"a single point of failure and a potential bottleneck,"* and it *"never
  forgets series … and will expose them to Prometheus forever unless manually
  deleted."* Per-runid pushes would pile up stale series forever — the opposite of
  "show live jobs." `statsd_exporter` (which has a TTL) is the less-wrong Prometheus
  path *if* a Prom metric were ever independently wanted, but it adds a service for
  zero UX gain over Loki. [P1][P2][P3]
- **Grafana renders the per-job state board natively.** Three candidate panels:
  - **Canvas** — free-place one **icon per job**; icon/background color is driven by
    query **thresholds / value-mappings**. Map `status` → amber (claimed) / green
    (done) / red (failed). This *is* the glowing icon. **Primary pick.** [P4]
  - **Status history** — one row per `runid`, one colored box per lifecycle event;
    crucially it **does *not* merge consecutive values**, so discrete claimed→done
    points stay visible. Strong table alternative / history view. [P5]
  - **State timeline** — same idea but **merges** identical consecutive states into
    duration bands (good for "how long amber," weaker for discrete dots). [P6]
- **The cell can link to the PR.** All three panels (and Canvas elements) support
  **data links to external URLs**. Two mechanisms:
  1. **Panel data link** when `pr_url` is a query field: interpolate
     `${__data.fields["pr_url"]}` into the link URL. [P7]
  2. **Loki derived field** when the PR url only lives in the JSON log line: a
     `matcherRegex` captures it and templates `${__value.raw}` into a full external
     URL (docs example: `http://localhost:16686/trace/${__value.raw}` → swap in
     `https://github.com/lentago/<repo>/pull/${__value.raw}`). In provisioning YAML
     escape it as `$${__value.raw}`. [P8]
- **Cardinality guardrail (matches existing discipline).** Keep `runid` and `pr_url`
  **in the JSON log body, never as Loki stream labels** — exactly what `cr-emit` does
  today. Per-runid labels would explode stream cardinality (the Loki analogue of the
  Pushgateway stale-series trap). Derive "latest state per runid" **at query time**. [P9]

### Implementation sketch (mapped to code)

Today `bin/cr-emit` is hardwired to a single terminal `job_complete` event, fired once
at `bin/run-job:195`. The PR url is scraped from `logs/<runid>.txt` at completion. The
amber→green vision needs *lifecycle* events. Surgical changes:

1. **Generalize `bin/cr-emit`** → `cr-emit <runid> <event> [k=v ...]`, defaulting to
   the current `job_complete` behavior so nothing regresses.
   - ⚠️ **Design note:** `cr-emit` currently *requires* `logs/<runid>.meta`
     (`cr-emit:13` exits if absent), but `.meta` isn't written until the end of the run
     (`run-job:135–174`). An early `job_claimed` event therefore can't read `.meta` —
     the generalized emitter must accept fields on the command line / env for events
     that fire before `.meta` exists, and only fall back to reading `.meta` for the
     terminal event.
2. **Fire `job_claimed` (amber)** at the claim — `bin/run-job:61`, the
   `mv inbox→processing` — carrying `runid project model worker`.
3. *(Optional)* **Fire `pr_opened` (green + link)** with `pr_url` the moment
   `gh pr create` returns, rather than only scraping it into the terminal event —
   tightens green→link latency. Terminal `job_complete` stays for cost/turns/duration.
4. **Build the panel** on the *Claytonia — Runner Fleet* dashboard (uid
   `claude-runner-fleet`): Canvas (icon color by `status` threshold) or Status history
   (row per `runid`), with the PR as a data link / Loki derived field.

States to model: `claimed` (amber) → `running` (optional) → `done`/`success` (green)
→ `failed` (red). Keep the Loki push body the standard
`{"streams":[{"stream":{<low-card labels>},"values":[["<ns_ts>","<json line>"]]}]}`
shape `cr-emit` already builds.

### Validate before building (NOT primary-source verified in the research pass)

- **Exact LogQL for "latest status per runid"** (`last_over_time` / instant query with
  `json`/`logfmt` parsing) and the Status-history/State-timeline table-shaping
  transforms (Labels-to-Fields / Merge / Organize) — reasoned from the setup, not
  quoted. Pin against live Loki before committing the panel.
- **Grafana's real-time floor** — auto-refresh minimum, Loki live-tail latency,
  Grafana Live/streaming. Confirm the running Grafana Cloud version supports the exact
  Canvas data-links / State-timeline data-links features (added incrementally across
  versions). Directionally fine for this cadence; verify if glow-latency matters.
- **Is `pr_url` reliably promoted to a query *field*** by the chosen parser (→ use a
  panel data link), or does it only exist inside the JSON log line (→ use a Loki
  derived field)? Decides which linking mechanism to wire.

### Recommendation matrix

| Effort | Path | When |
|---|---|---|
| **Low ✅** | Log-native + Canvas/Status-history + derived-field PR links | **Recommended** — delivers amber→green-links-to-PR, zero new deps |
| Medium | `statsd_exporter` (TTL) → Prometheus | Only if Prom metrics are independently wanted; no UX gain here |
| High | Bespoke SSE/WebSocket page (self-hosted) | Only for sub-second glow or a custom aesthetic Grafana can't do |

### Sources

- [P1] Prometheus — *When to use the Pushgateway*: https://prometheus.io/docs/practices/pushing/
- [P2] `prometheus/pushgateway` README (non-goals, no-TTL rationale): https://github.com/prometheus/pushgateway/blob/master/README.md
- [P3] `prometheus/statsd_exporter` (push-to-scrape bridge, per-metric TTL): https://github.com/prometheus/statsd_exporter
- [P4] Grafana — Canvas panel (element color by thresholds/value-mappings, data links): https://grafana.com/docs/grafana/latest/panels-visualizations/visualizations/canvas/
- [P5] Grafana — Status history (row per entity, no value merging): https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/status-history/
- [P6] Grafana — State timeline (state regions, merges consecutive values): https://grafana.com/docs/grafana/latest/panels-visualizations/visualizations/state-timeline/
- [P7] Grafana — Configure data links (`${__data.fields[...]}`, `${__value.raw}`): https://grafana.com/docs/grafana/latest/panels-visualizations/configure-data-links/
- [P8] Grafana — Loki data source, derived fields (`matcherRegex` + external URL): https://grafana.com/docs/grafana/latest/datasources/loki/
- [P9] Grafana — Loki label best practices / cardinality: https://grafana.com/docs/loki/latest/get-started/labels/bp-labels/

> Research method: deep-research harness, 2026-06-15 — 26 sources, 25 claims verified
> 3-0 by adversarial vote (0 killed). The "WHAT Grafana/Loki can do" core rests on
> unanimous primary-doc claims; the *Validate before building* items above were the
> synthesis gaps flagged by the verifier and are intentionally not presented as settled.
