# bullpen

A self-hosted **fleet of headless Claude agents** on the LAN. Drop a job onto the
NAS, an idle worker picks it up, does the work in a clean checkout, and opens a PR
for human review. Scheduled (cron) + triggered (drop-folder) jobs, per-project
context, GitHub App auth, per-job metrics to Grafana, crash-safe at-least-once
delivery.

The name: a *bullpen* is a pool of ready workers called up when needed. Agents idle
until a job arrives, then one gets the call.

## How a job flows

```
  you / cron / HA / a script
        │  write a job file
        ▼
  NAS inbox  (//neptune/lentago/claude-jobs/inbox)   ← shared "queue"
        │  every worker polls every 15s
        ▼
  a worker claims it  (atomic mv inbox→processing/<runid>)   ← exactly-once
        │
        ▼
  run-job:  resolve project → clean checkout → load repo CLAUDE.md + project memory
            → claude -p (headless) → branch + PR (never merge)
        │
        ├── output → logs/<runid>.{txt,json,meta,stderr,transcript.jsonl}
        │            (transcript.jsonl = the full reasoning: thinking + tool calls)
        ├── prompt → done/<runid>  (or failed/<runid>)
        └── event  → Loki → Grafana ("Claude Runner Fleet" dashboard)
```

Three planes, deliberately separated:
- **Control plane** — where work originates. Your laptop is a thin client that drops
  job specs; it does prompt-engineering, not execution.
- **Worker plane** — N interchangeable worker LXCs (cattle, not pets). The "hat" a
  worker wears is a field in the job, not the box's identity.
- **Artifact plane** — the NAS: the job queue, the results, the project registry, and
  per-project memory. Durable and portable; survives any worker being rebuilt.

## Submitting a job

Write a file into the NAS `inbox/` (write-to-temp then rename so the poller never
reads a half-written file — `*.partial` / `*.tmp` are ignored). Or, on a worker:

```bash
cr-submit "a quick ad-hoc prompt"                  # runs in /home/claude/work
cr-submit -p ice-cream-book "fix broken doc links" # project job: clean checkout + PR
cr-submit -m opus -p ice-cream-book "big refactor" # override the model for this one job
cr-submit -f /srv/jobs/scheduled/daily.json        # queue a copy of a saved spec (cron uses this)
```

A job is **plain text** (the whole file is the prompt) or a **JSON spec**:

```json
{ "project": "ice-cream-book", "prompt": "…", "model": "sonnet",
  "max_turns": 30, "cwd": "…", "allowed_tools": "Read Bash" }
```

**Model resolution**, most-specific wins: the job spec's `model` (or `cr-submit -m`)
→ the project registry's `model` → the global `CLAUDE_RUNNER_MODEL` in `runner.env`
→ the account default.

With `"project"`, the worker resolves the registry, prepares a clean checkout
(warm-but-reset), auto-loads the repo `CLAUDE.md`, injects that project's memory, and
enforces branch→PR. Without it, it's a bare prompt in the work dir.

**Web form.** `frontends/n8n/` is a point-and-click submitter — an n8n workflow that
writes the same job files to the inbox (same spec + write-then-rename, no SSH). It's
just another producer, and works as long as the NAS is up. See its README to deploy.

## Projects (routing + context)

Routing is a job field, not a separate inbox or a per-project box. The registry maps
a project to its repo + defaults; the context layer gives each project a portable
memory that jobs read and append to.

```bash
cr-newproject <name> <owner/repo> [model] [branch]   # register + scaffold context
```

- `projects/registry.json` — `name → {repo, default_branch, model, context_dir, setup}`
- `projects/<name>/memory.md` — dated, durable learnings (conventions, gotchas)

Durable conventions live in the **repo's own `CLAUDE.md`** (reviewed, versioned, loaded
into every job automatically). Cross-run learnings live in the NAS **memory** store.
Both reach any worker — nothing is trapped on one box.

## The fleet

Multiple workers poll the same inbox and claim jobs by atomic `rename`. When co-located
on one host they share a single mount, so single-winner is guaranteed by that host's
kernel — no dependency on cross-client SMB rename semantics. Each worker heartbeats
(`workers/<host>.alive` every 30s); `process-inbox` reaps jobs whose owner has gone
stale (>90s) and requeues them once (`.retry`), then fails them if stranded again.
At-least-once delivery — see Caveats for the idempotency boundary.

## Auth

- **Claude**: a subscription OAuth token (`claude setup-token`) in
  `/etc/claude-runner/token.env` (`CLAUDE_CODE_OAUTH_TOKEN`). Headless `claude -p`
  draws from the Agent SDK credit pool.
- **GitHub**: a GitHub App (`lentago-claude-runner`). `gh-token` mints short-lived
  installation tokens from the App key; `gh-credential-helper` feeds git per-op so no
  token is persisted. Workers open branches + PRs and **never merge** — review is a
  human step.

Secrets (`token.env`, `gh-app.pem`) live on the workers, never in this repo.

## Metrics

Every job emits a `job_complete` event (cost, turns, duration, status, repo, pr_url,
worker) to the homelab Alloy Loki receiver → Grafana Cloud. Dashboard **"Claude Runner
Fleet"** (uid `claude-runner-fleet`): spend, success rate, throughput, duration, and
**open agent PRs awaiting review** — the review front door.

## Repo layout

```
bin/         the runner: run-job, process-inbox, cr-submit, cr-newproject, cr-emit,
             gh-token, gh-credential-helper, claude-set-token
systemd/     claude-inbox.{service,timer} (poll), claude-heartbeat.{service,timer}
cron/        claude-runner — scheduled jobs (re-queue saved specs)
etc/         runner.env — non-secret config (model/cwd/turns defaults, LOKI_PUSH_URL)
gitops/      bullpen-gitops.{sh,service,timer} + install.sh — pull main, redeploy on drift
provision/   01..05 scripts — stand up a worker from scratch (LXC, runner, App, projects, reaper)
frontends/   alternate producers — n8n web form to submit jobs (frontends/n8n/)
docs/        deeper notes
```

## Deploy model (gitops)

`bullpen-gitops.timer` on each worker fetches `origin/main` every 5 min and redeploys
**only** files that actually drifted (`cmp -s`), validating scripts (`bash -n`) and
units first; no-op polls don't restart anything. **So a change to the fleet is a merged
PR, not a hand-run script on every box.** The `bullpen-gitops.*` units are bootstrap-only
(installed by `gitops/install.sh`) so a bad update can't break the updater.

## Provisioning a worker

See `provision/README.md`. In short: create an unprivileged LXC, bind-mount the NAS
`claude-jobs` dir to `/srv/jobs`, run `provision/01..05`, set the auth secrets, then
`gitops/install.sh`. Additional workers are a `pct clone` (detach/re-attach the bind
mount) with a fresh IP + hostname.

## Failure handling

When a job exits non-zero it lands in `failed/<runid>` and the worker logs a `run-job
FAIL` line to journald. The stderr note (if any) and the exit code are in
`logs/<runid>.stderr`.

**Issue comments (Option 1 of #37):** for project jobs whose prompt references a GitHub
issue (`issue #N` or `#N`), the runner posts a comment on that issue containing the
failure reason, exit code, runid, and the last 20 lines of the job log — the two places
a dispatcher watches are the PR queue and the issue, so this closes the loop with no new
infrastructure.  Commenting is strictly best-effort: a failure to post never changes the
job outcome.  Ad-hoc jobs (no project) and prompts with no issue reference are silent.

**Follow-ups not yet implemented:**
- *Grafana alert* — a failed-job alert rule on the "Claude Runner Fleet" dashboard so
  failures surface in the existing metrics view.
- *cr-status ergonomics* — print the runid + a `cr-status <runid>` one-liner so
  dispatchers can poll job state instead of inferring it from PR presence.

## Caveats (known, deliberate)

- **At-least-once, not idempotent.** A worker that dies *after* opening a PR but before
  filing the result will re-run on retry and could open a second PR (capped at 1 retry).
  Repo-side idempotency (does a branch/PR already exist?) is the fix when wanted.
- **Concurrent `memory.md` appends** from 2+ workers on CIFS can interleave. Safe for
  single-worker-per-project today; needs a lock or per-job fragments at scale.
- **Cross-*host* SMB renames untested** — co-locating workers on one host sidesteps it.
