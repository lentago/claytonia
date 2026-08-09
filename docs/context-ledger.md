# Context ledger — fleet-wide Claude context drift tracking

## Purpose

Host-side Claude Code context — the global `~/.claude/CLAUDE.md`, settings and
hooks, installed skills and plugins, per-project memory, and the MCP server
registration in `~/.claude.json` — shapes how every agent on a worker behaves,
yet it lives *outside* any repo. Repo-side context (a project's own `CLAUDE.md`)
is already versioned in the project repo; this ledger covers the host-side half.

Every worker snapshots its host-side context daily into the queue share; the
primary worker sweeps those snapshots into the **private** ledger repo
`lentago/myosotis`, one commit per changed host. The result is a versioned,
diffable history of the fleet's out-of-band context.

Beyond hygiene this is a **security control**: memory poisoning, hook injection,
and permission-allowlist creep on a worker stop being silent persistent state and
become visible diffs in the ledger.

## Threat model

**Catches (as a diff in the ledger):**

- **Memory poisoning** — an injected instruction landing in
  `~/.claude/projects/*/memory/**` shows up as a memory diff.
- **Hook injection** — a malicious hook added to `settings.json` /
  `settings.local.json` shows up as a settings diff.
- **Permission-allowlist creep** — an expanding `permissions.allow` list (or new
  MCP servers) shows up in the settings / derived-`claude.json` diff.
- **Stale / drifting CLI versions** — `versions.txt` records `claude --version`
  per host, so a worker running an old or odd build is visible.

**Limitation — a compromised host can lie in its own self-report.** The snapshot
is produced *by* the worker, so a sufficiently compromised worker could doctor
what it reports. The ledger is a tripwire for drift and low-to-mid-grade
tampering, not a root of trust. The escalation path is an **out-of-band
host-side spot-check from the PVE host (pve4)**: compare a suspect worker's live
`~/.claude` against its last ledger entry from a vantage point the worker does
not control.

## What is collected (allowlist)

The collector (`../bin/context-snapshot`) is **allowlist-only** — it never globs
`~/.claude` wholesale. Exactly these are staged:

- `~/.claude/CLAUDE.md`
- `~/.claude/settings.json`, `~/.claude/settings.local.json`
- `~/.claude/skills/*/SKILL.md` verbatim, plus a per-skill `OTHER-FILES.sha256`
  hash manifest (path, sha256, bytes) of every *other* file in the skill dir
- `~/.claude/projects/*/memory/**` — full bodies by default (workers). The
  `--memory=hash` flag emits only a manifest (path, sha256, bytes, mtime) with no
  bodies; it exists for the operator's workstation (out of scope for the fleet).
- installed-plugins list — names + versions/refs only (`claude/plugins.txt`)
- `claude --version` and `command -v claude` → `versions.txt`
- a **derived**, sanitized `claude-json.derived.json` built from `~/.claude.json`
  with `jq -S`: `mcpServers` mapped to `{type, command, url, args, env: (keys),
  headers: (keys)}` — **key names only, never values** — plus plugin/marketplace
  registration fields. The raw `~/.claude.json` is **never** copied; `projects`
  (prompt history) and oauth/account fields are excluded by construction. On a jq
  parse failure a `claude-json.PARSE_ERROR` marker is written and the derived view
  is excluded — there is no raw fallback, ever.

Each snapshot also carries a per-file `MANIFEST.sha256` and a `meta.json`
(`hostname`, `timestamp_utc`, `claude_version`, `script_rev`, `memory_mode`,
`status`). Because `timestamp_utc` changes each run, a host commits at least a
daily "still reporting" liveness entry even when nothing else drifted.

## Guardrails (denylist + secret-scan)

Two independent guards run over the *staged* tree before it is published; either
firing aborts the whole snapshot, publishes a `QUARANTINE.txt` in the host's
slot, and exits nonzero:

- **Path denylist** (defense in depth): any staged path matching `*credentials*`,
  `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `*token*`, `*.smbcred`, or `.envrc`.
- **Content secret-scan**: `grep -E` for `sk-ant-`, `ghp_`, `github_pat_`,
  `gho_`, `glpat-`, `AKIA[0-9A-Z]{16}`, `xox[baprs]-`, `eyJhbGciOi`, and
  `-----BEGIN.*PRIVATE KEY` over every staged file.

A hit is treated as a **finding, not a warning**: a secret is somewhere it should
not be. Loud failure is the feature.

## Quarantine semantics

On any guard hit the snapshot publishes a slot containing only `QUARANTINE.txt`
(plus `meta.json` with `status: quarantined`). `QUARANTINE.txt` records the
offending **path and line number only** — never the matched content, so the
secret never enters the ledger. The committer still commits a quarantined slot
(so a failed snapshot is *visible* in the ledger) and logs a warning.

## Review workflow

Review is the **myosotis commit feed**: each push is `ledger(<host>): N files
changed`, so browsing the repo's commit history (or watching it) surfaces exactly
what drifted on which host and when. A `QUARANTINE.txt` in a host's tree flags a
snapshot that tripped a guard and needs a look.

## ledger-report

`bin/ledger-report` is a read-only CLI wrapper over a myosotis clone that replaces
raw `git log` incantations. It defaults to the committer's clone at
`/opt/context-ledger/myosotis`; override with `LEDGER_DEPLOY_KEY` for fetch and
`LEDGER_CLONE_DIR` to point at any local clone (e.g. an operator workstation).

```
# Fleet summary — last snapshot time, age, files changed, status per host
ledger-report

# One host's drift commits with per-commit changed-file lists
ledger-report --host <hostname> [--since 7d]

# Actual diffs for a host (git log -p scoped to hosts/<h>/)
ledger-report --host <hostname> --diff [--since 7d]

# Every QUARANTINE.txt in history with commit hash, date, and body
ledger-report --quarantines

# Refresh the local clone from the remote before reporting
ledger-report --fetch [other options]
```

`--since` accepts shorthand ages (`7d`, `2w`, `1m`, `12h`) or any git date string
(`2026-07-01`, `"last week"`). Status values in the summary: `ok` (recent snapshot,
no guard hits), `stale` (last snapshot >48 h ago), `quarantined` (QUARANTINE.txt
present — needs attention). The script never commits, pushes, or checks out; `--fetch`
is the only mutating git operation it ever performs.

## Primary election

The committer (`../bin/context-ledger-commit`) runs on **one** worker. The
designated primary is named by a single NAS marker, `/srv/jobs/context-ledger/primary`,
holding that worker's hostname. The committer self-gates on it (any other worker
that somehow has the timer exits 0 silently), and provisioning
(`../provision/07-context-ledger.sh`) only enables the committer timer on that
host. This is the fleet's one deliberately pet-like role — justified because the
committer holds a repo-scoped write key that must **not** be fleet-wide.

To promote a new primary: write the new hostname to the marker and re-run
provisioning on that host so it generates its own deploy key:

```sh
echo "$(hostname)" > /srv/jobs/context-ledger/primary
sudo provision/07-context-ledger.sh
```

## Deploy key

The committer authenticates to `git@github.com:lentago/myosotis.git` with a
dedicated ed25519 key at `/root/.ssh/myosotis_deploy` (comment
`myosotis-ledger-committer@claude-runner`), pinned via `GIT_SSH_COMMAND`. This is
**not** the fleet GitHub App credential — the ledger writer is deliberately a
separate, per-repo-scoped identity. Provisioning generates the key if absent; the
**private half never leaves the host** and never lands in `/srv/jobs` or any repo.
When the key is freshly generated, provisioning logs the **public** half loudly:
register it as a **write** deploy key on `lentago/myosotis`. Until it is
registered the committer fails loudly and snapshots stay queued in `incoming/` —
that is the expected state during myosotis bootstrap.

**Rotation:** delete `/root/.ssh/myosotis_deploy*` on the primary and re-run
provisioning; a new keypair is generated and its public half logged for
registration. Remove the old deploy key from `lentago/myosotis` once the new one
is in place. The key is host-local, so rotation touches only the primary.

## Two hard rules

- **`myosotis` is NEVER a bullpen project.** It must never be registered in
  `projects/registry.json`. It is a data sink, not a job target: no agent ever
  checks it out or opens a PR against it.
- **The committer NEVER touches PRs or merges.** It pushes data commits to the
  ledger repo only. This does not weaken the fleet's branch-and-PR-never-merge
  boundary (see [`../CLAUDE.md`](../CLAUDE.md)) — that boundary governs *project*
  work, and the ledger is not project work.

## Events (Loki visibility layer)

After each sweep the committer ([`../bin/context-ledger-commit`](../bin/context-ledger-commit))
pushes structured events to the fleet's Alloy Loki receiver — the same
`loki_push` idiom the per-job emitter uses, factored into the shared helper
[`../bin/cr-loki.sh`](../bin/cr-loki.sh). The committer is the single observer:
its clone holds every host's `meta.json` + tree, so **one** emitter covers the
whole fleet with zero per-host instrumentation. Sizes/counts are derived from the
committed tree, so the snapshot side needs no changes.

Events are a **projection** of the ledger (the source of truth): a Loki push
failure is logged (`|| warn`) and **never** fails the sweep. Configure the Loki
endpoint via `LOKI_PUSH_URL` (from `runner.env`); the stale threshold via
`CONTEXT_STALE_S` (default `93600` = 26h).

> **This event schema is a cross-repo CONTRACT.** drosera dashboards and alerts
> query these fields; treat any field rename/removal/retype as a **breaking
> change** and coordinate it there.

### Labels (low-cardinality — Loki stream labels)

| Label | Value |
|---|---|
| `job` | `claude_runner` (constant) |
| `service` | `context_ledger` (constant) |
| `host` | the host name — **`context_host` events only** |

Everything else lives in the JSON log line (per the `cr-emit` convention).

### `context_sweep` — one per run

| Field | Type | Meaning |
|---|---|---|
| `event` | string | `"context_sweep"` |
| `swept` | int | host slots seen in `incoming/` this run |
| `changed` | int | hosts whose ledger commit was pushed this run |
| `quarantined` | int | swept slots carrying a `QUARANTINE.txt` |
| `duration_s` | int | wall-clock seconds for the sweep |

### `context_host` — one per host dir in the clone

Emitted for **every** `hosts/<host>/` in the ledger, **not** just the hosts swept
this run — so a host that stopped snapshotting still reports its age, which is
what liveness alerting keys on.

| Field | Type | Meaning |
|---|---|---|
| `event` | string | `"context_host"` |
| `host` | string | host name (also a label) |
| `status` | string | `ok` \| `quarantined` \| `stale`. `quarantined` (a committed `QUARANTINE.txt` / `meta.status`) wins; else `stale` when `snapshot_age_s > CONTEXT_STALE_S`; else `ok` |
| `files_changed` | int | files changed for this host **this sweep** (`0` if unswept) |
| `commit` | string | short SHA of the host's latest ledger commit |
| `snapshot_age_s` | int \| null | `now − meta.timestamp_utc` (`null` if unparseable/absent) |
| `claude_version` | string | from the host's `meta.json` |
| `memory_mode` | string | `full` \| `hash`, from `meta.json` |
| `total_bytes` | int | total bytes of the host's committed tree |
| `memory_bytes` | int | bytes of per-project memory (`full`: bodies; `hash`: manifest byte column) |
| `memory_files` | int | count of per-project memory files (or manifest entries) |
| `skills_count` | int | installed-skill directories |

## Signal model

The context-tracking stack has three layers with a strict authority order:

| Layer | What it is | Authority |
|---|---|---|
| **git** — `lentago/myosotis` | The ledger repo itself | **Source of truth** |
| **Loki** — `context_sweep` / `context_host` events | Projection pushed by the committer after each sweep | Derived — correct when the committer is healthy |
| **Grafana** — "Context Ledger" row on the Claytonia dashboard | Pane over the Loki projection | Display only |

**If Loki or Grafana disagrees with what `git log` in myosotis shows, git wins — and the disagreement is itself a signal worth investigating.** A committer that can commit but fails to push Loki events produces a Loki/Grafana gap, not a ledger gap. A host that shows `stale` in Grafana but has fresh commits in myosotis indicates a broken Loki push or a lagging dashboard query. A host with *neither* a fresh ledger commit *nor* a Loki event is a genuine reporting failure.

The committer is the only bridge between truth and projection: it reads the committed tree to compute sizes and ages, then pushes the events. Any failure there (LXC down, deploy key invalid, myosotis unreachable) silences *all* signals simultaneously — see the `committer-silence` runbook entry below. `ledger-report` queries git directly and remains useful when events are dark.

> **Operational baseline:** as of 2026-08-09, fleet workers run Claude Code 2.1.177 while the operator workstation runs 2.1.226. The version-spread panel in Grafana surfaced this gap on the day the dashboard shipped — that is the intended use of `context_host.claude_version`.

## Alert runbook

The four alert rules on the Claytonia — Runner Fleet dashboard map to the playbooks below. Before any deep-dive, run `ledger-report` for current fleet state — it queries git directly, so it stays useful even when the Loki projection is dark.

### `context_quarantine` — quarantined snapshot

A host's latest slot contains `QUARANTINE.txt`. A secret (or a path-denylist hit) landed somewhere it should not be on that worker.

1. **Rotate the credential first.** Read `QUARANTINE.txt` from the host's slot in myosotis (or `ledger-report --quarantines`) to get the offending path and line number. Treat this as a live exposure: if it is an API key, token, or private key, revoke or rotate before doing anything else.
2. **Clean the source file on the worker.** SSH in and remove or redact the matched content. Common causes: a secret accidentally written into a per-project memory file or a skill config file.
3. **Re-run the snapshot:** `systemctl start context-snapshot.service` on the affected worker. The next committer sweep picks up the new slot, commits a clean entry (no `QUARANTINE.txt`), and the alert resolves.
4. If path and line alone are not enough to identify the secret, inspect the surrounding diff in myosotis for the commit that introduced the file.

### `context_stale_host` — fleet host not reporting (>26 h)

A fleet worker's last ledger commit is more than 26 h old. The threshold is `CONTEXT_STALE_S` (default `93600` s, set in `runner.env`).

1. **Check the timer** on the host: `systemctl status context-snapshot.timer` — is it active, and when did it last trigger?
2. **Check the NAS mount:** `ls /srv/jobs/` on the worker — if the mount is absent the snapshot can find no inbox and writes nothing to `incoming/`. Re-mount with `mount -a` or investigate the SMB credential and `/etc/fstab`.
3. **Check host power state** from pve4: `pct status <vmid>`. A crashed or shut-down LXC explains everything.
4. If the timer and mount are both healthy but no slot has appeared, check `journalctl -u context-snapshot` on the worker and re-run manually: `systemctl start context-snapshot.service`.

### `context_stale_laptop_96h` — workstation not reporting (>96 h)

The operator workstation uses a longer staleness threshold (96 h) because it is a laptop — **staleness here is most often travel or the machine being powered off.** The playbook is the same as `context_stale_host` but skip the PVE power-state step; wait until the machine is on and reachable, then check the timer if the alert persists. The workstation runs `--memory=hash` mode (no memory bodies in the ledger).

### `context_committer_silence` — committer has not pushed events

The Loki `context_sweep` event has been absent for an extended period. **While this fires, every other Grafana panel in the Context Ledger row goes dark — the projection is stale.** The ledger itself is unaffected; use `ledger-report` directly against the local clone for fleet status while you investigate.

Diagnostic order on the primary (LXC 110 in the claytonia pool):

1. **LXC 110 health:** `pct status 110` from pve4. Start it if it is not running.
2. **Committer timer:** `systemctl status context-ledger-commit.timer` on LXC 110. Enable and start if inactive.
3. **Deploy key:** confirm `/root/.ssh/myosotis_deploy` exists and its public half is registered as a **write** deploy key on `lentago/myosotis`. Test: `ssh -i /root/.ssh/myosotis_deploy -o BatchMode=yes git@github.com` — GitHub should return a greeting with the key identity, not a permission error.
4. **myosotis reachability:** `curl -sf https://api.github.com/repos/lentago/myosotis` from LXC 110 confirms the GitHub API is reachable from that host.
5. **Recent logs:** `journalctl -u context-ledger-commit -n 50` for the specific error.

If the committer can commit to myosotis but Loki push is failing, check `LOKI_PUSH_URL` in `runner.env` and probe the Alloy receiver directly with a `curl` to the push endpoint.

## Files

| Piece | Path |
|---|---|
| Collector (all workers) | [`../bin/context-snapshot`](../bin/context-snapshot) |
| Committer (primary only) | [`../bin/context-ledger-commit`](../bin/context-ledger-commit) |
| Report CLI (operator) | [`../bin/ledger-report`](../bin/ledger-report) |
| Provisioning | [`../provision/07-context-ledger.sh`](../provision/07-context-ledger.sh) |
| Units | `../systemd/context-snapshot.{service,timer}`, `../systemd/context-ledger-commit.{service,timer}` |
| Tests | [`../test/context-ledger.bats`](../test/context-ledger.bats) |
