#!/usr/bin/env bats
#
# Context-ledger tests: the snapshot sanitizer/secret-scan and the primary-only
# committer. Fixture-based and hermetic — a fake $HOME/.claude(.json), a tmpfs
# JOBS_ROOT, and a local bare repo standing in for lentago/myosotis. No network,
# no real secrets, no journald (a systemd-cat stub drains it). See
# docs/context-ledger.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SNAP="$REPO_ROOT/bin/context-snapshot"
  COMMIT="$REPO_ROOT/bin/context-ledger-commit"
  REPORT="$REPO_ROOT/bin/ledger-report"

  TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/claytonia-ledger.XXXXXX")"

  # systemd-cat stub on PATH so the scripts' journald logging is a no-op.
  mkdir -p "$TEST_TMP/bin"
  cp "$REPO_ROOT/test/stubs/systemd-cat" "$TEST_TMP/bin/systemd-cat"
  export PATH="$TEST_TMP/bin:$PATH"

  # Fake host-side Claude context.
  export HOME_DIR="$TEST_TMP/home"
  export CLAUDE_DIR="$HOME_DIR/.claude"
  export CLAUDE_JSON="$HOME_DIR/.claude.json"
  mkdir -p "$CLAUDE_DIR"

  export JOBS_ROOT="$TEST_TMP/jobs"
  mkdir -p "$JOBS_ROOT"
  export CONTEXT_HOSTNAME="test-worker"
  INCOMING="$JOBS_ROOT/context-ledger/incoming/$CONTEXT_HOSTNAME"

  # Stub the shared loki_push (no network): record every emitted event as
  # {labels, line} JSON to $LOKI_CAPTURE so tests can assert the JSON shape.
  # The committer sources LOKI_LIB in place of bin/cr-loki.sh.
  export LOKI_CAPTURE="$TEST_TMP/loki.jsonl"
  export LOKI_STUB="$TEST_TMP/loki-stub.sh"
  cat > "$LOKI_STUB" <<'STUB'
loki_push() {
  jq -cn --argjson s "$1" --arg line "$2" '{labels:$s, line:($line|fromjson)}' \
    >> "$LOKI_CAPTURE"
}
STUB
}

teardown() { [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"; }

run_snapshot() { HOME="$HOME_DIR" CLAUDE_DIR="$CLAUDE_DIR" CLAUDE_JSON="$CLAUDE_JSON" \
  JOBS_ROOT="$JOBS_ROOT" CONTEXT_HOSTNAME="$CONTEXT_HOSTNAME" run "$SNAP" "$@"; }

# --- sanitizer: derived claude.json holds KEY NAMES only, never values --------

@test "sanitizer: derived claude.json emits env/header key NAMES, no values" {
  cat > "$CLAUDE_JSON" <<'JSON'
{
  "mcpServers": {
    "gh":    {"type":"http","url":"https://mcp.example/","headers":{"Authorization":"Bearer HEADER_SECRET_VALUE"}},
    "local": {"type":"stdio","command":"node","args":["srv.js"],"env":{"MY_API_KEY":"ENV_SECRET_VALUE"}}
  },
  "oauthAccount": {"accessToken":"OAUTH_SECRET_VALUE","emailAddress":"a@b.c"},
  "projects": {"/w/x": {"history":["a secret prompt body"]}}
}
JSON

  run_snapshot
  [ "$status" -eq 0 ]

  d="$INCOMING/claude-json.derived.json"
  [ -f "$d" ]

  # key names present...
  grep -q 'MY_API_KEY' "$d"
  grep -q 'Authorization' "$d"
  # ...values, secrets, and prompt-history / account keys absent
  ! grep -q 'ENV_SECRET_VALUE' "$d"
  ! grep -q 'HEADER_SECRET_VALUE' "$d"
  ! grep -q 'OAUTH_SECRET_VALUE' "$d"
  ! grep -q 'oauthAccount' "$d"
  ! grep -q 'secret prompt body' "$d"

  # env/headers are arrays of key names
  [ "$(jq -rc '.mcpServers.local.env' "$d")" = '["MY_API_KEY"]' ]
  [ "$(jq -rc '.mcpServers.gh.headers' "$d")" = '["Authorization"]' ]
}

@test "sanitizer: unparseable claude.json yields a PARSE_ERROR marker, no raw copy" {
  printf '{ not valid json\n' > "$CLAUDE_JSON"
  run_snapshot
  [ "$status" -eq 0 ]
  [ -f "$INCOMING/claude-json.PARSE_ERROR" ]
  [ ! -f "$INCOMING/claude-json.derived.json" ]
  # the raw file's content never lands
  ! grep -rq 'not valid json' "$INCOMING"
}

# --- secret-scan: any planted secret aborts + quarantines ---------------------

@test "secret-scan: a planted token aborts the snapshot and quarantines" {
  mkdir -p "$CLAUDE_DIR/projects/proj-a/memory"
  printf 'token: ghp_0123456789abcdefABCDEF0123456789abcd\n' \
    > "$CLAUDE_DIR/projects/proj-a/memory/leak.md"

  run_snapshot
  [ "$status" -ne 0 ]

  # quarantine slot published; the offending body is NOT there
  [ -f "$INCOMING/QUARANTINE.txt" ]
  [ ! -f "$INCOMING/claude/projects/proj-a/memory/leak.md" ]
  # QUARANTINE.txt names the path:line but NEVER the matched secret
  grep -q 'leak.md' "$INCOMING/QUARANTINE.txt"
  ! grep -q 'ghp_' "$INCOMING/QUARANTINE.txt"
  # meta records the quarantine
  [ "$(jq -r '.status' "$INCOMING/meta.json")" = "quarantined" ]
}

@test "secret-scan: a planted PRIVATE KEY block also aborts" {
  mkdir -p "$CLAUDE_DIR/projects/proj-b/memory"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb64\n-----END-----\n' \
    > "$CLAUDE_DIR/projects/proj-b/memory/key.md"
  run_snapshot
  [ "$status" -ne 0 ]
  [ -f "$INCOMING/QUARANTINE.txt" ]
}

# --- path denylist: a staged sensitive filename aborts ------------------------

@test "denylist: a staged *.pem file aborts the snapshot" {
  mkdir -p "$CLAUDE_DIR/projects/proj-c/memory"
  printf 'innocuous body\n' > "$CLAUDE_DIR/projects/proj-c/memory/oops.pem"
  run_snapshot
  [ "$status" -ne 0 ]
  [ -f "$INCOMING/QUARANTINE.txt" ]
  grep -qi 'denylist' "$INCOMING/QUARANTINE.txt"
}

# --- clean snapshot shape -----------------------------------------------------

@test "clean snapshot: publishes CLAUDE.md, MANIFEST, meta(ok)" {
  printf '# global rules\n' > "$CLAUDE_DIR/CLAUDE.md"
  printf '{"a":1}\n'        > "$CLAUDE_DIR/settings.json"
  mkdir -p "$CLAUDE_DIR/skills/demo"
  printf '# demo skill\n'   > "$CLAUDE_DIR/skills/demo/SKILL.md"
  printf 'x\n'              > "$CLAUDE_DIR/skills/demo/helper.py"

  run_snapshot
  [ "$status" -eq 0 ]

  [ -f "$INCOMING/claude/CLAUDE.md" ]
  [ -f "$INCOMING/claude/skills/demo/SKILL.md" ]
  # non-SKILL.md files are hash-manifested, never copied verbatim
  [ -f "$INCOMING/claude/skills/demo/OTHER-FILES.sha256" ]
  [ ! -f "$INCOMING/claude/skills/demo/helper.py" ]
  grep -q 'helper.py' "$INCOMING/claude/skills/demo/OTHER-FILES.sha256"

  [ -f "$INCOMING/MANIFEST.sha256" ]
  [ "$(jq -r '.status' "$INCOMING/meta.json")" = "ok" ]
  [ "$(jq -r '.hostname' "$INCOMING/meta.json")" = "test-worker" ]
}

@test "versions: claude_version captured from a stub on PATH" {
  # Verify that context-snapshot picks up the version string when claude
  # is reachable on PATH — the fix for #89 (context-snapshot.service lacked
  # Environment=PATH including ~/.local/bin where claude installs).
  cat > "$TEST_TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "2.1.226 (Claude Code)"
STUB
  chmod +x "$TEST_TMP/bin/claude"

  run_snapshot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.claude_version' "$INCOMING/meta.json")" = "2.1.226 (Claude Code)" ]

  rm -f "$TEST_TMP/bin/claude"
}

@test "memory=hash: emits a manifest with no bodies" {
  mkdir -p "$CLAUDE_DIR/projects/proj-d/memory"
  printf 'durable note\n' > "$CLAUDE_DIR/projects/proj-d/memory/notes.md"

  run_snapshot --memory=hash
  [ "$status" -eq 0 ]
  [ -f "$INCOMING/claude/projects/proj-d/memory.manifest" ]
  [ ! -f "$INCOMING/claude/projects/proj-d/memory/notes.md" ]
  grep -q 'notes.md' "$INCOMING/claude/projects/proj-d/memory.manifest"
  ! grep -rq 'durable note' "$INCOMING"
}

# --- committer ----------------------------------------------------------------

seed_remote() {
  REMOTE="$TEST_TMP/myosotis.git"
  # -b main: pin the bare repo's HEAD. Without it the runner's git may default
  # HEAD to an unborn "master" while the seed pushes "main", and any
  # `git -C $REMOTE log` assertion dies on the dangling HEAD.
  git init -q --bare -b main "$REMOTE"
  local seed="$TEST_TMP/seed"
  git clone -q "$REMOTE" "$seed"
  ( cd "$seed"
    printf '# myosotis ledger\n' > README.md
    git -c user.email=t@t -c user.name=t add README.md
    git -c user.email=t@t -c user.name=t commit -q -m init
    git push -q origin HEAD:main )
  CLONE="$TEST_TMP/clone"
  KEY="$TEST_TMP/key"; : > "$KEY"; chmod 600 "$KEY"
}

run_commit() { LEDGER_REMOTE="$REMOTE" LEDGER_CLONE_DIR="$CLONE" LEDGER_DEPLOY_KEY="$KEY" \
  JOBS_ROOT="$JOBS_ROOT" CONTEXT_HOSTNAME="$CONTEXT_HOSTNAME" \
  PRIMARY_MARKER="${MARKER:-$JOBS_ROOT/context-ledger/primary}" \
  LOKI_LIB="${LOKI_LIB_OVERRIDE:-$LOKI_STUB}" LOKI_CAPTURE="$LOKI_CAPTURE" \
  CONTEXT_STALE_S="${CONTEXT_STALE_S:-}" run "$COMMIT"; }

# Collapse the captured event stream to the lines matching one event type.
captured_events() { jq -c "select(.line.event==\"$1\")" "$LOKI_CAPTURE"; }

@test "committer: non-primary host is a silent no-op" {
  seed_remote
  mkdir -p "$JOBS_ROOT/context-ledger"
  printf 'some-other-host\n' > "$JOBS_ROOT/context-ledger/primary"
  mkdir -p "$INCOMING"; printf 'x\n' > "$INCOMING/meta.json"

  run_commit
  [ "$status" -eq 0 ]
  [ ! -d "$CLONE" ]                 # never cloned
  [ -d "$INCOMING" ]               # incoming untouched
}

@test "committer: missing deploy key fails loudly, leaves incoming queued" {
  seed_remote
  mkdir -p "$JOBS_ROOT/context-ledger"
  printf '%s\n' "$CONTEXT_HOSTNAME" > "$JOBS_ROOT/context-ledger/primary"
  mkdir -p "$INCOMING"; printf 'x\n' > "$INCOMING/meta.json"
  rm -f "$KEY"   # no key

  run_commit
  [ "$status" -ne 0 ]
  [ -d "$INCOMING" ]
}

@test "committer: sweeps a host into the ledger, commits, and clears incoming" {
  seed_remote
  mkdir -p "$JOBS_ROOT/context-ledger"
  printf '%s\n' "$CONTEXT_HOSTNAME" > "$JOBS_ROOT/context-ledger/primary"
  mkdir -p "$INCOMING/claude"
  printf '# rules\n' > "$INCOMING/claude/CLAUDE.md"
  printf '{"status":"ok"}\n' > "$INCOMING/meta.json"

  run_commit
  [ "$status" -eq 0 ]

  # incoming for the swept host is cleared on success
  [ ! -d "$INCOMING" ]
  # the ledger repo now carries hosts/<host>/... and the commit message form
  git -C "$CLONE" log -1 --format='%s' | grep -q "ledger($CONTEXT_HOSTNAME):"
  [ -f "$CLONE/hosts/$CONTEXT_HOSTNAME/claude/CLAUDE.md" ]
  # and it was pushed to the remote
  git -C "$REMOTE" log -1 --format='%s' | grep -q "ledger($CONTEXT_HOSTNAME):"
}

@test "committer: a re-run with no new data makes no second commit" {
  seed_remote
  mkdir -p "$JOBS_ROOT/context-ledger"
  printf '%s\n' "$CONTEXT_HOSTNAME" > "$JOBS_ROOT/context-ledger/primary"
  mkdir -p "$INCOMING/claude"; printf '# rules\n' > "$INCOMING/claude/CLAUDE.md"
  printf '{"status":"ok"}\n' > "$INCOMING/meta.json"
  run_commit; [ "$status" -eq 0 ]
  before="$(git -C "$CLONE" rev-list --count HEAD)"

  # same content again -> rsync produces no diff -> no new commit
  mkdir -p "$INCOMING/claude"; printf '# rules\n' > "$INCOMING/claude/CLAUDE.md"
  printf '{"status":"ok"}\n' > "$INCOMING/meta.json"
  run_commit; [ "$status" -eq 0 ]
  after="$(git -C "$CLONE" rev-list --count HEAD)"
  [ "$before" = "$after" ]
  [ ! -d "$INCOMING" ]
}

# --- committer: visibility events (context_sweep / context_host) --------------
# The emitted JSON is a cross-repo CONTRACT (drosera dashboards/alerts query it);
# these assert its shape against a stubbed loki_push. See docs/context-ledger.md.

@test "emit: a sweep with changes emits one context_sweep + one context_host (contract shape)" {
  seed_remote
  mkdir -p "$JOBS_ROOT/context-ledger"
  printf '%s\n' "$CONTEXT_HOSTNAME" > "$JOBS_ROOT/context-ledger/primary"

  mkdir -p "$INCOMING/claude/skills/demo" "$INCOMING/claude/projects/proj/memory"
  printf '# rules\n'      > "$INCOMING/claude/CLAUDE.md"
  printf '# demo\n'       > "$INCOMING/claude/skills/demo/SKILL.md"
  printf 'durable note\n' > "$INCOMING/claude/projects/proj/memory/note.md"
  now="$(date -u +%FT%TZ)"
  jq -n --arg ts "$now" '{hostname:"test-worker", timestamp_utc:$ts,
    claude_version:"1.2.3", script_rev:"1", memory_mode:"full", status:"ok"}' \
    > "$INCOMING/meta.json"

  run_commit
  [ "$status" -eq 0 ]

  [ "$(captured_events context_sweep | wc -l)" -eq 1 ]
  [ "$(captured_events context_host  | wc -l)" -eq 1 ]

  sweep="$(captured_events context_sweep)"
  [ "$(jq -r '.line.swept'           <<<"$sweep")" = 1 ]
  [ "$(jq -r '.line.changed'         <<<"$sweep")" = 1 ]
  [ "$(jq -r '.line.quarantined'     <<<"$sweep")" = 0 ]
  [ "$(jq -r '.line.duration_s|type' <<<"$sweep")" = number ]
  [ "$(jq -r '.labels.job'           <<<"$sweep")" = claude_runner ]
  [ "$(jq -r '.labels.service'       <<<"$sweep")" = context_ledger ]

  host="$(captured_events context_host)"
  [ "$(jq -r '.labels.job'               <<<"$host")" = claude_runner ]
  [ "$(jq -r '.labels.service'           <<<"$host")" = context_ledger ]
  [ "$(jq -r '.labels.host'              <<<"$host")" = test-worker ]
  [ "$(jq -r '.line.host'                <<<"$host")" = test-worker ]
  [ "$(jq -r '.line.status'              <<<"$host")" = ok ]
  [ "$(jq -r '.line.memory_mode'         <<<"$host")" = full ]
  [ "$(jq -r '.line.claude_version'      <<<"$host")" = 1.2.3 ]
  [ "$(jq -r '.line.skills_count'        <<<"$host")" = 1 ]
  [ "$(jq -r '.line.memory_files'        <<<"$host")" = 1 ]
  [ "$(jq -r '.line.files_changed|type'  <<<"$host")" = number ]
  [ "$(jq -r '.line.files_changed'       <<<"$host")" -gt 0 ]
  [ "$(jq -r '.line.total_bytes'         <<<"$host")" -gt 0 ]
  [ "$(jq -r '.line.memory_bytes'        <<<"$host")" -gt 0 ]
  [ "$(jq -r '.line.snapshot_age_s|type' <<<"$host")" = number ]
  [ "$(jq -r '.line.snapshot_age_s'      <<<"$host")" -ge 0 ]
  # commit is the host's latest short sha in the ledger
  [ "$(jq -r '.line.commit' <<<"$host")" = "$(git -C "$CLONE" log -1 --format=%h -- hosts/test-worker)" ]
}

@test "emit: a host present in the ledger but absent from incoming still emits context_host (files_changed=0)" {
  seed_remote
  mkdir -p "$JOBS_ROOT/context-ledger"
  printf '%s\n' "$CONTEXT_HOSTNAME" > "$JOBS_ROOT/context-ledger/primary"

  # First sweep populates hosts/test-worker in the ledger.
  mkdir -p "$INCOMING/claude"; printf '# rules\n' > "$INCOMING/claude/CLAUDE.md"
  now="$(date -u +%FT%TZ)"
  jq -n --arg ts "$now" '{hostname:"test-worker", timestamp_utc:$ts,
    claude_version:"9.9.9", script_rev:"1", memory_mode:"full", status:"ok"}' \
    > "$INCOMING/meta.json"
  run_commit; [ "$status" -eq 0 ]; [ ! -d "$INCOMING" ]

  # Second sweep: incoming empty — the host is unswept but still in the clone.
  : > "$LOKI_CAPTURE"
  run_commit; [ "$status" -eq 0 ]

  [ "$(captured_events context_host | wc -l)" -eq 1 ]
  host="$(captured_events context_host)"
  [ "$(jq -r '.line.host'                <<<"$host")" = test-worker ]
  [ "$(jq -r '.line.files_changed'       <<<"$host")" = 0 ]
  [ "$(jq -r '.line.claude_version'      <<<"$host")" = 9.9.9 ]
  [ "$(jq -r '.line.snapshot_age_s|type' <<<"$host")" = number ]

  sweep="$(captured_events context_sweep)"
  [ "$(jq -r '.line.swept'   <<<"$sweep")" = 0 ]
  [ "$(jq -r '.line.changed' <<<"$sweep")" = 0 ]
}

@test "emit: a quarantined slot yields status=quarantined" {
  seed_remote
  mkdir -p "$JOBS_ROOT/context-ledger"
  printf '%s\n' "$CONTEXT_HOSTNAME" > "$JOBS_ROOT/context-ledger/primary"

  mkdir -p "$INCOMING"
  printf 'CONTEXT SNAPSHOT QUARANTINED\nhost: test-worker\n' > "$INCOMING/QUARANTINE.txt"
  now="$(date -u +%FT%TZ)"
  jq -n --arg ts "$now" '{hostname:"test-worker", timestamp_utc:$ts,
    claude_version:"1.0.0", script_rev:"1", memory_mode:"full", status:"quarantined"}' \
    > "$INCOMING/meta.json"

  run_commit
  [ "$status" -eq 0 ]

  [ "$(jq -r '.line.quarantined' <<<"$(captured_events context_sweep)")" = 1 ]
  [ "$(jq -r '.line.status'      <<<"$(captured_events context_host)")" = quarantined ]
}

@test "emit: a snapshot older than CONTEXT_STALE_S yields status=stale" {
  seed_remote
  mkdir -p "$JOBS_ROOT/context-ledger"
  printf '%s\n' "$CONTEXT_HOSTNAME" > "$JOBS_ROOT/context-ledger/primary"

  mkdir -p "$INCOMING/claude"; printf '# rules\n' > "$INCOMING/claude/CLAUDE.md"
  jq -n '{hostname:"test-worker", timestamp_utc:"2000-01-01T00:00:00Z",
    claude_version:"1.0.0", script_rev:"1", memory_mode:"full", status:"ok"}' \
    > "$INCOMING/meta.json"

  CONTEXT_STALE_S=100 run_commit
  [ "$status" -eq 0 ]

  host="$(captured_events context_host)"
  [ "$(jq -r '.line.status'         <<<"$host")" = stale ]
  [ "$(jq -r '.line.snapshot_age_s' <<<"$host")" -gt 100 ]
}

@test "emit: a loki push failure never fails the sweep" {
  seed_remote
  mkdir -p "$JOBS_ROOT/context-ledger"
  printf '%s\n' "$CONTEXT_HOSTNAME" > "$JOBS_ROOT/context-ledger/primary"

  mkdir -p "$INCOMING/claude"; printf '# rules\n' > "$INCOMING/claude/CLAUDE.md"
  printf '{"status":"ok"}\n' > "$INCOMING/meta.json"

  # A push that always fails must not change the sweep exit code or block the commit.
  fail_stub="$TEST_TMP/loki-fail.sh"
  printf 'loki_push(){ return 1; }\n' > "$fail_stub"

  LOKI_LIB_OVERRIDE="$fail_stub" run_commit
  [ "$status" -eq 0 ]
  git -C "$CLONE" log -1 --format='%s' | grep -q "ledger($CONTEXT_HOSTNAME):"
}

# --- ledger-report -----------------------------------------------------------
# Fixture: a local clone with two hosts and two commits for alpha (one old,
# one recent) so we can assert summary output and --since filtering.

setup_report_clone() {
  LREMOTE="$TEST_TMP/myosotis-report.git"
  LCLONE="$TEST_TMP/myosotis-report"
  git init -q --bare -b main "$LREMOTE"
  git clone -q "$LREMOTE" "$LCLONE"
  (
    cd "$LCLONE"
    git config user.email "t@t"
    git config user.name "t"
    mkdir -p hosts/alpha hosts/beta

    # alpha: old commit (2026-07-01, ~39 days before test date)
    printf '{"status":"ok","hostname":"alpha","timestamp_utc":"2026-07-01T10:00:00Z"}\n' \
      > hosts/alpha/meta.json
    git add hosts/alpha/meta.json
    GIT_COMMITTER_DATE="2026-07-01T10:00:00 +0000" \
      git commit -q --date="2026-07-01T10:00:00 +0000" -m "ledger(alpha): 1 files changed"

    # beta: commit with quarantine (2026-08-08)
    printf '{"status":"quarantined","hostname":"beta","timestamp_utc":"2026-08-08T10:00:00Z"}\n' \
      > hosts/beta/meta.json
    printf 'DENYLIST: hosts/beta/claude/oops.pem:1\n' > hosts/beta/QUARANTINE.txt
    git add hosts/beta/
    GIT_COMMITTER_DATE="2026-08-08T10:00:00 +0000" \
      git commit -q --date="2026-08-08T10:00:00 +0000" -m "ledger(beta): 2 files changed"

    # alpha: recent drift commit (2026-08-08)
    printf '{"status":"ok","hostname":"alpha","timestamp_utc":"2026-08-08T10:00:00Z"}\n' \
      > hosts/alpha/meta.json
    printf '# updated rules\n' > hosts/alpha/CLAUDE.md
    git add hosts/alpha/
    GIT_COMMITTER_DATE="2026-08-08T10:00:00 +0000" \
      git commit -q --date="2026-08-08T10:00:00 +0000" -m "ledger(alpha): 2 files changed"

    git push -q origin main
  )
}

run_report() { LEDGER_CLONE_DIR="$LCLONE" run "$REPORT" "$@"; }

@test "ledger-report: summary shows all hosts" {
  setup_report_clone
  run_report
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'alpha'
  printf '%s\n' "$output" | grep -q 'beta'
}

@test "ledger-report: summary flags quarantined status for beta" {
  setup_report_clone
  run_report
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep 'beta' | grep -q 'quarantined'
}

@test "ledger-report: --host lists commits with changed-file lists" {
  setup_report_clone
  run_report --host alpha
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^commit'
  printf '%s\n' "$output" | grep -q 'hosts/alpha'
}

@test "ledger-report: --host --since filters to commits after the cutoff" {
  setup_report_clone
  # Cutoff 2026-07-26 excludes the 2026-07-01 commit but includes 2026-08-08.
  run_report --host alpha --since 2026-07-26
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q  'ledger(alpha): 2 files'
  ! printf '%s\n' "$output" | grep -q 'ledger(alpha): 1 files'
}

@test "ledger-report: --host --diff emits patch output" {
  setup_report_clone
  run_report --host beta --diff
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^commit'
}

@test "ledger-report: --quarantines lists beta quarantine with body" {
  setup_report_clone
  run_report --quarantines
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'host: beta'
  printf '%s\n' "$output" | grep -q 'DENYLIST'
}

@test "ledger-report: missing clone dir fails loudly" {
  LEDGER_CLONE_DIR="$TEST_TMP/nonexistent" run "$REPORT"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'ledger-report:'
}

@test "ledger-report: unknown host fails loudly" {
  setup_report_clone
  run_report --host no-such-host
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'ledger-report:'
}
