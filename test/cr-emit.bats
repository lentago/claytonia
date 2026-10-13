#!/usr/bin/env bats
#
# cr-emit event payloads: submitter (#21) rides as a log-line field on
# job_started, job_running and job_complete — never as a Loki stream label
# (it is per-session; as a label it would mint a stream per submitter).
# curl is faked, so no network is touched.

load test_helper

_fake_curl() {
  mkdir -p "$TEST_TMP/fakebin"
  cat > "$TEST_TMP/fakebin/curl" <<EOS
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done > "$TEST_TMP/curl.args"
exit 0
EOS
  chmod +x "$TEST_TMP/fakebin/curl"
  export PATH="$TEST_TMP/fakebin:$PATH"
  export LOKI_PUSH_URL="http://loki.invalid/push"
}

payload() { tail -n1 "$TEST_TMP/curl.args"; }
line()    { jq -r '.streams[0].values[0][1]' <<<"$(payload)"; }
labels()  { jq -r '.streams[0].stream | keys | join(",")' <<<"$(payload)"; }

@test "started/running: submitter is a line field, not a label" {
  _fake_curl
  for ev in started running; do
    run "$REPO_ROOT/bin/cr-emit" "$ev" R1 proj sonnet alice@laptop
    [ "$status" -eq 0 ]
    [ "$(jq -r .event <<<"$(line)")" = "job_$ev" ]
    [ "$(jq -r .submitter <<<"$(line)")" = alice@laptop ]
    [ "$(labels)" = "job,model,project,service,worker" ]
  done
}

@test "started/running: an absent submitter is an empty string" {
  _fake_curl
  run "$REPO_ROOT/bin/cr-emit" running R1 proj sonnet
  [ "$status" -eq 0 ]
  [ "$(jq -r '.submitter | tostring' <<<"$(line)")" = "" ]
}

@test "job_complete: submitter comes from the .meta, as a line field" {
  _fake_curl
  printf 'runid=R1\nexit=0\nproject=proj\nmodel=sonnet\nsubmitter=alice@laptop\n' > "$JOBS_ROOT/logs/R1.meta"
  run "$REPO_ROOT/bin/cr-emit" R1
  [ "$status" -eq 0 ]
  [ "$(jq -r .event <<<"$(line)")" = job_complete ]
  [ "$(jq -r .submitter <<<"$(line)")" = alice@laptop ]
  [ "$(labels)" = "job,model,project,service,status,worker" ]
}
