#!/usr/bin/env bash
# The rest of the operator-visible outcome surface of bin/fm-pr-merge.sh, driven
# the way an operator drives it, against stand-in forge CLIs that model GitHub.
# Each scenario builds its own sandbox: task meta, simulated live pull request,
# simulated base-branch ruleset, and fake gh-axi/gh on PATH.
set -u
REPO=${1:?repo under test}
TASK=task-x1
PR_URL=https://github.com/acme/widgets/pull/4321
BASE_PATH=$PATH

new_sandbox() { # <queued-base-rule: yes|no> <merge-behaviour: lands|noop|fails> <reads: ok|broken>
  local rule=$1 behaviour=$2 reads=$3 s
  s=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-merge-e2e.XXXXXX")
  mkdir -p "$s/state" "$s/bin" "$s/wt" "$s/home"
  cat > "$s/state/$TASK.meta" <<META
window=fm-$TASK
worktree=$s/wt
project=$s/project
kind=ship
mode=no-mistakes
META
  printf 'state=OPEN\nmerged=false\nqueued=false\nbase=main\n' > "$s/pr-state"
  if [ "$rule" = yes ]; then printf 'merge_method=MERGE\n' > "$s/branch-rules"; else : > "$s/branch-rules"; fi
  printf '%s\n' "$behaviour" > "$s/merge-behaviour"
  printf '%s\n' "$reads" > "$s/read-behaviour"
  cat > "$s/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
S=$FM_E2E_SANDBOX
case "${1:-} ${2:-}" in
  "pr merge")
    case "$(cat "$S/merge-behaviour")" in
      lands)
        printf 'state=MERGED\nmerged=true\nqueued=false\nbase=main\n' > "$S/pr-state"
        printf 'merged:\n  number: 4321\n  status: ok\n' ; exit 0 ;;
      fails)
        echo "error: failed to run git: exit status 128" >&2 ; exit 1 ;;
      *)
        printf 'merged:\n  number: 4321\n  status: ok\n' ; exit 0 ;;
    esac ;;
  "pr view")
    [ "$(cat "$S/read-behaviour")" = ok ] || exit 1
    st=$(sed -n 's/^state=//p' "$S/pr-state" | tr 'A-Z' 'a-z')
    printf 'pull_request:\n  number: 4321\n  state: %s\n' "$st" ; exit 0 ;;
esac
exit 0
SH
  cat > "$s/bin/gh" <<'SH'
#!/usr/bin/env bash
S=$FM_E2E_SANDBOX
case "${1:-} ${2:-}" in
  "pr view") case " $* " in *headRefOid*) echo 1111111111111111111111111111111111111111; exit 0 ;; esac ;;
  "api graphql")
    [ "$(cat "$S/read-behaviour")" = ok ] || { echo 'gh: Something went wrong (HTTP 502)' >&2; exit 1; }
    cat "$S/pr-state"; exit 0 ;;
  api\ *) case " $* " in *rules/branches*) cat "$S/branch-rules"; exit 0 ;; esac ;;
esac
exit 0
SH
  chmod +x "$s/bin/gh-axi" "$s/bin/gh"
  printf '%s\n' "$s"
}

# The whole search path re-exposed by symlink except gh, so no real copy answers.
path_without_gh() {
  local s=$1 dir="$1/nogh" bindir entry name
  mkdir -p "$dir"
  ln -sf "$s/bin/gh-axi" "$dir/gh-axi"
  printf '%s\n' "$BASE_PATH" | tr ':' '\n' | while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = gh ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done
  printf '%s\n' "$dir"
}

run() { # <sandbox> <path> [extra args...]
  local s=$1 path=$2; shift 2
  FM_ROOT_OVERRIDE="$REPO" FM_HOME="$s/home" FM_STATE_OVERRIDE="$s/state" \
  FM_E2E_SANDBOX="$s" PATH="$path" \
    "$REPO/bin/fm-pr-merge.sh" "$TASK" "$PR_URL" "$@" 2>&1 | grep -v '^●\|^WARNING: watcher\|^armed:'
  local rc=${PIPESTATUS[0]}
  echo "[exit status: $rc]"
  echo "[task meta: $(grep -E '^pr=' "$s/state/$TASK.meta" | tr '\n' ' ')| merge poll: $(cd "$s/state" && ls | grep 'pr-poll' | tr '\n' ' ')]"
}

section() { echo; echo "── $1"; }

echo "=============================================================="
echo "bin/fm-pr-merge.sh outcome surface - $(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo "$REPO")"
echo "=============================================================="

section "1. a merge that really lands is reported as merged"
s=$(new_sandbox no lands ok)
echo "\$ fm-pr-merge.sh $TASK $PR_URL"
run "$s" "$s/bin:$PATH"; rm -rf "$s"

section "2. gh is not installed at all - the gh-axi merge still runs and still proves the merge"
s=$(new_sandbox no lands ok); p=$(path_without_gh "$s")
echo "\$ PATH without gh; fm-pr-merge.sh $TASK $PR_URL"
echo "[gh resolvable on this PATH: $(PATH="$p" command -v gh >/dev/null 2>&1 && echo yes || echo no)]"
run "$s" "$p"; rm -rf "$s"

section "3. auto-merge armed on a base branch with no merge queue - refused, not a silent success"
s=$(new_sandbox no noop ok)
echo "\$ fm-pr-merge.sh $TASK $PR_URL -- --auto --squash"
run "$s" "$s/bin:$PATH" -- --auto --squash; rm -rf "$s"

section "4. both outcome reads fail after a merge command that returned success"
s=$(new_sandbox yes lands broken)
echo "\$ fm-pr-merge.sh $TASK $PR_URL"
run "$s" "$s/bin:$PATH"; rm -rf "$s"

section "5. the merge command itself failed - its own error first, no claim of acceptance"
s=$(new_sandbox yes fails ok)
echo "\$ fm-pr-merge.sh $TASK $PR_URL -- --auto --merge"
run "$s" "$s/bin:$PATH" -- --auto --merge; rm -rf "$s"

section "6. the caller already used the queue's own flags and it still has not queued"
s=$(new_sandbox yes noop ok)
echo "\$ fm-pr-merge.sh $TASK $PR_URL -- --auto --merge"
run "$s" "$s/bin:$PATH" -- --auto --merge; rm -rf "$s"
