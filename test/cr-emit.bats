#!/usr/bin/env bats
#
# cr-emit event payloads: submitter (#21) rides as a log-line field on
# job_started, job_running and job_complete — never as a Loki stream label
# (it is per-session; as a label it would mint a stream per submitter).
# runtime (#173) is a stream label on all three, and a line field too; the five
# token counts and tokens_by_model are job_complete line fields, never labels; an
# unknown cost is null, never 0. curl is faked, so no network is touched.

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
    [ "$(labels)" = "job,model,project,runtime,service,worker" ]
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
  [ "$(labels)" = "job,model,project,runtime,service,status,worker" ]
}

stream()  { jq -c '.streams[0].stream' <<<"$(payload)"; }

@test "started/running: runtime is a stream label and a line field; an absent one is claude" {
  _fake_curl
  for ev in started running; do
    run "$REPO_ROOT/bin/cr-emit" "$ev" R1 proj gemini-3.8-flash alice@laptop gemini
    [ "$status" -eq 0 ]
    [ "$(jq -r .runtime <<<"$(stream)")" = gemini ]
    [ "$(jq -r .runtime <<<"$(line)")" = gemini ]
    for rt in "" absent; do
      if [ "$rt" = absent ]; then run "$REPO_ROOT/bin/cr-emit" "$ev" R1 proj sonnet alice@laptop
      else run "$REPO_ROOT/bin/cr-emit" "$ev" R1 proj sonnet alice@laptop ""; fi
      [ "$status" -eq 0 ]
      [ "$(jq -r .runtime <<<"$(stream)")" = claude ]
      [ "$(jq -r .runtime <<<"$(line)")" = claude ]
    done
  done
}

@test "job_complete: runtime, the five token counts and tokens_by_model from the .meta; tokens are line fields only" {
  _fake_curl
  printf '%s\n' runid=R1 exit=0 project=proj model=default cost_usd= runtime=gemini \
    tokens_in=113481 tokens_cached=771573 tokens_cache_write= tokens_out=2906 tokens_thinking=6672 \
    'tokens_by_model={"gemini-3.5-flash-lite":{"in":10015,"cached":0,"cache_write":null,"out":165,"thinking":1211},"gemini-3.8-flash":{"in":103466,"cached":771573,"cache_write":null,"out":2741,"thinking":5461}}' \
    > "$JOBS_ROOT/logs/R1.meta"
  run "$REPO_ROOT/bin/cr-emit" R1
  [ "$status" -eq 0 ]
  [ "$(jq -r .runtime <<<"$(stream)")" = gemini ]
  jq -e '.runtime == "gemini" and .tokens_in == 113481 and .tokens_cached == 771573
         and .tokens_cache_write == null and .tokens_out == 2906 and .tokens_thinking == 6672
         and .tokens_by_model["gemini-3.8-flash"] == {in: 103466, cached: 771573, cache_write: null, out: 2741, thinking: 5461}
         and (.tokens_by_model | keys) == ["gemini-3.5-flash-lite","gemini-3.8-flash"]' <<<"$(line)"
  [ "$(labels)" = "job,model,project,runtime,service,status,worker" ]
}

@test "job_complete: a blank or malformed tokens_by_model is null" {
  _fake_curl
  for v in '' 'not json' '[1,2]' '"gpt"'; do
    printf '%s\n' runid=R1 exit=0 project=proj model=sonnet "tokens_by_model=$v" > "$JOBS_ROOT/logs/R1.meta"
    run "$REPO_ROOT/bin/cr-emit" R1
    [ "$status" -eq 0 ]
    jq -e '.tokens_by_model == null' <<<"$(line)"
  done
}

@test "job_complete: a blank token count is null; a .meta with no runtime line is claude" {
  _fake_curl
  printf '%s\n' runid=R1 exit=0 project=proj model=sonnet cost_usd=0.25 \
    tokens_in=12 tokens_cached=4000 tokens_cache_write=300 tokens_out=55 tokens_thinking= > "$JOBS_ROOT/logs/R1.meta"
  run "$REPO_ROOT/bin/cr-emit" R1
  [ "$status" -eq 0 ]
  [ "$(jq -r .runtime <<<"$(stream)")" = claude ]
  jq -e '.runtime == "claude" and .tokens_in == 12 and .tokens_cache_write == 300
         and .tokens_thinking == null and .tokens_by_model == null' <<<"$(line)"
}

@test "job_complete: a blank cost is null, never 0; a numeric cost is unchanged" {
  _fake_curl
  # A non-Claude job (no cost reported), and a Claude run that printed no JSON.
  printf '%s\n' runid=R1 exit=0 project=proj model=gpt-6.1-sol cost_usd= runtime=codex > "$JOBS_ROOT/logs/R1.meta"
  printf '%s\n' runid=R2 exit=9 project=proj model=sonnet cost_usd= num_turns= > "$JOBS_ROOT/logs/R2.meta"
  for r in R1 R2; do
    run "$REPO_ROOT/bin/cr-emit" "$r"
    [ "$status" -eq 0 ]
    jq -e '.cost_usd == null' <<<"$(line)"
  done
  # Claude's own figures, a zero among them, pass through as numbers.
  for c in 0.4321 0 2.01; do
    printf '%s\n' runid=R3 exit=0 project=proj model=sonnet "cost_usd=$c" runtime=claude > "$JOBS_ROOT/logs/R3.meta"
    run "$REPO_ROOT/bin/cr-emit" R3
    [ "$status" -eq 0 ]
    jq -e --argjson c "$c" '.cost_usd == $c and (.cost_usd | type) == "number"' <<<"$(line)"
  done
}
