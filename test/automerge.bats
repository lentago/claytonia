#!/usr/bin/env bats
#
# cr-automerge (ADR-0009): the post-job merge decision. It may arm squash
# auto-merge only when the job named a rule, the repo's default branch defines
# it, and the PR fits it; every other case, and every error, disarms. A stub gh
# serves the policy, the PR and its files from the test's own fixtures.

load test_helper

REPO=acme/proj
URL=https://github.com/acme/proj/pull/9

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-am.XXXXXX")"
  mkdir -p "$TEST_TMP/bin"
  export FAKE_GH_LOG="$TEST_TMP/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_POLICY="$TEST_TMP/policy.json"
  export FAKE_PR="$TEST_TMP/pr.json"
  export FAKE_FILES="$TEST_TMP/files.tsv"
  cat > "$TEST_TMP/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
  "api repos/"*"/contents/.claytonia/automerge.json?ref=main --jq .content")
    [ -f "$FAKE_POLICY" ] || { echo "HTTP 404" >&2; exit 1; }
    base64 -w0 < "$FAKE_POLICY"; echo ;;
  "pr view "*) cat "$FAKE_PR" ;;
  "api --paginate repos/"*"/pulls/9/files "*) cat "$FAKE_FILES" ;;
  "pr merge "*) ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOS
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"

  cat > "$FAKE_POLICY" <<'EOF'
{"rules": {"brief": {"title": "^Add \\d{4}-\\d{2}-\\d{2} (morning|evening) briefing$",
                     "paths": ["notes/daily/*.md", "notes/events/*.md"]}}}
EOF
  pr OPEN false main app/lentago-claude-runner "Add 2026-10-28 morning briefing" acme proj
  printf 'notes/daily/2026-10-28.md\t\nnotes/events/2026-10-28.md\t\n' > "$FAKE_FILES"
}

teardown() { rm -rf "$TEST_TMP"; }

pr() { # <state> <draft> <base> <author> <title> <head-owner> <head-repo>
  jq -n --arg s "$1" --argjson d "$2" --arg b "$3" --arg a "$4" --arg t "$5" --arg o "$6" --arg r "$7" \
    '{number:9, state:$s, isDraft:$d, baseRefName:$b, author:{login:$a}, title:$t,
      headRepositoryOwner:{login:$o}, headRepository:{name:$r}}' > "$FAKE_PR"
}

decide() { # [rule] [rc]
  run "$REPO_ROOT/bin/cr-automerge" "$URL" "$REPO" main "${1-brief}" "${2:-0}"
}

armed()    { grep -q -- "pr merge $URL --auto --squash --delete-branch" "$FAKE_GH_LOG"; }
disarmed() { grep -q -- "pr merge $URL --disable-auto" "$FAKE_GH_LOG" && ! armed; }

@test "arms when the job named a rule and the PR fits it" {
  decide
  [ "$status" -eq 0 ]
  [ "$output" = "armed rule=brief" ]
  armed
}

@test "no rule named: disarmed, and the policy is never read" {
  decide ""
  [[ "$output" == "disarmed: no rule named"* ]]
  disarmed
  ! grep -q contents "$FAKE_GH_LOG"
}

@test "a failed job is never armed" {
  decide brief 1
  [[ "$output" == "disarmed: job exited 1" ]]
  disarmed
}

@test "no policy on the default branch: disarmed" {
  rm "$FAKE_POLICY"
  decide
  [[ "$output" == "disarmed: no readable policy on main"* ]]
  disarmed
}

@test "a rule the policy doesn't define: disarmed" {
  decide other
  [[ "$output" == "disarmed: policy has no rule 'other'" ]]
  disarmed
}

@test "a path outside the rule: disarmed" {
  printf 'notes/daily/2026-10-28.md\t\nREADME.md\t\n' > "$FAKE_FILES"
  decide
  [[ "$output" == "disarmed: path outside rule 'brief': README.md" ]]
  disarmed
}

@test "a rename's old path counts too" {
  printf 'notes/daily/x.md\tbin/run-job\n' > "$FAKE_FILES"
  decide
  [[ "$output" == *"path outside rule 'brief': bin/run-job" ]]
  disarmed
}

@test "* stays inside one directory" {
  printf 'notes/daily/sub/x.md\t\n' > "$FAKE_FILES"
  decide
  [[ "$output" == *"path outside rule"* ]]
  disarmed
}

@test "a title that doesn't match in full: disarmed" {
  pr OPEN false main app/lentago-claude-runner "Add 2026-10-28 morning briefing and more" acme proj
  decide
  [[ "$output" == "disarmed: title"* ]]
  disarmed
}

@test "a PR the runner App didn't author: disarmed" {
  pr OPEN false main someone "Add 2026-10-28 morning briefing" acme proj
  decide
  [[ "$output" == "disarmed: PR author someone is not the runner App" ]]
  disarmed
}

@test "a draft, a closed PR, another base or a fork head: disarmed" {
  pr OPEN true main app/lentago-claude-runner "Add 2026-10-28 morning briefing" acme proj
  decide; [[ "$output" == "disarmed: PR is a draft" ]]
  pr MERGED false main app/lentago-claude-runner "Add 2026-10-28 morning briefing" acme proj
  decide; [[ "$output" == "disarmed: PR is MERGED" ]]
  pr OPEN false dev app/lentago-claude-runner "Add 2026-10-28 morning briefing" acme proj
  decide; [[ "$output" == "disarmed: PR targets dev, not main" ]]
  pr OPEN false main app/lentago-claude-runner "Add 2026-10-28 morning briefing" fork proj
  decide; [[ "$output" == "disarmed: PR head is fork/proj, not acme/proj" ]]
  ! armed
}

@test "more files than the rule allows: disarmed" {
  jq '.rules.brief.max_files = 1' "$FAKE_POLICY" > "$FAKE_POLICY.new" && mv "$FAKE_POLICY.new" "$FAKE_POLICY"
  decide
  [[ "$output" == "disarmed: PR touches 2 paths, rule allows 1" ]]
  disarmed
}

@test "a PR that changes nothing: disarmed" {
  : > "$FAKE_FILES"
  decide
  [[ "$output" == "disarmed: PR changes no files" ]]
  disarmed
}
