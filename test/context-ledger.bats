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
  PRIMARY_MARKER="${MARKER:-$JOBS_ROOT/context-ledger/primary}" run "$COMMIT"; }

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
