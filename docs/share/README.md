<!-- Generated from docs/share/README.md in lentago/claytonia and published here by bin/cr-publish-share (#185). Edit it there, by PR: a change made in this copy is overwritten within minutes. -->
# claytonia job queue — the drop folder

_Co-written with [Claude](https://claude.ai) (Anthropic), like the rest of claytonia: the
maintainer directs and reviews, Claude writes._

This folder is the job queue for **claytonia**, the Lentago Labs agent fleet (the
bullpen). It is the SMB share `lentago/claude-jobs`, mounted on every worker as
`/srv/jobs`. The worker pool (the `claude-runner*` LXCs; their number is set in the
repo's `terraform/`) polls `inbox/` every 60 seconds. The first worker to rename a
job into `processing/` owns it, and the result lands in `logs/`. Project jobs end
in a pull request for a human to review. Workers never merge.

The full reference is the claytonia README:
<https://github.com/lentago/claytonia#submitting-a-job>.

## Submit a job

Write a file into `inbox/` **under a temporary name, then rename it**, for example
`foo.json.partial` → `foo.json`. The poller skips `*.partial`, `*.tmp` and dotfiles,
so it never reads half a file. A job is either:

- **plain text** (`.txt` / `.md`): the whole file is the prompt, run in
  `/home/claude/work`; or
- **a JSON spec**, in which every key but `prompt` is optional:

```json
{ "prompt": "fix the broken doc links", "project": "claytonia", "issue": 130,
  "model": "sonnet", "max_turns": 30, "max_budget_usd": 5, "timeout_sec": 1800 }
```

| Key | What it does |
|---|---|
| `prompt` | the task |
| `project` | a name in `projects/registry.json`: the job gets a clean checkout of that repo, its `CLAUDE.md` and project memory, and is told to branch and open a PR |
| `issue` | the target issue (an integer). The worker posts a claim comment there and edits it with the outcome. Without the key, a strict parse of the prompt applies |
| `runtime` | the agent CLI to run, `claude` by default; the project's registry entry may set it |
| `model` | `sonnet`, `opus`, `haiku`, `fable` or a full model id; it must be one the runtime takes, or the job is refused |
| `max_turns`, `max_budget_usd`, `timeout_sec` | per-job limits. Most specific wins: spec, then registry, then the fleet defaults (150 turns, $15, 3600 s). A limit hit fails the job |
| `workflows` | `true` lets the job's GitHub token change `.github/workflows/`. Without it such a change is refused, and the job fails saying to resubmit with it |
| `automerge` | names a rule in the target repo's `.claytonia/automerge.json`. Only a PR that fits the rule is auto-merged; every other PR waits for a human |
| `allowed_tools` | restricts the agent's tools (`"Read Bash"`); omit it to allow all |
| `cwd` | the working directory for a job with no project |
| `submitter` | who queued it, carried into the logs and metrics (`cr-submit` sets it) |

Every token a project job holds covers its own repository only.

## From a worker (`ssh claude-runner`)

```
cr-submit "a quick ad-hoc prompt"
cr-submit -p claytonia -i 130 "work issue 130"      # project job, naming its issue
cr-submit -m opus -p claytonia "a harder one"       # pick the model
cr-submit --workflows -p claytonia "edit ci.yml"    # allow .github/workflows/ changes
cr-submit -f /srv/jobs/scheduled/daily-health.json  # queue a copy of a saved spec now
journalctl -t claude-runner -f                      # watch runs live
```

`cr-submit -h` lists every option.

## Where output lands

A job's runid is `<UTC timestamp>-<file name>`.

- `logs/<runid>.txt`: the agent's final answer (and the PR URL)
- `logs/<runid>.json`: the CLI's raw output; `logs/<runid>.result.json`: the same, normalized
- `logs/<runid>.meta`: exit code, duration, cost, turns, limits, issue, submitter, merge decision
- `logs/<runid>.stderr`: checkout and run notes. On failure its last line is the reason, and that line is quoted on the job's issue
- `logs/<runid>.transcript.jsonl`: the full transcript of the run
- `done/<runid>` or `failed/<runid>`: the consumed job file. `*.badjson`, `*.emptyprompt` and `*.stranded` name jobs that never ran

Exit codes in `.meta`: 0 done; 1 the agent failed or hit a turn or budget limit;
3 bad JSON or an empty prompt; 4 unknown project; 5 checkout failed; 6 a branch with
no PR; 7 timeout; 8 a runtime or model refused before the run. Any other code is
the agent CLI's own exit status.

## Scheduled jobs

A schedule is data. Give a spec in `scheduled/<name>.json` a `"schedule"` (5-field
cron) and a `"tz"`, and `cr-schedule` queues it on time from whichever worker
claims the slot first:

```json
{ "prompt": "…", "project": "…", "schedule": "0 6 * * *", "tz": "America/New_York",
  "catchup_min": 10, "enabled": true }
```

A late slot still fires within `catchup_min` minutes; `"enabled": false` pauses the
spec. The queued copy carries `"submitter": "schedule:<name>"`.

## Other folders

- `projects/registry.json`: the registered projects
- `projects/<name>/memory.md`: what jobs have learned about that project
- `workers/`: one heartbeat per worker; a dead worker's job is requeued once
- `processing/`: jobs in flight, each with an `.owner`

Any trigger can submit work by writing a job file into `inbox/`: a webhook, a Home
Assistant shell command, a cron line on another host.
