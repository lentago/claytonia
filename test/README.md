# Queue-core test harness

Contract tests for the one component every other automation in the fleet depends
on: the NAS-inbox queue. They drive the **real** `bin/run-job` and
`bin/process-inbox` against a fake inbox on tmpfs, with the agent, metrics, and
journald calls stubbed, so a run touches no network, no NAS, and no real Claude.

Framework is [bats](https://github.com/bats-core/bats-core). They're meant to
run on every PR alongside the ShellCheck gate. The workflow ships at
`test/ci/queue-tests.yml`; a maintainer activates it with
`git mv test/ci/queue-tests.yml .github/workflows/` (the runner GitHub App can't
push under `.github/workflows/` itself — it lacks the `workflows` permission).

## Run locally

```bash
sudo apt-get install -y bats uuid-runtime   # once
bats --print-output-on-failure test/
```

## What's covered (`test/queue.bats`)

| Property | Test |
|---|---|
| **Atomic claim-by-rename** — many workers race one inbox file; exactly one claims it, losers no-op with no side effects | claim race |
| **At-least-once delivery** — a dropped job reaches exactly one of `done/`/`failed/` with its logs, win or lose | at-least-once (×2: success + failure) |
| **Crash-mid-job recovery** — a job whose owner died is requeued (`.retry`) then delivered; a second strand fails instead of looping; a live owner is left alone | crash recovery (×3) |
| **Write-then-rename discipline** — `*.partial` / `*.tmp` / dotfiles / `.owner` / `.swp` are never claimed | discipline |
| **Submitter** (#21) — a spec's `submitter` lands in the `.meta` and reaches `cr-emit` started/running; text jobs have none | submitter (×2) |
| **Per-job bounds** (#114) — a job that outruns `timeout_sec` is killed, lands in `failed/` (exit 7, `limit=timeout`) with its `.owner` gone, and the worker claims the next job in the same pass; turn and budget hits are filed `failed/` with `limit=turns`/`budget`; spec limits reach the CLI | limits (×4) |

## Also covered

- `test/cr-submit.bats` — admission control (#21): the occupancy summary (alive /
  idle / busy / inbox depth from fake `workers/*.alive` + `processing/*.owner`), a
  stalled listing staying bounded, the default and explicit `submitter`, the capacity
  guard warning, and `-w` (never blocks without a terminal; waits then queues, or
  times out and queues, under a `script` pty; `-W` / `CLAUDE_SUBMIT_WAIT_UNATTENDED=1`
  wait and queue with no terminal, and `-W` with `-f` is refused). Also the overlap check (#22): an open
  fleet PR (with its capped path list) and same-project waiting/in-flight specs are
  named while the job still queues, Dependabot PRs and other projects are not, a quiet
  project prints nothing, ad-hoc and `-f` jobs make no `gh` call, and a failing or hung
  `gh` is a note, never a failed or delayed submit.
- `test/cr-emit.bats` — `submitter` is a log-line field on job_started / job_running /
  job_complete and never a Loki label.
- `test/cr-emit-alive.bats`, `test/issue-signal.bats` — liveness event; issue claim
  comments; only the project's own PR gets a merge decision, recorded in the `.meta`.
- `test/schedule.bats` — `cr-schedule` (scheduled jobs as data): one queue per slot
  across racing workers, the `tz` on both sides of DST, the repeated fall-back hour
  firing once, catch-up of the latest slot only, bad specs skipped without stopping
  the rest, cron field semantics, claim pruning. The clock is `CR_SCHEDULE_NOW`.
- `test/automerge.bats` — `cr-automerge` (ADR-0009): arms only when the job named a
  rule, the default branch defines it and the PR fits it; disarms on every other case
  (no rule, failed job, no policy, a path or rename outside the globs, `*` crossing a
  directory, title, author, draft, state, base, fork head, file count). The head-SHA
  rule (#178): the arm carries `--match-head-commit`; a push during the check or right
  after the arm disarms; no readable head is never armed; an armed PR gets the
  gate-readable comment, and a failed comment does not disarm. Uses its own `gh` stub
  serving the policy, the PR, its files and a programmable sequence of head re-reads.
- `test/rt-claude.bats` — the runtime seam (#167): run-job reaches the CLI only through
  `bin/rt-claude`, and the move changes nothing a Claude job files. The raw output lands
  byte-for-byte as `logs/<runid>.json`; the CLI argv, the `.runid` sidecar and the `.meta`
  keys and order are pinned; each stub mode yields its normalized `logs/<runid>.result.json`
  (none when the output is not JSON, so the exit code decides); token counts are disjoint;
  `normalize` is silent on stderr; the transcript copy is best-effort.
- `test/adapter-contract.bats` — the worker-runtime contract (#166, #169), run against
  every `bin/rt-*` adapter: the prompt on stdin and never in argv, raw output on stdout,
  the CLI's exit code passed through, the full result schema from an ok run, a failed run
  never filed `ok`, no result (and silence) for empty or unparseable output,
  `accepts-model`, a best-effort `transcript`, and exit 2 for anything else. A new adapter
  adds one `contract_entry` (its stub and two models); without it the suite fails.
- `test/runtime.bats` — the runtime key (#168): precedence, refusal at claim time, the
  runtime-scoped model defaults, `cr-submit -r`, `cr-newproject -r`, `cr-schedule`.
- `test/runtime-stubs.bats` — the Gemini and Codex stubs replay the captured CLI output
  shapes (`test/fixtures/runtimes/`) and honour their seams.
- `test/gh-token.bats` — scoped installation tokens (#176): each access profile's exact
  permissions for one repository, nothing the App lacks, no installation-wide write
  token, a read-only token when no repo is named, refusals before any request, the
  installation fallback, and the credential helper passing the job's profile through.
  A stub `curl` plays the GitHub API; the App key is generated per test.
- `test/token-scope.bats` — run-job asks for the least each step needs (`job`,
  `comment`, `read`, `merge`, always for the job's repo); `"workflows": true` and
  `cr-submit --workflows`; and a job that needed workflows:write without it fails with
  the fix in its reason line, from the agent's marker or GitHub's refusal, while a
  transcript that merely quotes run-job does not trip it.
- `test/cr-update.bats` — `cr-update` runs under cron's PATH (`/usr/local/bin:/usr/bin:/bin`)
  and reaches claude only through `CLAUDE_BIN`: an update, an already-current run, a
  failed update (exit 1, logged with the prior version), and a held inbox lock that
  skips the run without calling claude.

## How it stays hermetic

`test/test_helper.bash` builds a throwaway tmpfs `JOBS_ROOT` per test and sets a
few override env vars the runner scripts honour (each defaults to the production
value, so nothing here changes how a real worker behaves):

- `CLAUDE_RUNNER_BIN` — `process-inbox` finds the in-repo `run-job`
- `CLAUDE_RUNNER_PATH` — `run-job`'s internal PATH, so the stubs shadow real bins
- `CLAUDE_INBOX_LOCK` — a per-run flock path, never the prod singleton
- `CLAUDE_BIN` — points at `test/stubs/claude`

`test/stubs/` holds no-op / canned-output stand-ins for `claude`, `gemini`, `codex`,
`cr-emit`, `gh`, `gh-token`, and `systemd-cat`. The `gh-token` stub logs its argv to
`FAKE_GH_TOKEN_LOG` when set. The `gemini` and `codex` stubs replay real
output captured from the CLIs (`test/fixtures/runtimes/README.md` says what and when);
each takes `FAKE_<CLI>_MODE` (`ok` / `error` / `nonzero`), `FAKE_<CLI>_ARGS`,
`FAKE_<CLI>_STDIN` and a `FAKE_HANG` prompt, like the `claude` stub. The `gh` stub logs its argv to `FAKE_GH_LOG`; with
`FAKE_GH_PRS` set, `gh pr list` prints that file and `gh api …/pulls/<n>/files` prints
`FAKE_GH_FILES_DIR/<n>.json` (`FAKE_GH_FAIL` / `FAKE_GH_SLEEP` apply to both). The `cr-emit` stub appends its argv to `FAKE_CREMIT_LOG` when set.
The fake `claude` picks its result from `FAKE_CLAUDE_MODE` (`ok` / `error` / `nonzero` / `turns` / `budget`) so a test can drive the done vs
failed routing. A prompt containing `FAKE_HANG` makes it sleep `FAKE_CLAUDE_SLEEP`
seconds first (to trip a timeout), and `FAKE_CLAUDE_ARGS` captures its argv.
