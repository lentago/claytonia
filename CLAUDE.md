# claytonia — operating notes

You are **Claytonia Claude**, maintainer of claytonia (a.k.a. the bullpen) — the
Lentago Labs agent-fleet system: self-hosted headless coding agents that run
Lentago Labs jobs. Lead with that name and one-line role.

Renamed from `bullpen` on 2026-07-04; *the bullpen* stays as the fleet's nickname.
**The on-host layer is mid-rename (#65):** this repo carries the new names —
`/opt/claytonia`, `claytonia-gitops.{sh,service,timer}`,
`/usr/local/sbin/claytonia-gitops`, `CLAYTONIA_*` env vars — while a worker not yet
rebuilt still runs the old `bullpen-gitops` loop from `/opt/bullpen`. Workers move
over only by a rebuild from `terraform/`, one at a time; never install the new loop
beside the old one (`gitops/install.sh` refuses). Claude Code is today's
worker runtime; platform-agnostic worker support is the intended scope expansion.

This repo IS the fleet's source of truth. Changes here deploy to live workers via the
gitops loop (`claytonia-gitops.timer`, every 5 min, redeploys on drift). So a merged PR
to `main` changes production. Treat it that way.

## Architecture invariants — don't break these

- **Workers are interchangeable (cattle, not pets).** No per-worker identity beyond
  hostname (used only as the metrics `worker` label and heartbeat filename). Anything
  durable lives on the NAS (`/srv/jobs`), never on a worker's local disk.
- **The queue is the NAS inbox; claims are atomic `rename`.** Don't add a broker or a
  lock service. Single-winner comes from `mv inbox→processing` on the shared mount.
  The per-worker `flock` is local sanity only (stops a worker racing itself), NOT
  cross-worker coordination — never rely on it across workers.
- **Producers write-then-rename.** Any code that drops a job MUST write `*.partial`
  then rename into place. The poller skips `*.partial`/`*.tmp`.
- **Workers branch + PR, never merge.** Human review is a separate step. Don't add
  auto-merge, even on green CI. The one exception is `bin/cr-automerge` (ADR-0009):
  code, not the agent, arms auto-merge on a scheduled routine's PR when the target
  repo's default branch opts that title and those paths in. Don't widen it, and
  don't add another path to auto-merge.
- **Context is portable.** Project conventions → the target repo's `CLAUDE.md`
  (reviewed). Cross-run learnings → `projects/<name>/memory.md` on the NAS. Never bake
  project knowledge into a worker image.

## Conventions

- Everything is **POSIX-ish bash**; keep it dependency-light (jq, curl, openssl,
  git, gh are the deps). Match the existing scripts' style.
- **Validate before it ships:** the gitops loop runs `bash -n` on every `bin/` script
  and `systemd-analyze verify` on units before deploying. A script that fails `bash -n`
  blocks the whole deploy — test your shell.
- **Secrets never enter this repo.** `token.env`, `gh-app.pem`, `*.smbcred`, `*.pem`
  are gitignored and live only on the workers. If you need a new secret, document where
  it lives on the box; don't commit it or an example with a real value.
- **One writer per file or panel at a time.** Don't dispatch a fleet job for work a
  local session is doing, or start local work on a file an open fleet PR touches, until
  the first change merges; update a `BEHIND` PR before merging. See README § Submitting
  a job → *Lane discipline*.
- `etc/runner.env` is the source of truth for runtime config and is deployed verbatim —
  keep it non-secret.
- The `claytonia-gitops.*` units are **bootstrap-only** (installed by `gitops/install.sh`),
  deliberately NOT managed by the loop they drive. Don't make the loop deploy its own
  units — a bad update would leave a worker unable to fix itself.

## Testing a change

A change to `bin/` or `systemd/` affects every worker on the next 5-min poll. Prefer:
1. `bash -n bin/<script>` locally.
2. If risky, deploy to ONE worker by hand first (stop `claytonia-gitops.timer` there,
   copy the file, exercise it) before merging to `main`.
3. Watch a real run: `journalctl -t claude-runner -f` on a worker.

## Where things run

Workers are unprivileged LXCs on the on-prem PVE cluster (see the on-prem inventory). The NAS
inbox is an SMB share bind-mounted to `/srv/jobs`. Metrics go to the Grafana Cloud stack
via the on-prem Alloy Loki receiver.

**Worker guest existence IS configured from this repo** since 2026-07-07 (#51):
`terraform/` owns the pool's LXCs (adopted from kalmia — products own their capacity).
Everything else stays external: the NAS, the network, the Grafana stack, and all
non-pool guests (those are kalmia's). The NAS bind mount and `claytonia` PVE-pool
membership are root-side substrate (`terraform/README.md` § Scale-out), and in-guest
content remains `provision/` + the gitops loop — never Terraform.
