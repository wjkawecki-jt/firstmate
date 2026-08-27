#!/usr/bin/env bash
# End-to-end reproduction harness for the .env.local pool-reissue failure.
#
#   usage: e2e-env-local-reissue.sh <firstmate-repo-root> <label>
#
# Drives the REAL binaries - bin/fm-spawn.sh and bin/fm-teardown.sh - over a real
# git project, a real linked worktree standing in for a treehouse pool slot, and a
# fake `treehouse` whose `return --force` hands the slot back pristine the way the
# pool does. The cycle is the one an end user lives through:
#
#   1. a task is spawned into a pooled slot that carries the captain's .env.local
#   2. the task finishes and teardown returns the slot to the pool
#   3. the next task is spawned and the pool reissues that same slot
#
# The file's bytes are a synthetic marker and are NEVER printed: the transcript
# reports presence, mode, ownership, and a yes/no byte-identity verdict only.
set -u

REPO=${1:?usage: e2e-env-local-reissue.sh <repo-root> <label>}
LABEL=${2:?usage: e2e-env-local-reissue.sh <repo-root> <label>}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-env-local-e2e-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

HOME_DIR="$WORK/home"
PROJ="$WORK/project"
ORIGIN="$WORK/origin.git"
POOL="$WORK/pool"
FAKEBIN="$WORK/fakebin"
GIT_ID=(-c user.name='Firstmate E2E' -c user.email='e2e@example.invalid')

mkdir -p "$HOME_DIR"/{data,projects,state,config} "$FAKEBIN"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"

# Isolate git's global excludes so the .gitignore rule under test is the only one
# that decides whether .env.local is ignored on this machine.
: > "$WORK/empty-gitignore"
: > "$WORK/empty-gitconfig"
printf '[core]\n\texcludesFile = %s\n' "$WORK/empty-gitignore" > "$WORK/isolated-gitconfig"
export GIT_CONFIG_GLOBAL="$WORK/isolated-gitconfig"
export GIT_CONFIG_SYSTEM="$WORK/empty-gitconfig"

# Same exemption tests/lib.sh takes: this harness runs from a no-mistakes gate
# worktree, the one environment the gate-lifecycle guard refuses, and it drives the
# real fm-spawn/fm-teardown deliberately.
export FM_GATE_REFUSE_BYPASS=1

# --- fakes ------------------------------------------------------------------
# tmux: spawn drives a terminal; the pane's cwd is the pooled slot, which is how
# spawn learns which worktree `treehouse get` handed it.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH

# treehouse: `get` is a no-op (the pane already sits in the slot). `return --force`
# models the pool taking the slot back and handing out a pristine checkout, which
# is the state a reissued slot is observed in: no leftover working-tree files.
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = return ]; then
  shift
  [ "${1:-}" != --force ] || shift
  dir=${1:-}
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    git -C "$dir" reset --hard --quiet
    git -C "$dir" clean --quiet -fdx
  fi
fi
exit 0
SH

# Hermetic stubs for the lookups teardown makes on the way out.
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cp "$FAKEBIN/gh-axi" "$FAKEBIN/gh"
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN"/tmux "$FAKEBIN"/treehouse "$FAKEBIN"/gh-axi "$FAKEBIN"/gh "$FAKEBIN"/no-mistakes

# --- fixture ----------------------------------------------------------------
git init --quiet -b main "$PROJ"
printf 'base\n' > "$PROJ/README.md"
printf '.env.local\n' > "$PROJ/.gitignore"
git -C "$PROJ" add README.md .gitignore
git -C "$PROJ" "${GIT_ID[@]}" commit -qm 'initial, ignoring .env.local'
git clone --quiet --bare "$PROJ" "$ORIGIN"
git -C "$PROJ" remote add origin "file://$ORIGIN"
git -C "$PROJ" fetch --quiet origin
git -C "$PROJ" worktree add --quiet --detach "$POOL" HEAD

# The captain's real local environment file lives in the primary checkout. The
# bytes below are a synthetic marker; 0640 is deliberate so mode preservation is
# observable against the 0600 default of a freshly staged copy.
printf 'FIXTURE_MARKER=captain-local-not-a-real-credential\n' > "$PROJ/.env.local"
chmod 0640 "$PROJ/.env.local"

file_facts() {  # <path>
  local p=$1 mode owner
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then
    printf 'ABSENT\n'
    return
  fi
  mode=$(stat -f %Lp "$p" 2>/dev/null || stat -c %a "$p")
  owner=$(stat -f 'uid=%u gid=%g' "$p" 2>/dev/null || stat -c 'uid=%u gid=%g' "$p")
  if cmp -s "$PROJ/.env.local" "$p"; then
    printf 'present  mode=%s  %s  byte-identical-to-captain-source=yes\n' "$mode" "$owner"
  else
    printf 'present  mode=%s  %s  byte-identical-to-captain-source=no\n' "$mode" "$owner"
  fi
}

run_spawn() {  # <task-id>
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL" \
    PATH="$FAKEBIN:$PATH" \
    "$REPO/bin/fm-spawn.sh" "$id" "$PROJ" --mode no-mistakes --yolo off 2>&1
}

run_teardown() {  # <task-id>
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN:$PATH" \
    "$REPO/bin/fm-teardown.sh" "$id" --force 2>&1
}

echo "=============================================================="
echo " firstmate .env.local across teardown and pool reissue - $LABEL"
echo "=============================================================="
echo "fm-spawn.sh under test: $REPO/bin/fm-spawn.sh"
echo "project (captain's primary checkout): $PROJ"
echo "pooled slot: $POOL"
echo "project .gitignore: $(cat "$PROJ/.gitignore")"
echo "captain's .env.local:      $(file_facts "$PROJ/.env.local")"
echo

# The slot carries the captain's file the way it does before a teardown: placed by
# hand here so the "present before teardown" half of the cycle is shown even on the
# pre-fix path, where nothing in spawn would put it there.
cp -p "$PROJ/.env.local" "$POOL/.env.local"
echo "[0] pooled slot as the captain left it before teardown"
echo "    slot .env.local:       $(file_facts "$POOL/.env.local")"
echo

echo "[1] fm-spawn.sh task-alpha (task runs in the pooled slot)"
out=$(run_spawn env-e2e-alpha); status=$?
echo "    exit status: $status"
printf '%s\n' "$out" | sed -n '$p' | sed 's/^/    last line: /'
echo "    slot .env.local:       $(file_facts "$POOL/.env.local")"
echo

echo "[2] fm-teardown.sh env-e2e-alpha --force (slot returns to the pool)"
out=$(run_teardown env-e2e-alpha); status=$?
echo "    exit status: $status"
printf '%s\n' "$out" | grep -i 'returned\|teardown complete\|worktree' | tail -n 2 | sed 's/^/    /'
echo "    slot .env.local:       $(file_facts "$POOL/.env.local")"
echo

echo "[3] fm-spawn.sh task-bravo (the pool reissues that same slot)"
out=$(run_spawn env-e2e-bravo); status=$?
echo "    exit status: $status"
printf '%s\n' "$out" | sed -n '$p' | sed 's/^/    last line: /'
echo "    slot .env.local:       $(file_facts "$POOL/.env.local")"
echo "    slot git status:       $(git -C "$POOL" status --porcelain | wc -l | tr -d ' ') entries (0 = the slot is not wedged)"
echo

if [ -f "$POOL/.env.local" ] && cmp -s "$PROJ/.env.local" "$POOL/.env.local"; then
  echo "VERDICT: the reissued worktree carries the captain's .env.local again."
else
  echo "VERDICT: the reissued worktree has NO usable .env.local - the reported failure."
fi
