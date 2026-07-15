#!/usr/bin/env bash
# Regression tests for gated_merge.sh, driven by a stubbed `gh` on PATH.
#
# The bug these guard (realrate/.github#11): a transient failure to READ the
# PR's checks used to be indistinguishable from "the repo has no CI", so healthy
# patch/minor Dependabot bumps were parked for a human. The gate now reads the
# REST check-runs/status APIs and distinguishes an API error (retry) from a
# genuine empty result (route to human). Scenarios below pin that behaviour.
#
# No network: `gh` is replaced by a fake that returns canned JSON per scenario.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/gated_merge.sh"
FAILURES=0

# --- the fake `gh` -----------------------------------------------------------
BIN="$(mktemp -d)"
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
# Minimal `gh` stand-in. Logs every call to $GH_LOG and answers from env-provided
# fixtures. BLIP_COUNT makes the first N check-runs reads fail (exit 1) to
# simulate a transient API error during a busy batch.
set -uo pipefail
echo "gh $*" >> "$GH_LOG"
sub="${1:-}"; shift || true
case "$sub" in
  pr)
    action="${1:-}"; shift || true
    case "$action" in
      view)
        if printf '%s ' "$@" | grep -q headRefOid; then echo "${FAKE_SHA:-deadbeef}"; exit 0; fi
        if printf '%s ' "$@" | grep -q state;      then echo "${FAKE_PR_STATE:-OPEN}"; exit 0; fi
        exit 0 ;;
      merge)   echo "merged"; exit 0 ;;
      comment|edit|review|checks) exit 0 ;;
      *) exit 0 ;;
    esac ;;
  api)
    path="${1:-}"
    case "$path" in
      *check-runs*)
        if [ "${BLIP_COUNT:-0}" -gt 0 ]; then
          c="$(cat "$COUNTER" 2>/dev/null || echo 0)"; c=$((c + 1)); echo "$c" > "$COUNTER"
          [ "$c" -le "$BLIP_COUNT" ] && exit 1
        fi
        cat "$CHECK_RUNS_JSON"; exit 0 ;;
      *status*) cat "$STATUS_JSON"; exit 0 ;;
      *) echo '{}'; exit 0 ;;
    esac ;;
  label) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$BIN/gh"

FIX="$(mktemp -d)"
# Our own auto-merge run is id 999; the gate must exclude it from the checks it
# waits on. It is left "in_progress" so a failure to exclude it would hang the
# terminal-state loop until timeout (surfacing the bug).
SELF_RUN='{"name":"auto-merge","status":"in_progress","conclusion":null,"html_url":"https://github.com/o/r/actions/runs/999/job/2","details_url":"https://github.com/o/r/actions/runs/999/job/2"}'
tests_run() { # $1 = conclusion
  printf '{"name":"tests","status":"completed","conclusion":"%s","html_url":"https://github.com/o/r/actions/runs/222/job/1","details_url":"https://github.com/o/r/actions/runs/222/job/1"}' "$1"
}
echo "{\"total_count\":2,\"check_runs\":[$(tests_run success),$SELF_RUN]}" > "$FIX/green.json"
echo "{\"total_count\":2,\"check_runs\":[$(tests_run failure),$SELF_RUN]}" > "$FIX/red.json"
echo "{\"total_count\":1,\"check_runs\":[$SELF_RUN]}"                       > "$FIX/noci.json"
echo '{"state":"pending","total_count":0,"statuses":[]}'                    > "$FIX/status.json"

# --- harness -----------------------------------------------------------------
run_case() { # $1 name; remaining: VAR=VAL env for the run. Populates $LOG/$OUT.
  # Use `env` so the caller's VAR=VAL args (which arrive via "$@" expansion, and
  # so are NOT recognised as shell assignments) are applied to the environment.
  local name="$1"; shift
  LOG="$(mktemp)"; OUT="$(mktemp)"; COUNTER_FILE="$(mktemp)"; : > "$COUNTER_FILE"
  env \
    "PATH=$BIN:$PATH" "GH_LOG=$LOG" "COUNTER=$COUNTER_FILE" \
    "STATUS_JSON=$FIX/status.json" FAKE_SHA="cafef00d" FAKE_PR_STATE="OPEN" \
    GITHUB_RUN_ID="999" PR_URL="https://github.com/o/r/pull/1" GITHUB_TOKEN="x" \
    CI_GATE_ENABLED="true" MERGE_METHOD="rebase" GATE_POLL_SECONDS="1" \
    "$@" \
    bash "$SCRIPT" > "$OUT" 2>&1
  echo "  [case] $name"
}

assert_grep()    { if grep -qF "$1" "$2"; then echo "    ok: found '$1'"; else echo "    FAIL: expected '$1'"; FAILURES=$((FAILURES + 1)); fi; }
assert_no_grep() { if grep -qF "$1" "$2"; then echo "    FAIL: unexpected '$1'"; FAILURES=$((FAILURES + 1)); else echo "    ok: absent '$1'"; fi; }

echo "== 1. API blips then green -> MERGE (the #11 regression) =="
run_case "blip_then_green" \
  BLIP_COUNT="3" CHECK_RUNS_JSON="$FIX/green.json" \
  GATE_APPEAR_SECONDS="5" GATE_TIMEOUT_SECONDS="30"
assert_grep    "pr merge --rebase" "$LOG"
assert_no_grep "no CI checks registered" "$LOG"
assert_no_grep "could not read CI status" "$LOG"

echo "== 2. Green immediately -> MERGE (self-run excluded) =="
run_case "green" \
  CHECK_RUNS_JSON="$FIX/green.json" \
  GATE_APPEAR_SECONDS="5" GATE_TIMEOUT_SECONDS="30"
assert_grep    "pr merge --rebase" "$LOG"
assert_no_grep "pr comment" "$LOG"

echo "== 3. Genuinely no CI -> ROUTE TO HUMAN (fail-safe preserved) =="
run_case "no_ci" \
  CHECK_RUNS_JSON="$FIX/noci.json" \
  GATE_APPEAR_SECONDS="2" GATE_TIMEOUT_SECONDS="30"
assert_grep    "no CI checks registered" "$LOG"
assert_no_grep "pr merge --rebase" "$LOG"

echo "== 4. Red CI -> ROUTE TO HUMAN =="
run_case "red_ci" \
  CHECK_RUNS_JSON="$FIX/red.json" \
  GATE_APPEAR_SECONDS="5" GATE_TIMEOUT_SECONDS="30"
assert_grep    "CI is not passing" "$LOG"
assert_no_grep "pr merge --rebase" "$LOG"

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILURES ASSERTION(S) FAILED"; fi
exit "$FAILURES"
