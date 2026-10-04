#!/usr/bin/env bats
#
# `cr-emit alive` (#110): the worker_alive liveness event drosera counts.
# curl is faked, so no network is touched.

load test_helper

_fake_curl() { # <exit-status>
  mkdir -p "$TEST_TMP/fakebin"
  cat > "$TEST_TMP/fakebin/curl" <<EOF
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done > "$TEST_TMP/curl.args"
exit $1
EOF
  chmod +x "$TEST_TMP/fakebin/curl"
  export PATH="$TEST_TMP/fakebin:$PATH"
  export LOKI_PUSH_URL="http://loki.invalid/push"
}

@test "alive: worker_alive in the log body, existing stream labels only" {
  _fake_curl 0
  run "$REPO_ROOT/bin/cr-emit" alive
  [ "$status" -eq 0 ]
  payload="$(tail -n1 "$TEST_TMP/curl.args")"
  [ "$(jq -r '.streams[0].stream | keys | join(",")' <<<"$payload")" = "job,service" ]
  [ "$(jq -r '.streams[0].stream.job' <<<"$payload")" = "claude_runner" ]
  line="$(jq -r '.streams[0].values[0][1]' <<<"$payload")"
  [ "$(jq -r .event <<<"$line")" = "worker_alive" ]
  [ "$(jq -r .worker <<<"$line")" = "$(hostname)" ]
  [ -n "$(jq -r .timestamp <<<"$line")" ]
}

@test "alive: a failed Loki push still exits 0" {
  _fake_curl 7
  run "$REPO_ROOT/bin/cr-emit" alive
  [ "$status" -eq 0 ]
}
