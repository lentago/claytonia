# The worker-runtime interface

*Written with Claude Code (Claude Opus 5.5) from the shipped adapters, 2026-11-04.*

claytonia's product is the queue contract: a plain-file inbox on the NAS, atomic
claim by rename, branch-and-PR-never-merge, per-project context, and at-least-once
delivery (ADR-0001, ADR-0002, ADR-0006). The agent CLI that does a job's work is a
**runtime** behind that contract. A worker reaches it only through one adapter
script, `bin/rt-<runtime>`. This page is the interface a new runtime is built
against: what `bin/run-job` gives an adapter, and what the adapter owes back.

It describes what shipped under #166:

| Runtime | Adapter | CLI on the workers | Status (2026-11-04) |
|---|---|---|---|
| `claude` | [`bin/rt-claude`](../bin/rt-claude) (#167) | Claude Code | live; every job to date |
| `gemini` | [`bin/rt-gemini`](../bin/rt-gemini) (#170, #205) | Gemini CLI 0.66 | shipped, inert until its Vertex credentials are installed |
| `codex` | [`bin/rt-codex`](../bin/rt-codex) (#171) | Codex CLI 0.166 | shipped, inert until its OpenAI key is installed |

The contract's canonical text is the header of `bin/rt-claude`. Where this page and
the code disagree, the code wins, and this page should be fixed.

## Where a runtime sits in a job

`run-job` drives every job through the same steps. Only the parts marked
**adapter** belong to the runtime; everything else is runtime-neutral.

1. **Claim.** `process-inbox` moves the job file `inbox/ → processing/` (atomic
   rename) and starts `run-job`.
2. **Resolve the runtime.** Spec `runtime` → the project registry's `runtime` →
   `CLAUDE_RUNNER_RUNTIME` in `etc/runner.env` → `claude` (#168). A default model
   applies only to the runtime it was written for (README § Runtime resolution).
3. **Refuse at claim** (exit 8), before any checkout, if the name is invalid, there
   is no executable `bin/rt-<runtime>`, or the spec names a model the runtime does
   not take: **adapter** `accepts-model`.
4. **Check out** the project repo clean at its default branch, run the project's
   `setup` hook, and build the prompt: the preamble (branch, PR, never-merge,
   rebase-before-PR, project memory) plus the job's prompt.
5. **Run:** **adapter** `run`, under `timeout(1)` when the job has `timeout_sec`.
6. **Normalize:** **adapter** `normalize`, outside the timeout, so a killed run is
   still filed.
7. **Decide the outcome** from the exit code and the normalized result: limits,
   failure, the PR URL.
8. **Transcript:** **adapter** `transcript`, best-effort.
9. **File** the job to `done/` or `failed/`, write `.meta`, emit `job_complete`
   (`cr-emit`), update the claim comment, and settle the PR's merge path with
   `cr-automerge`. It disarms any auto-merge (ADR-0002), unless a scheduled
   routine's policy allows that PR (ADR-0009). This step, not the agent, enforces
   never-merge, whichever runtime ran.

## The adapter

One executable, `bin/rt-<runtime>`, shipped in `bin/` and deployed by the gitops
loop with the rest of `bin/`. It must pass `bash -n`, or it blocks the whole deploy.
Four subcommands; any other subcommand or option exits 2.

```
rt-<runtime> run --cwd DIR --runid ID --session-id UUID [--model M]
                 [--max-turns N] [--max-budget-usd X] [--allowed-tools T]
rt-<runtime> normalize --raw F --result F --txt F --session-id UUID [--model M]
rt-<runtime> transcript --session-id UUID --out F
rt-<runtime> accepts-model --model M
```

### `run`

**run-job provides:**

| Input | Detail |
|---|---|
| working directory | `run-job` has already `cd`'d to `--cwd`: a clean checkout of the project repo, or `CLAUDE_RUNNER_CWD` for an ad-hoc job |
| prompt | **on stdin, never argv**. One argv string caps at 128 KiB, and project memory files already reach 23 KB |
| `--session-id` | a UUID `run-job` minted for this run. A runtime that can take a caller's id uses it; one that mints its own reports that one in the result |
| `--runid` | the job's run id (`logs/<runid>.*`). Claude uses it for the live-transcript sidecar |
| `--model` | only when the spec, or a default written for this runtime, names one; else the runtime's own default |
| limits | `--max-turns`, `--max-budget-usd`, most specific wins (spec → registry → `runner.env`). The wall clock is not passed: `timeout(1)` enforces it outside the adapter for every runtime |
| `--allowed-tools` | the spec's `allowed_tools`, Claude tool syntax |
| environment | `HOME` and a `PATH` that includes `/opt/claude-runner/bin`. For a project job, also `GH_REPO` and `GH_TOKEN_ACCESS` (`job`, or `job-workflows` with `workflows: true`), which the git credential helper mints for (#176). **No vendor secret**: `run-job` unsets `CLAUDE_CODE_OAUTH_TOKEN` and sources no vendor file (#170) |

**The adapter owes:**

- **stdout** is the runtime's raw output, filed byte-for-byte as `logs/<runid>.json`
  (byte-identical to before the seam, for Claude).
- **stderr** goes to `logs/<runid>.stderr`. Its last line is what a failure comment
  on the job's issue quotes, so a refusal says what is wrong in one line.
- **The exit code**: 0 is clean, and anything else routes the job to `failed/`.
- **No interaction**: no approval prompts, and the CLI may edit files and run `git`
  and `gh` in the checkout.
- **Exec the CLI**, so the process tree under `timeout(1)` stays the CLI's own, and
  never outlive or swallow `TERM`.
- **Source only its own vendor file**, and unset every other vendor's credential
  before it execs (see *Secrets* below).

### `normalize`

Called after the run with the raw output. It writes the **normalized result** to
`--result` (`logs/<runid>.result.json`) and the final text to `--txt`
(`logs/<runid>.txt`).

| Field | Meaning |
|---|---|
| `runtime` | the runtime's name |
| `model` | the `--model` asked for, else `null` (the runtime's default) |
| `session_id` | the id that finds this run's transcript: run-job's UUID, or the runtime's own when it mints one |
| `status` | `ok` \| `max_turns` \| `max_budget` \| `error` |
| `is_error` | the runtime itself reported the run as failed |
| `turns` | a count of the run's steps; what it counts is runtime-specific (below) |
| `tokens` | `{in, cached, out, thinking}`, **disjoint** (#173): `in` excludes cache reads; `out` excludes thinking when the runtime reports thinking separately, else `thinking` is `null` |
| `cost_usd` | as the runtime reports it; **`null` when it reports none, never `0`** |
| `final_text` | the agent's last message: where the PR URL is found, and what the claim comment quotes |

Rules:

- Raw output that is not parseable gets **no** result. `run-job` then lets the exit
  code alone decide, and the raw text doubles as `.txt`.
- An empty output (a run killed before it printed) also gets no result.
- `normalize` exits non-zero only when the output was readable but the result could
  not be written. `run-job` then **fails the job**: a run whose verdict is lost is
  never filed as a success.
- It is silent on stderr, since the last stderr line is the failure reason.

**How `run-job` reads the result:**

- `is_error: true` makes the exit 1.
- A `status` of `max_turns` or `max_budget` names the limit (`limit=turns|budget` in
  `.meta`).
- Any `status` but `ok` fails the job.
- `cost_usd` and `turns` land in `.meta` as-is.
- A wall-clock kill is `limit=timeout`, exit 7, whatever the result says.

### `transcript`

Best-effort: copy the runtime's own session record for `--session-id` to `--out`
(`logs/<runid>.transcript.jsonl`, the durable NAS copy). A missing transcript is not
an error. `CLAUDE_RUNNER_CAPTURE_TRANSCRIPT=0` turns the call off.

### `accepts-model`

Exit 0 when the model is one this runtime takes, 1 when it is not. `run-job` asks
only about a model the job spec names, and refuses the job at claim time on a 1, so
a Claude model can never reach Gemini or Codex. Each adapter owns its own rule, and
none knows another's.

## Secrets

Each adapter sources its own env file under `/etc/claude-runner/`, installed by hand
on every worker. `run-job` sources none, so no runtime's process holds another
vendor's credential. The files are `root:claude 0640`, because the CLI runs as
`claude`; any job on any worker can therefore spend against them (#166, ADR-0010's
trade-off). Each key's own scope and its project usage limit bound the damage: $25 a
month per vendor for Phase 1 (Chris, 2026-11-04). The rebuild runbook carries the
files across a rebuild (`provision/README.md` § Rebuilding a worker).

| Runtime | File | Holds | Read by |
|---|---|---|---|
| `claude` | `token.env` | `CLAUDE_CODE_OAUTH_TOKEN` | `rt-claude run` only (#201) |
| `gemini` | `gemini.env`, `gemini-sa.json` | Vertex AI: project, `location=global`, the key of a service account with *Vertex AI User* only | `rt-gemini run` only |
| `codex` | `codex.env` | `OPENAI_API_KEY` | `rt-codex run` only |

An adapter whose file is missing refuses before the CLI starts, with one stderr line
(`rt-gemini` exits 3, `rt-codex` 78).

## The three runtimes

| | `claude` | `gemini` | `codex` |
|---|---|---|---|
| invocation | `claude -p --dangerously-skip-permissions --output-format json --session-id <uuid>` | `gemini -p "" -o json --approval-mode yolo --session-id <uuid>` | `codex exec --json -C <cwd> --dangerously-bypass-approvals-and-sandbox --ignore-user-config -o <file>` |
| session id | run-job's UUID | run-job's UUID | Codex mints its own thread id; `normalize` reports it |
| repo `CLAUDE.md` | native | loaded via `context.fileName` | loaded via `project_doc_fallback_filenames` |
| settings | the CLI's own | a fresh Gemini home per run, outside the checkout; a root-owned `/etc/gemini-cli/settings.json` from `cr-harden` keeps usage statistics off (#205) | per-run `-c` overrides only; no worker config is read |
| `max_turns` | native | `model.maxSessionTurns`; a capped job is refused if the checkout's own `.gemini/settings.json` names one (#205) | not enforced (one stderr line) |
| `max_budget_usd` | native | not enforced (one stderr line) | not enforced (one stderr line) |
| `allowed_tools` | native | not passed (one stderr line) | not passed (one stderr line) |
| `turns` counts | model turns | tool calls | completed action items (commands, file changes, tool calls) |
| `cost_usd` | reported | `null` | `null` |
| transcript | `~/.claude/projects/…/<uuid>.jsonl` | the run home's `chats/session-*.jsonl` | `~/.codex/sessions/**/*<thread>.jsonl` |
| local state | Claude Code's own session files, kept by its own retention | the per-run Gemini home, swept after 7 days | `~/.codex/sessions` files, swept after 7 days |
| models | `haiku`, `sonnet`, `opus`, `fable`, `claude-*` | `gemini-*`, `auto`, `pro`, `flash`, `flash-lite` | `gpt-*`, `codex-*`, o-series |

No runtime runs a sandbox of its own: the worker, an unprivileged LXC, is the
sandbox. Codex's own sandbox starts in the LXC, but it makes `.git` read-only and
blocks the `gh-token` broker's sudo, so it was ruled out on evidence (#171).

## Adding a runtime

The acceptance test (fleet principle, 2026-07-04): **adding a runtime does not touch
an existing runtime's code path**, and needs no change to the dispatch spec beyond
the optional `runtime` key.

1. `bin/rt-<name>`, implementing the four subcommands above. Start from the header
   of `bin/rt-claude`.
2. A stub CLI under `test/stubs/<cli>` that replays real captured output from
   `test/fixtures/runtimes/` (#169), and `test/rt-<name>.bats`.
3. One `contract_entry` case in `test/adapter-contract.bats`. The contract cases
   loop over every `bin/rt-*`, so a new adapter is held to the contract the moment
   it lands.
4. The adapter in the explicit list in `.github/workflows/shellcheck.yml`.
5. Its secret, if any: the README § Auth entry, `provision/rebuild/` R-2 and R-4, and
   `verify.sh`.
6. The CLI in the runner image (lentago/kalmia's forge), because workers are cattle:
   every worker carries every CLI, and the poller does no capability matching (#166
   judgment C).
7. Five small documentation jobs on a low-stakes repo, each PR reviewed like any
   other, before the runtime is used for real work.

## Not yet in the interface

- **`.meta` runtime and token fields**, and an enforced/not-enforced record per
  limit (#173). Today the unenforced limits appear only as a stderr line. A Codex
  job's `.meta` `session_id` holds run-job's UUID; Codex's thread id is in its
  `result.json`.
- **A per-runtime CLI update path** (#172). `cr-update` updates Claude Code only.
- **Runtime disclosure** on agent PRs and in the preamble's commit trailer (#174),
  with the wording set by lentago/.github#317.
- **A live transcript and the claim comment's live link** for Gemini and Codex
  (lentago/drosera#305). Today these are Claude-only.
- **Queue transport off the LAN**: #47's second item, outside this interface.
