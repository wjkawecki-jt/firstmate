#!/usr/bin/env bash
# Wedge-preservation evidence on the SAME fixed watcher: three panes that MUST
# still reach firstmate's handling turn.
set -u
ROOT="$1"; OUTFILE="$2"
cd "$ROOT"
. "$ROOT/tests/wake-helpers.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-repro-preserve)
seen_sig() { if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1"; else stat -c '%s:%Y' "$1"; fi; }
file_mtime() { if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi; }
back_date() { local e=$1 f=$2; if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$e" '+%Y%m%d%H%M.%S')" "$f"; else touch -m -d "@$e" "$f"; fi; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
wait_poll_cycle() {
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"; rm -f "$beat"; first=""
  while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat"); [ -n "$first" ] && break; sleep 0.1; i=$((i+1)); done
  while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat"); if [ -n "$now" ] && [ "$now" != "$first" ]; then return 0; fi
    sleep 0.1; i=$((i+1)); done
  return 1
}
ack_cycle() {
  local state=$1 err sequence generation
  err="$state/.repro-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}

exec > "$OUTFILE" 2>&1
echo "### wedge-preservation check on the FIXED watcher: what must still reach firstmate"
echo

setup() {  # <case> <window> <status-line> <pane-text>
  dir=$(make_case "$1"); state="$dir/state"; fakebin="$dir/fakebin"
  capture_file="$dir/pane.txt"; window=$2; statusf="$state/t.status"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/t.meta"
  printf '%s\n' "$3" > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-t_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s\n' "$4" > "$capture_file"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
}
run_watch() {  # <extra env...>
  env "$@" PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$dir/watch.out" 2>&1 &
  pid=$!
  if wait_poll_cycle "$state" "$pid"; then reap "$pid"; else wait "$pid" 2>/dev/null || true; fi
}

echo "--- 1. declared external wait, LIVE endpoint, past the long recheck cadence"
echo "    (the wait must not rot invisibly: it still has to reach the captain)"
setup preserve-recheck "default:w16:p2" "paused: waiting on the external human reviewer to respond" "reviewing the handoff, waiting on a human"
back_date $(( $(date +%s) - 500 )) "$statusf"
printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-t_status"
round=1
while [ "$round" -le 6 ]; do
  run_watch FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting on the external human reviewer to respond' \
    FM_PAUSE_RESURFACE_SECS=240
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null 2>&1 && break
  ack_cycle "$state" >/dev/null 2>&1 || true
  round=$((round + 1))
done
echo "    firstmate's handling turn (bin/fm-wake-drain.sh):"
FM_STATE_OVERRIDE="$state" "$DRAIN" 2>&1 | sed 's/^/      | /'
echo

echo "--- 2. the SAME idle pane after the declaration is lifted"
echo "    (a task NOT in a declared external wait is unchanged: genuine stale delivered at once)"
ack_cycle "$state" >/dev/null 2>&1 || true
printf 'working: external wait cleared, but the pane made no progress\n' > "$statusf"
printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-t_status"
run_watch FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
  FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
  FM_PAUSE_RESURFACE_SECS=999
echo "    firstmate's handling turn (bin/fm-wake-drain.sh):"
FM_STATE_OVERRIDE="$state" "$DRAIN" 2>&1 | sed 's/^/      | /'
echo

echo "--- 3. a genuinely wedged pane: quiet, provably-working run, no declaration, past the wedge threshold"
echo "    (a wedge that stops being reported would be worse than the bug being fixed)"
setup preserve-wedge "default:w17:p2" "working: running the validation pipeline" "waiting for the pipeline"
: > "$state/.paused-x" ; rm -f "$state/.paused-x"
printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.stale-$key"
printf '2\n' > "$state/.count-$key"
run_watch FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
  FM_FAKE_CREW_STATE='state: working · source: run-step · pipeline step running' \
  FM_STALE_ESCALATE_SECS=240
echo "    firstmate's handling turn (bin/fm-wake-drain.sh):"
FM_STATE_OVERRIDE="$state" "$DRAIN" 2>&1 | sed 's/^/      | /'
echo

echo "--- 4. a LIVE captain-held decision gate (the deliberate carve-out that keeps the stricter gate)"
setup preserve-hold "default:w18:p2" "captain-held [key=route]: tracked by held-decision-route" "idle at a captain-owned decision"
run_watch FM_FAKE_TMUX_CURRENT_COMMAND=claude \
  FM_FAKE_CREW_STATE='state: paused · source: status-log · captain-owned decision' \
  FM_PAUSE_RESURFACE_SECS=999
echo "    firstmate's handling turn (bin/fm-wake-drain.sh):"
FM_STATE_OVERRIDE="$state" "$DRAIN" 2>&1 | sed 's/^/      | /'
