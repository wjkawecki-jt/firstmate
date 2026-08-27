#!/usr/bin/env bash
# End-to-end reproduction of the reported defect, driven exactly as an operator
# drives it: bin/fm-pr-merge.sh <task> <pr-url> against a simulated GitHub whose
# base branch ruleset carries a merge_queue rule (merge_method: MERGE).
#
# The forge CLIs on PATH are stand-ins for the real ones and model GitHub's own
# behaviour: a direct --squash merge on a queue-required branch is ACCEPTED and
# exits zero while the pull request stays {"merged": false, "state": "open"} and
# isInMergeQueue: false; passing -- --auto --merge really queues it.
# No firstmate test hook is involved - the script under test is run unmodified.
set -u

REPO_UNDER_TEST=$1     # checkout of firstmate to exercise
LABEL=$2               # transcript heading
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-merge-e2e.XXXXXX")
TASK=task-x1
PR_URL=https://github.com/acme/widgets/pull/4321

mkdir -p "$SANDBOX/state" "$SANDBOX/bin" "$SANDBOX/wt" "$SANDBOX/home"
cat > "$SANDBOX/state/$TASK.meta" <<META
window=fm-$TASK
worktree=$SANDBOX/wt
project=$SANDBOX/project
kind=ship
mode=no-mistakes
META

# Simulated live GitHub state for pull request #4321.
cat > "$SANDBOX/pr-state" <<'STATE'
state=OPEN
merged=false
queued=false
base=main
STATE
# Simulated base-branch ruleset: main is behind a merge queue using MERGE.
printf 'merge_method=MERGE\n' > "$SANDBOX/branch-rules"

cat > "$SANDBOX/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
S=$FM_E2E_SANDBOX
case "${1:-} ${2:-}" in
  "pr merge")
    auto=false; method=
    for a in "$@"; do
      case "$a" in
        --auto) auto=true ;;
        --merge) method=merge ;;
        --squash) method=squash ;;
        --rebase) method=rebase ;;
      esac
    done
    if [ "$auto" = true ] && [ "$method" = merge ]; then
      # GitHub accepts the queue's own configured method and queues the PR.
      sed -i.bak 's/^queued=false$/queued=true/' "$S/pr-state" && rm -f "$S/pr-state.bak"
      echo "✓ Pull request acme/widgets#4321 will be added to the merge queue when all requirements are met"
      exit 0
    fi
    # A direct squash on a queue-required branch: GitHub accepts the call,
    # does nothing, and the CLI exits zero.
    printf 'merged:\n  number: 4321\n  status: ok\n'
    exit 0
    ;;
  "pr view")
    st=$(sed -n 's/^state=//p' "$S/pr-state" | tr 'A-Z' 'a-z')
    printf 'pull_request:\n  number: 4321\n  state: %s\n' "$st"
    exit 0
    ;;
esac
exit 0
SH

cat > "$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
S=$FM_E2E_SANDBOX
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in *headRefOid*) echo 1111111111111111111111111111111111111111; exit 0 ;; esac
    ;;
  "api graphql")
    cat "$S/pr-state"; exit 0 ;;
  api\ *)
    case " $* " in *rules/branches*) cat "$S/branch-rules"; exit 0 ;; esac
    ;;
esac
exit 0
SH
chmod +x "$SANDBOX/bin/gh-axi" "$SANDBOX/bin/gh"

run() {
  local heading=$1; shift
  echo
  echo "\$ fm-pr-merge.sh $TASK $PR_URL ${*:+$*}"
  FM_ROOT_OVERRIDE="$REPO_UNDER_TEST" \
  FM_HOME="$SANDBOX/home" \
  FM_STATE_OVERRIDE="$SANDBOX/state" \
  FM_E2E_SANDBOX="$SANDBOX" \
  PATH="$SANDBOX/bin:$PATH" \
    "$REPO_UNDER_TEST/bin/fm-pr-merge.sh" "$TASK" "$PR_URL" "$@" 2>&1
  local rc=$?
  echo "[exit status: $rc]"
  echo "[live pull request: $(tr '\n' ' ' < "$SANDBOX/pr-state")]"
  echo "[task meta: $(grep -E '^(pr|pr_head)=' "$SANDBOX/state/$TASK.meta" | tr '\n' ' ')]"
  echo "[merge poll armed: $(ls "$SANDBOX/state" | grep -c 'pr-poll' || true) file(s) $(ls "$SANDBOX/state" | grep 'pr-poll' | tr '\n' ' ')]"
}

echo "=============================================================="
echo "$LABEL"
echo "=============================================================="
run "default squash on a merge-queue-protected base"
run "operator retries with the queue's own method" -- --auto --merge
rm -rf "$SANDBOX"
