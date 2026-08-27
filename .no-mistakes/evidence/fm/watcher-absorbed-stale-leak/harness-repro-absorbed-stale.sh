#!/usr/bin/env bash
# Product-level reproduction of the reported symptom: four parked tasks in a
# declared external wait, each with a LIVE endpoint whose harness footer ticks
# (minting a new pane hash on every capture). Shows, per tick, the watcher's own
# triage decision and what actually landed on the durable wake queue that
# firstmate drains into a handling turn.
set -u
ROOT="$1"; LABEL="$2"; OUTFILE="$3"
cd "$ROOT"
. "$ROOT/tests/wake-helpers.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot "fm-repro-$LABEL")
seen_sig() { if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1"; else stat -c '%s:%Y' "$1"; fi; }
file_mtime() { if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
ack_cycle() {  # <state> - what firstmate does at the END of a burned handling turn
  local state=$1 err sequence generation
  err="$state/.repro-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}
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

exec > "$OUTFILE" 2>&1
echo "### firstmate watcher - parked task in a declared external wait (endpoint ALIVE, harness footer ticking)"
echo "### build: $LABEL"
echo

for w in w12 w15; do
  dir=$(make_case "$LABEL-$w"); state="$dir/state"; fakebin="$dir/fakebin"
  capture_file="$dir/pane.txt"; statusf="$state/$w.status"; window="default:$w:p2"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/$w.meta"
  printf 'paused: waiting on the external human reviewer to respond\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-${w}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  burned=0
  echo "--- $window : 4 watcher ticks, footer advances each tick (new pane hash every time)"
  tick=1
  while [ "$tick" -le 4 ]; do
    printf 'reviewing the handoff, waiting on a human\n  esc to interrupt · %ds\n' $((tick * 17)) > "$capture_file"
    # The pane has been sitting at this footer frame: prime the watcher's own
    # hash/count state so this tick's poll is the SECOND sight of this hash,
    # i.e. exactly the first-sight-of-a-new-stale-hash branch the report names.
    printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=claude \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting on the external human reviewer to respond' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$dir/watch.out" 2>&1 &
    pid=$!
    if wait_poll_cycle "$state" "$pid"; then reap "$pid"; else wait "$pid" 2>/dev/null || true; fi
    rows_now=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
    queued=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { print $5 }' "$state/.wake-queue" 2>/dev/null | tail -1)
    printf '  tick %d (footer advanced -> new pane hash)\n' "$tick"
    printf '     durable queue row : %s\n' "${queued:-<nothing queued - no handling turn burned>}"
    [ -z "${queued:-}" ] || burned=$((burned + 1))
    # Simulate firstmate spending the handling turn: drain and acknowledge.
    if [ -n "${queued:-}" ] && [ "$tick" -lt 4 ]; then ack_cycle "$state" || true; fi
    # Now poll again with the SAME footer frame: this is the in-between poll the
    # report saw logging the very same declaration as absorbed.
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=claude \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting on the external human reviewer to respond' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$dir/watch.out" 2>&1 &
    pid2=$!
    if wait_poll_cycle "$state" "$pid2"; then reap "$pid2"; else wait "$pid2" 2>/dev/null || true; fi
    decision=$(grep -F "$window" "$state/.watch-triage.log" 2>/dev/null | tail -1)
    printf '     next poll, same hash, watcher decision : %s\n' "${decision:-<none logged>}"
    tick=$((tick + 1))
  done
  rows=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  echo "  => handling turns firstmate burned on this unchanged parked task: $burned of 4 ticks"
  echo "  => durable stale rows still queued for $window: $rows (bare 'stale: $window': $bare)"
  echo "  => what firstmate's next handling turn receives (bin/fm-wake-drain.sh):"
  FM_STATE_OVERRIDE="$state" "$DRAIN" 2>&1 | sed 's/^/       | /' || true
  echo
done
