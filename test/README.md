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

## How it stays hermetic

`test/test_helper.bash` builds a throwaway tmpfs `JOBS_ROOT` per test and sets a
few override env vars the runner scripts honour (each defaults to the production
value, so nothing here changes how a real worker behaves):

- `CLAUDE_RUNNER_BIN` — `process-inbox` finds the in-repo `run-job`
- `CLAUDE_RUNNER_PATH` — `run-job`'s internal PATH, so the stubs shadow real bins
- `CLAUDE_INBOX_LOCK` — a per-run flock path, never the prod singleton
- `CLAUDE_BIN` — points at `test/stubs/claude`

`test/stubs/` holds no-op / canned-output stand-ins for `claude`, `cr-emit`, and
`systemd-cat`. The fake `claude` picks its result from `FAKE_CLAUDE_MODE`
(`ok` / `error` / `nonzero`) so a test can drive the done vs failed routing.
