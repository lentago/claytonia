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

1. **Claim.** `process-inbox` hands each inbox file to `run-job`, which claims it
   with one atomic rename, `inbox/ → processing/`. A worker that loses the race
   finds the file gone and exits with no side effects. That rename is the
   single-winner point (ADR-0001).
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
Seven subcommands; any other subcommand or option exits 2.

```
rt-<runtime> run --cwd DIR --runid ID --session-id UUID [--model M]
                 [--max-turns N] [--max-budget-usd X] [--allowed-tools T]
rt-<runtime> normalize --raw F --result F --txt F --session-id UUID [--model M]
rt-<runtime> transcript --session-id UUID --out F
rt-<runtime> accepts-model --model M
rt-<runtime> enforces --limit turns|budget
rt-<runtime> update
rt-<runtime> live-session --session-id UUID --cwd DIR --raw F
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
| `tokens` | `{in, cached, cache_write, out, thinking}`, five **disjoint** counts (#173). Each input token is in exactly one of `in` (billed at the uncached rate), `cached` (cache reads) and `cache_write` (cache writes); `out` excludes thinking when the runtime reports thinking separately, else `thinking` is `null`. A count the runtime does not report is `null`; all five are `null` when it reported no usage |
| `tokens_by_model` | `{"<model id>": {in, cached, cache_write, out, thinking}}`: the same five counts for each model the run used, summing to `tokens` field by field. Keyed `unknown` when the runtime reports usage but not its model; `null` exactly when all of `tokens` is `null`. It is what the dashboard prices from (lentago/drosera#304): a spec's `model` is often `default`, and one Gemini job spans several models |
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
- The five token counts land in `.meta` as `tokens_in`, `tokens_cached`,
  `tokens_cache_write`, `tokens_out` and `tokens_thinking`, and `tokens_by_model` as
  one line of compact JSON; a `null` is written blank. `cr-emit` carries them on the
  `job_complete` line, never as labels, and turns a blank `cost_usd` into `null`,
  never `0`.
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

### `enforces`

Exit 0 when the runtime enforces that cap itself (`turns` for `max_turns`, `budget`
for `max_budget_usd`), 1 when it does not; any other limit name exits 2. `run-job`
asks only about a limit the job sets, after the run, and records the answer in
`.meta` as `turns_enforced=` and `budget_enforced=` (`yes` or `no`; blank when the
job set no such limit), so a limit that was set but not enforced is recorded, never
dropped silently (#166, #173). The wall clock is never asked about: `timeout(1)`
enforces it outside every adapter.

### `live-session`

Where this run's live session file is, for the worker transcript shipper (#239;
lentago/drosera ADR-0012, drosera#305). It prints `<session id><TAB><path>` once the
runtime's own session file exists, and nothing (exit 0) while it does not. It exits 3
when the runtime's transcript ships another way and is never linked: Claude's, which
the shipper reads from `~/.claude/projects/-home-claude-work*/` beside the `.runid`
sidecar. `--raw` is the run's raw output so far, for a runtime that announces its
session id there (Codex's `thread.started`). It is read-only, quick and silent, since
run-job calls it every 2 seconds.

**run-job links what it finds** at
`/home/claude/.claytonia/live/<runtime>/<project>/<runid>/<session_id>.jsonl` (`adhoc`
for an ad-hoc job). The shipper reads Gemini and Codex sessions only through these
links, and takes every label from the link's path. A link is written only when the
job's cwd resolves inside the public workroot (`/home/claude/work`), and never for an
`offbox_transcript: false` project. Both paths are resolved first, so a `..` or a
symlink cannot leave the workroot. This rule is what keeps a private project's jobs off
Grafana Cloud, and `test/live-links.bats` holds it. It is about where a job runs, not
what it reads: a job in the public workroot streams its narration whatever files it
reads, as a Claude job always has. run-job looks while the job runs
and once more after it, so a short run still links. It keeps the run directory's mtime
fresh until the job ends, then stamps the finish. `process-inbox`, holding the inbox
lock so that no job is mid-run, removes run directories idle for more than 15 minutes
(`CLAUDE_RUNNER_LIVE_GRACE_MIN`). This assumes the shipper reads a finished job's last
lines within that time. If the shipper is down for longer, the live stream loses its
tail, while the NAS copy (`logs/<runid>.transcript.jsonl`) keeps the whole session.
Removing a link never touches the session file.

### `update`

Brings the runtime's CLI to its target version (#172). `cr-update` calls it for
every adapter in `bin/`, weekly from cron as root, under the inbox lock and its
jitter and wait, so an update never lands under a running job. A new runtime
gets its step by shipping its adapter; `cr-update` names no runtime. It prints
one line, which `cr-update` logs to journald under the runtime's name, and exits:

| Exit | Line | Meaning |
|---|---|---|
| 0 | `updated: <before> -> <after>`, `already current (<version>)`, or `not pinned, left at <version> (…)` | done |
| 3 | `not installed (<path>)` | skipped: a worker built before its image carried this CLI |
| 4 | `needs root: …` | skipped: an update is due, but the install is not this user's to write |
| other | `update FAILED (was: <before>): <why>` | failed; `cr-update` still runs the other steps, then exits 1 |

Each adapter owns its install's privileges. `cr-update` runs as root because Gemini
and Codex are installed system-wide and root-owned by kalmia's runner image.
`rt-claude` runs Claude's update as `claude`, the owner of its native install.
Each CLI is called by absolute path, since cron's PATH (`/usr/local/bin:/usr/bin:/bin`)
lacks `~/.local/bin` (#162); system tools are on that PATH and are called by name.

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
| `max_turns` | native (`turns_enforced=yes`) | `model.maxSessionTurns` (`turns_enforced=yes`); a capped job is refused if the checkout's own `.gemini/settings.json` names one (#205) | not enforced: one stderr line, `turns_enforced=no` |
| `max_budget_usd` | native (`budget_enforced=yes`) | not enforced: one stderr line, `budget_enforced=no` | not enforced: one stderr line, `budget_enforced=no` |
| `allowed_tools` | native | not passed (one stderr line) | not passed (one stderr line) |
| `turns` counts | model turns | tool calls | completed action items (commands, file changes, tool calls) |
| `tokens` | summed over `modelUsage`, the whole session (`inputTokens` → `in`, `cacheReadInputTokens` → `cached`, `cacheCreationInputTokens` → `cache_write`, `outputTokens` → `out`, thinking folded in so `null`); `.usage`, which covers only part of the session, only when `modelUsage` is missing | per model in `.stats.models`: `input` + `tool` → `in` (0.66's `input` is already `prompt` − `cached`), `cached`, `candidates` → `out`, `thoughts` → `thinking`; `cache_write` `null` | `turn.completed` usage, summed: `input` − `cached_input` − `cache_write_input` → `in`, `cached_input`, `cache_write_input`, `output` − `reasoning_output` → `out`, `reasoning_output` → `thinking` |
| `tokens_by_model` keys | `modelUsage`'s model ids (`unknown` on the `.usage` fallback) | `.stats.models`' model ids: the router, the main model and the loop detector, a zero-token one included | the model the session transcript's `turn_context` names; `unknown` when it names none or several, or there is no transcript |
| `cost_usd` | reported | `null` | `null` |
| `update` (#172) | `claude update`, as `claude`: Claude Code's own release channel, no pin | npm `@google/gemini-cli` under `/usr`, to `CLAUDE_RUNNER_GEMINI_VERSION` (`etc/runner.env`) | the release package into `/opt/codex/<version>`, checked against the sha256 digest GitHub publishes for it (integrity; authenticity rests on GitHub's TLS, as for the image's install), to `CLAUDE_RUNNER_CODEX_VERSION`; a version already on disk needs no network |
| transcript | `~/.claude/projects/…/<uuid>.jsonl` | the run home's `chats/session-*.jsonl` | `~/.codex/sessions/**/*<thread>.jsonl` |
| live stream | its own path and the `.runid` sidecar (`live-session` exits 3) | linked under `live/gemini/…/<sessionId>.jsonl` | linked under `live/codex/…/<thread id>.jsonl`, the id read from `thread.started` |
| local state | Claude Code's own session files, kept by its own retention | the per-run Gemini home, swept after 7 days | `~/.codex/sessions` files, swept after 7 days; the adapter's per-run hand-off files (last message, thread id) under `~/.cache/rt-codex`, swept after 2 days |
| models | `haiku`, `sonnet`, `opus`, `fable`, `opusplan`, `default`, `claude-*` (optionally with `[1m]`) | `gemini-*`, `auto`, `auto-gemini-*`, `pro`, `flash`, `flash-lite` | `gpt-*`, `codex-*`, o-series (`o3`, `o4-mini`, …), lowercase |

No runtime runs a sandbox of its own: the worker, an unprivileged LXC, is the
sandbox. Codex's own sandbox starts in the LXC, but it makes `.git` read-only and
blocks the `gh-token` broker's sudo, so it was ruled out on evidence (#171).

**A runtime's shell tool may rewrite the environment of the commands it runs.**
Gemini CLI 0.66 appends seven git config overrides through `GIT_CONFIG_COUNT`
to every shell command. The first is an empty `credential.helper`, which clears
the worker's `gh-credential-helper`, so on the first live run `git push` found no
credential (#170). `rt-gemini` copies the URL-scoped helper from `~/.gitconfig`
into `GIT_CONFIG_PARAMETERS`, which git applies after those overrides. When you
add a runtime, check `env` and `git config -l` from inside one of its shell
commands, not only from the adapter.

## Adding a runtime

The acceptance test (fleet principle, 2026-07-04): **adding a runtime does not touch
an existing runtime's code path**, and needs no change to the dispatch spec beyond
the optional `runtime` key.

1. `bin/rt-<name>`, implementing the seven subcommands above. Start from the header
   of `bin/rt-claude`.
2. A stub CLI under `test/stubs/<cli>` that replays real captured output from
   `test/fixtures/runtimes/` (#169), and `test/rt-<name>.bats`.
3. One `contract_entry` case in `test/adapter-contract.bats`. The contract cases
   loop over every `bin/rt-*`, so a new adapter is held to the contract the moment
   it lands.
4. The adapter in the explicit list in `.github/workflows/shellcheck.yml`.
5. Its secret, if any: the README § Auth entry, `provision/rebuild/` R-2 and R-4, and
   `provision/rebuild/verify.sh`.
6. The CLI in the runner image (lentago/kalmia's forge), because workers are cattle:
   every worker carries every CLI, and the poller does no capability matching (#166
   judgment C).
7. Five small documentation jobs on a low-stakes repo, each PR reviewed like any
   other, before the runtime is used for real work.

## Not yet in the interface

- **Codex's thread id in `.meta`.** A Codex job's `.meta` `session_id` holds
  run-job's UUID; Codex's own thread id is only in its `result.json`.
- **Runtime disclosure** on agent PRs and in the preamble's commit trailer (#174),
  with the wording set by lentago/.github#317.
- **Queue transport off the LAN**: #47's second item, outside this interface.
