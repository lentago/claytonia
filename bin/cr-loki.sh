#!/usr/bin/env bash
# cr-loki.sh — the fleet's shared Loki push idiom, SOURCED (not executed) by the
# emitters that ship events to the Alloy Loki receiver: bin/cr-emit (per-job
# events) and bin/context-ledger-commit (context-ledger sweep/host events).
#
# It defines exactly one function, loki_push, plus the LOKI_PUSH_URL default.
# Keep it dependency-light (jq + curl only) and side-effect-free on source, so a
# caller can source it early without surprises. Callers decide policy: cr-emit
# treats a push failure as fatal to the emit; the committer treats it as a
# non-fatal projection error (`|| warn`), never failing the sweep.
#
# Not on PATH and never symlinked into /usr/local/bin — it is a library, resolved
# by the caller relative to its own (readlink-resolved) location. See
# docs/context-ledger.md.

# Default to the fleet Loki receiver. A caller that sourced runner.env (which
# sets LOKI_PUSH_URL) BEFORE sourcing this keeps that value; :- only fills a
# genuinely-unset URL.
LOKI_PUSH_URL="${LOKI_PUSH_URL:-http://192.168.139.20:3100/loki/api/v1/push}"

# loki_push <labels-json> <line-json> — POST one stream value to Loki, stamped
# now (ns). Low-cardinality fields belong in <labels-json> (stream labels); the
# full event belongs in <line-json> (the log line). Returns curl's exit status.
loki_push() {
  local labels="$1" line="$2" ns payload
  ns="$(date +%s%N)"
  payload="$(jq -cn --argjson s "$labels" --arg line "$line" --arg ts "$ns" \
    '{streams:[{stream:$s, values:[[$ts,$line]]}]}')"
  curl -sf -m 10 -XPOST "$LOKI_PUSH_URL" -H 'Content-Type: application/json' \
    --data-binary "$payload" >/dev/null
}
