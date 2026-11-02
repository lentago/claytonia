#!/usr/bin/env bats
#
# gh-token mints installation tokens limited to one repository and to the access
# profile its caller names (#176). A stub curl stands in for the GitHub API and
# records each request; the App key is a throwaway generated per test.

load test_helper

APP_PERMS='{"contents":"write","issues":"write","metadata":"read","pull_requests":"write","workflows":"write"}'

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-ghtoken.XXXXXX")"
  openssl genrsa -out "$TEST_TMP/app.pem" 2048 2>/dev/null
  printf 'APP_ID=4242\nINSTALLATION_ID=900\n' > "$TEST_TMP/app.env"
  export GH_APP_ENV="$TEST_TMP/app.env" GH_APP_PEM="$TEST_TMP/app.pem"
  export FAKE_CURL_LOG="$TEST_TMP/curl.log"; : > "$FAKE_CURL_LOG"
  unset GH_REPO
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl for gh-token: logs "<METHOD> <url> <body>" and answers like the API,
# and its first argument to $FAKE_CURL_LOG.first.
printf '%s\n' "$1" >> "$FAKE_CURL_LOG.first"
method=GET; body=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -d) body="$2"; shift ;;
    -H) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s %s\n' "$method" "$url" "$body" >> "$FAKE_CURL_LOG"
case "$url" in
  */installation) [ -n "${FAKE_CURL_NO_LOOKUP:-}" ] && exit 22; echo '{"id": 111}' ;;
  */access_tokens) [ -n "${FAKE_CURL_NO_TOKEN:-}" ] && { echo '{}'; exit 0; }; echo '{"token": "ghs_test"}' ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$TEST_TMP/bin/curl"
  export PATH="$TEST_TMP/bin:$PATH"
}

mint_body() { awk '$1 == "POST" { $1 = ""; $2 = ""; sub(/^  /, ""); print }' "$FAKE_CURL_LOG" | tail -1; }
mint_url()  { awk '$1 == "POST" { print $2 }' "$FAKE_CURL_LOG" | tail -1; }

@test "a project job's default token: its repo only, the job profile, its own installation" {
  export GH_REPO=lentago/claytonia
  run "$REPO_ROOT/bin/gh-token"
  [ "$status" -eq 0 ]
  [ "$output" = ghs_test ]
  grep -q '^GET https://api.github.com/repos/lentago/claytonia/installation' "$FAKE_CURL_LOG"
  [ "$(mint_url)" = https://api.github.com/app/installations/111/access_tokens ]
  mint_body | jq -e '.repositories == ["claytonia"]
    and .permissions == {"contents":"write","issues":"write","metadata":"read","pull_requests":"write"}'
}

@test "each profile asks for exactly its permissions, for the named repo" {
  want() { # <profile> <permissions json>
    : > "$FAKE_CURL_LOG"
    run "$REPO_ROOT/bin/gh-token" --access "$1" acme/proj
    [ "$status" -eq 0 ]
    mint_body | jq -e --argjson p "$2" '.repositories == ["proj"] and .permissions == $p'
  }
  want job           '{"contents":"write","issues":"write","metadata":"read","pull_requests":"write"}'
  want job-workflows '{"contents":"write","issues":"write","metadata":"read","pull_requests":"write","workflows":"write"}'
  want comment       '{"issues":"write","metadata":"read"}'
  want read          '{"contents":"read","issues":"read","metadata":"read","pull_requests":"read"}'
  want merge         '{"contents":"write","metadata":"read","pull_requests":"write"}'
}

@test "no profile asks for a permission the App lacks, or above the level it holds" {
  rank() { case "$1" in read) echo 1 ;; write) echo 2 ;; esac; }
  for p in job job-workflows comment read merge; do
    : > "$FAKE_CURL_LOG"
    "$REPO_ROOT/bin/gh-token" --access "$p" acme/proj >/dev/null
    mint_body | jq -e --argjson app "$APP_PERMS" '
      .permissions | to_entries | all(.key as $k | $app | has($k))' >/dev/null
    while IFS=$'\t' read -r k lvl; do
      [ "$(rank "$lvl")" -le "$(rank "$(jq -nr --argjson app "$APP_PERMS" --arg k "$k" '$app[$k]')")" ]
    done < <(mint_body | jq -r '.permissions | to_entries[] | "\(.key)\t\(.value)"')
  done
}

@test "no write token is minted for a whole installation" {
  for p in job job-workflows comment merge; do
    : > "$FAKE_CURL_LOG"
    run "$REPO_ROOT/bin/gh-token" --access "$p"
    [ "$status" -eq 2 ]
    [[ "$output" == *"needs owner/repo"* ]]
    [ ! -s "$FAKE_CURL_LOG" ]
  done
}

@test "with no repo at all, the token is read-only, across the default installation" {
  run "$REPO_ROOT/bin/gh-token"
  [ "$status" -eq 0 ]
  [ "$(mint_url)" = https://api.github.com/app/installations/900/access_tokens ]
  mint_body | jq -e '(has("repositories") | not)
    and .permissions == {"contents":"read","issues":"read","metadata":"read","pull_requests":"read"}'
}

@test "an unknown profile, a malformed repo, or a stray argument is refused before any request" {
  run "$REPO_ROOT/bin/gh-token" --access admin acme/proj
  [ "$status" -eq 2 ]
  run "$REPO_ROOT/bin/gh-token" 'acme/proj/../x'
  [ "$status" -eq 2 ]
  run "$REPO_ROOT/bin/gh-token" acme/proj extra
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_CURL_LOG" ]
}

@test "a failed installation lookup falls back to INSTALLATION_ID; a mint with no token fails" {
  export FAKE_CURL_NO_LOOKUP=1
  run "$REPO_ROOT/bin/gh-token" acme/proj
  [ "$status" -eq 0 ]
  [ "$(mint_url)" = https://api.github.com/app/installations/900/access_tokens ]
  unset FAKE_CURL_NO_LOOKUP
  export FAKE_CURL_NO_TOKEN=1
  run "$REPO_ROOT/bin/gh-token" acme/proj
  [ "$status" -eq 1 ]
  [[ "$output" == *"returned no token"* ]]
}

@test "the credential helper passes the job's profile through, and nothing when there is none" {
  export FAKE_GH_TOKEN_LOG="$TEST_TMP/ght.log" GH_TOKEN_BIN="$STUBS_DIR/gh-token"
  run bash -c "printf 'protocol=https\nhost=github.com\n' | GH_TOKEN_ACCESS=job-workflows '$REPO_ROOT/bin/gh-credential-helper' get"
  [ "$status" -eq 0 ]
  [[ "$output" == *"password=stub-token"* ]]
  run bash -c "printf 'protocol=https\nhost=github.com\n' | '$REPO_ROOT/bin/gh-credential-helper' get"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$FAKE_GH_TOKEN_LOG")" = "--access job-workflows" ]
  [ "$(sed -n 2p "$FAKE_GH_TOKEN_LOG")" = "" ]
}

# --- The broker (#177): the agent user cannot read the key, so gh-token runs itself
# again as root through its one sudoers rule. A stub sudo records how it was asked.
stub_sudo() {
  cat > "$TEST_TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SUDO_LOG"; echo ghs_via_sudo
STUB
  chmod +x "$TEST_TMP/bin/sudo"
  export FAKE_SUDO_LOG="$TEST_TMP/sudo.log" GH_TOKEN_SUDO="$TEST_TMP/bin/sudo"; : > "$FAKE_SUDO_LOG"
}

@test "a user who cannot read the key mints through sudo, naming the profile and the repo" {
  [ "$EUID" -ne 0 ] || skip "root reads every file"
  stub_sudo; chmod 000 "$GH_APP_PEM"
  GH_REPO=lentago/claytonia run "$REPO_ROOT/bin/gh-token"
  [ "$status" -eq 0 ] && [ "$output" = ghs_via_sudo ]
  [ "$(cat "$FAKE_SUDO_LOG")" = "-n /opt/claude-runner/bin/gh-token --access job lentago/claytonia" ]
  : > "$FAKE_SUDO_LOG"
  run "$REPO_ROOT/bin/gh-token" --access merge acme/proj
  [ "$(cat "$FAKE_SUDO_LOG")" = "-n /opt/claude-runner/bin/gh-token --access merge acme/proj" ]
  : > "$FAKE_SUDO_LOG"
  run "$REPO_ROOT/bin/gh-token"
  [ "$(cat "$FAKE_SUDO_LOG")" = "-n /opt/claude-runner/bin/gh-token --access read" ]
  [ ! -s "$FAKE_CURL_LOG" ]
}

@test "a request gh-token refuses never reaches sudo; a missing key is reported, not brokered" {
  [ "$EUID" -ne 0 ] || skip "root reads every file"
  stub_sudo; chmod 000 "$GH_APP_PEM"
  run "$REPO_ROOT/bin/gh-token" --access admin acme/proj
  [ "$status" -eq 2 ]
  run "$REPO_ROOT/bin/gh-token" --access job
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_SUDO_LOG" ]
  export GH_APP_PEM="$TEST_TMP/absent.pem"
  run "$REPO_ROOT/bin/gh-token" acme/proj
  [ "$status" -eq 1 ] && [[ "$output" == *"missing/empty"* ]]
  [ ! -s "$FAKE_SUDO_LOG" ]
}

@test "the App config is read for its two numbers and never run" {
  printf '# GitHub App: test\nAPP_ID="4242"\n$(touch %s/ran)\nINSTALLATION_ID=900\n' "$TEST_TMP" > "$GH_APP_ENV"
  run "$REPO_ROOT/bin/gh-token"
  [ "$status" -eq 0 ] && [ "$output" = ghs_test ]
  [ "$(mint_url)" = https://api.github.com/app/installations/900/access_tokens ]
  [ ! -e "$TEST_TMP/ran" ]
  printf 'APP_ID=\n' > "$GH_APP_ENV"
  run "$REPO_ROOT/bin/gh-token"
  [ "$status" -eq 1 ] && [[ "$output" == *"APP_ID not set"* ]]
}

@test "every API call tells curl to skip any .curlrc (-q must come first)" {
  run "$REPO_ROOT/bin/gh-token" acme/proj
  [ "$status" -eq 0 ]
  [ "$(sort -u "$FAKE_CURL_LOG.first")" = -q ]
}
