# Runtime output fixtures

Real output from the agent CLIs that `test/stubs/gemini` and `test/stubs/codex`
replay, so each adapter (#170, #171) is tested against what its CLI actually
prints. Captured 2026-11-02 on the workstation, prompt on stdin, in an empty
directory, read-only (`--approval-mode plan`, `-s read-only`). Session and thread
ids, the GCP project and the error-report path are scrubbed; nothing else is
edited.

| File | CLI | Run |
|---|---|---|
| `gemini-ok.json` | Gemini CLI 0.66.0, `-o json`, `gemini-3.5-flash-lite` | ok: stdout, exit 0 |
| `gemini-error.stderr` | same, `-m no-such-model-xyz` | failed call: stdout empty, this on stderr, exit 1 |
| `codex-ok.jsonl` | Codex CLI 0.166.0, `exec --json`, default model | ok: stdout, exit 0; `-o` file holds `ok` |
| `codex-error.jsonl` | same, `-m no-such-model-xyz` | failed call: stdout, exit 1; no `-o` file |

What the captures settle or show, for the adapters:

- **Gemini.** `-p ""` with the prompt on stdin works, and `--session-id` takes a caller UUID. `stats.models.<m>.tokens` carries `input`, `prompt`, `cached`, `candidates`, `thoughts`, `tool` and `total`, and the same counts repeat under `stats.models.<m>.roles.main.tokens`, so summing must take `.tokens` only or it double-counts. This run had no cache hits; Gemini CLI 0.66 computes `input` as `prompt − cached`, so `input` excludes cache reads (see [bin/rt-gemini header, normalize, “Disjoint (#173)”](../../../bin/rt-gemini)).
- **Codex.** `exec` reads the prompt from stdin when no `PROMPT` argument is given, and `-o` writes the last message. `turn.completed.usage` has a fifth field the spec did not list, `cache_write_input_tokens`. A failed call still prints events (`error`, `turn.failed`) and exits 1. `rt-codex` now runs `codex exec` with `--ignore-user-config`, so no worker-local config is read (see [bin/rt-codex header, Context](../../../bin/rt-codex)).

Recapture when a CLI's output shape changes, and update the stub header to match.
