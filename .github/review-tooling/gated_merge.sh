#!/usr/bin/env bash
# Gated auto-merge for Dependabot PRs (RealRate-Private#2229 / #2244).
#
# Waits for the PR's own CI checks -- every check EXCEPT this workflow's own run --
# to finish, then merges only if all of them passed. If any check failed, or the
# checks do not finish within the timeout, the PR is routed to manual review
# instead of merged. So a bump can never auto-merge over red CI, even in repos
# that have NO *required* status checks configured.
#
# Why read checks here instead of using GitHub "required status checks":
# required checks are matched by exact name, per repo. This workflow is injected
# org-wide across repos whose test jobs are named differently (or absent), so a
# single org rule cannot name them all -- requiring a check a repo does not emit
# would deadlock every PR there. Reading the PR's own check conclusions works
# uniformly regardless of what each repo calls its checks. See #2244.
#
# The job that sources this script is a required workflow in the org
# `dependabot-automerge` ruleset, so this script MUST exit 0 on every expected
# path (merged, held-for-human, no-CI): a non-zero exit would itself block the
# merge for a human too. It only merges; it never fails the gate.
#
# Env:
#   PR_URL                 (required) the PR to gate and merge
#   GITHUB_TOKEN           (required) authenticates the gh calls
#   GITHUB_RUN_ID          (auto on runners) this run's id; excludes our own check
#   CI_GATE_ENABLED        default "true"; "false" = kill switch, native --auto merge
#   MERGE_METHOD           default "rebase"
#   GATE_APPEAR_SECONDS    default 300; how long to wait for checks to register
#                          before giving up and routing to a human (never merges
#                          without a green signal, even if the repo has no CI)
#   GATE_TIMEOUT_SECONDS   default 1800; overall budget to wait for checks to finish
#   GATE_POLL_SECONDS      default 30; poll interval
set -uo pipefail

: "${PR_URL:?PR_URL is required}"

CI_GATE_ENABLED="${CI_GATE_ENABLED:-true}"
MERGE_METHOD="${MERGE_METHOD:-rebase}"
APPEAR="${GATE_APPEAR_SECONDS:-300}"
TIMEOUT="${GATE_TIMEOUT_SECONDS:-1800}"
POLL="${GATE_POLL_SECONDS:-30}"

# Kill switch: fall back to GitHub-native auto-merge (waits only for *required*
# checks). Lets the CI gate be turned off org-wide via one env flip, no revert.
if [ "$CI_GATE_ENABLED" != "true" ]; then
  echo "CI_GATE_ENABLED=$CI_GATE_ENABLED -> native auto-merge (no CI gate)."
  gh pr merge --auto --"$MERGE_METHOD" "$PR_URL"
  exit $?
fi

pr_state() { gh pr view "$PR_URL" --json state --jq .state 2>/dev/null || echo ""; }

route_to_human() {
  gh pr comment "$PR_URL" --body "🤖 **Auto-merge held:** $1 Routed to manual review." || true
  gh label create needs-manual-review --color FBCA04 \
    --description "Dependabot bump — needs manual review before merge" 2>/dev/null || true
  gh pr edit "$PR_URL" --add-label needs-manual-review || true
}

do_merge() {
  # Try an immediate merge first. The base branch's ruleset can prohibit an
  # immediate merge until its required workflow/checks settle ("the base branch
  # policy prohibits the merge ... add the --auto flag"); in that case enable
  # auto-merge so GitHub completes the merge once the policy is satisfied. Our
  # own checks are already green here, so --auto only defers to the branch policy,
  # it does not skip CI. Anything else -> route to a human.
  local err
  if err="$(gh pr merge --"$MERGE_METHOD" "$PR_URL" 2>&1)"; then
    echo "Merged."
    return 0
  fi
  if printf '%s' "$err" | grep -qiE "add the .--auto. flag|base branch policy prohibits"; then
    if gh pr merge --auto --"$MERGE_METHOD" "$PR_URL"; then
      echo "Immediate merge blocked by branch policy; enabled --auto (GitHub will complete it once requirements are met)."
      return 0
    fi
  fi
  route_to_human "the merge was rejected: $(printf '%s' "$err" | tail -1)"
}

# The PR's checks minus THIS workflow's own run, matched by run id inside the
# check link (rename-proof). Captures stdout even when `gh pr checks` exits
# non-zero (it does when checks are pending/failing); only an empty result -- no
# checks reported yet -- collapses to [].
other_checks() {
  local out
  out="$(gh pr checks "$PR_URL" --json name,bucket,link 2>/dev/null)"
  [ -z "$out" ] && { echo '[]'; return; }
  echo "$out" | jq --arg rid "${GITHUB_RUN_ID:-0}" \
    '[.[] | select((.link // "") | contains("/runs/" + $rid + "/") | not)]'
}

start="$SECONDS"

# 1) Wait for CI to register. Checks can be slow to appear under runner-queue
#    contention, so we wait up to APPEAR. We do NOT merge on "no checks" -- that
#    would skip the gate exactly when checks are merely delayed (and an immediate
#    merge before the base-branch policy's requirements exist gets rejected
#    anyway). If nothing registers, route to a human rather than merge blind.
while :; do
  checks="$(other_checks)"
  [ "$(echo "$checks" | jq 'length')" -gt 0 ] && break
  if [ $((SECONDS - start)) -ge "$APPEAR" ]; then
    route_to_human "no CI checks registered within ${APPEAR}s (checks delayed, or the repo has none) -- not auto-merging without a green signal."
    exit 0
  fi
  sleep "$POLL"
done

# 2) Wait for every non-self check to reach a terminal state.
while :; do
  checks="$(other_checks)"
  [ "$(echo "$checks" | jq '[.[] | select(.bucket=="pending")] | length')" -eq 0 ] && break
  if [ "$(pr_state)" != "OPEN" ]; then echo "PR no longer open; nothing to do."; exit 0; fi
  if [ $((SECONDS - start)) -ge "$TIMEOUT" ]; then
    route_to_human "CI did not finish within $((TIMEOUT / 60)) minutes."
    exit 0
  fi
  sleep "$POLL"
done

# 3) Any failed / cancelled check -> hold for a human. (`skipping` and `pass`
#    are both acceptable.) Otherwise merge.
bad="$(echo "$checks" | jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")]')"
if [ "$(echo "$bad" | jq 'length')" -gt 0 ]; then
  route_to_human "CI is not passing ($(echo "$bad" | jq -r '[.[].name] | join(", ")'))."
  exit 0
fi

if [ "$(pr_state)" != "OPEN" ]; then echo "PR already merged/closed; nothing to do."; exit 0; fi

echo "All checks passed; merging."
do_merge
exit 0
