#!/usr/bin/env bash
# End-to-end reproduction of the absorbed paused-task stale-wake leak.
#
# Drives the REAL bin/fm-watch.sh (no stubs of the code under test) against a
# hermetic tmux/crew-state backend, simulating one crew that declared
#   paused: awaiting the upstream tool release to land
# while its grok endpoint is still LIVE and its harness footer ticks a clock,
# minting a new pane hash every few polls.
#
# It emulates the real supervision loop an end user experiences: firstmate arms
# the watcher, the watcher exits when it reports an actionable wake, firstmate
# handles + acknowledges it, and re-arms. Every watcher exit is one burned
# handling turn.
#
# Usage: repro-absorbed-stale-leak.sh <path/to/fm-watch.sh> <label> <outdir>
set -u

REPO=${FM_REPRO_REPO:?set FM_REPRO_REPO to the firstmate checkout}
# shellcheck source=/dev/null
. "$REPO/tests/wake-helpers.sh"

WATCH_BIN=$1
LABEL=$2
OUTDIR=$3
DRAIN="$REPO/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot "fm-repro-$LABEL")

WINDOW="default:w17:p2"
TASK=release
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')

mkdir -p "$OUTDIR"
TRANSCRIPT="$OUTDIR/$LABEL.transcript.txt"
: > "$TRANSCRIPT"
: > "$OUTDIR/$LABEL.durable-rows"
say() { printf '%s\n' "$*" | tee -a "$TRANSCRIPT"; }

# Signature a primed .seen-* marker must hold so the per-poll signal scan does
# not fire on the pre-existing status line (mirrors fm-watch.sh's stat_sig).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

ack_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.repro-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1
}

dir=$(make_case "$LABEL")
state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
statusf="$state/$TASK.status"

printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$WINDOW" > "$state/$TASK.meta"
printf 'working: opened the upstream release PR\npaused: awaiting the upstream tool release to land\n' > "$statusf"
# Backdate the declaration so the reported ages read like a real multi-minute wait.
back=$(( $(date +%s) - 420 ))
if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
else touch -m -d "@$back" "$statusf"; fi
sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-${TASK}_status"

footer() {  # <tick>
  printf '> paused: awaiting the upstream tool release to land\n\n  upstream release watch - last poll 14:0%s:07 - idle\n' "$1" > "$capture"
}
footer 0
printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$KEY"

say "=== $LABEL: live grok endpoint under a declared external wait, footer ticking ==="
say "watcher under test : $WATCH_BIN"
say "window             : $WINDOW   (kind=ship, harness=grok, backend=tmux)"
say "status log         : $(tail -1 "$statusf")"
say "crew state read    : state: paused - source: status-log - awaiting the upstream tool release"
say "endpoint liveness  : tmux pane_current_command=grok  (agent ALIVE)"
say ""

turns=0
tick=1
while [ "$tick" -le 4 ]; do
  footer "$tick"
  say "--- harness footer tick $tick (new pane hash) ---"
  deadline=$(( $(date +%s) + 9 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    out="$dir/arm.out"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$capture" \
      FM_FAKE_TMUX_CURRENT_COMMAND=grok \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_BIN" > "$out" 2>"$out.err" &
    pid=$!
    if wait_for_exit "$pid" 40; then :; else kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    reason=$(head -1 "$out" 2>/dev/null || true)
    if [ -n "$reason" ]; then
      turns=$((turns + 1))
      say "  WATCHER EXITED -> firstmate handling turn #$turns: $reason"
      # Snapshot the durable queue BEFORE acknowledging, so the row the watcher
      # enqueued is visible rather than consumed by the handling turn.
      awk -F '\t' -v w="$WINDOW" '$4 == w { printf "    durable queue row: seq=%s kind=%s key=%s payload=%s\n", $2, $3, $4, $5 }' \
        "$state/.wake-queue" 2>/dev/null | tee -a "$TRANSCRIPT" "$OUTDIR/$LABEL.durable-rows" >/dev/null
      awk -F '\t' -v w="$WINDOW" '$4 == w { printf "    durable queue row: seq=%s kind=%s key=%s payload=%s\n", $2, $3, $4, $5 }' \
        "$state/.wake-queue" 2>/dev/null
      grep -c . "$state/.wake-queue" >/dev/null 2>&1 || say "    durable queue row: (none - the watcher enqueued nothing)"
      ack_cycle "$state" || say "  (drain/ack unavailable)"
    else
      # Reaped mid-poll, or it stood down to re-announce its own recovery.
      ack_cycle "$state" >/dev/null 2>&1 || true
      break
    fi
  done
  tick=$((tick + 1))
done

say ""
say "--- every durable wake record this run enqueued for $WINDOW ---"
if [ -s "$OUTDIR/$LABEL.durable-rows" ]; then
  sed 's/^    /  /' "$OUTDIR/$LABEL.durable-rows" | tee -a "$TRANSCRIPT"
else
  say "  (none - the absorb decision kept every wake out of the durable queue)"
fi
say ""
say "--- watcher triage log ($state/.watch-triage.log) ---"
grep -E "absorbed stale|surfaced" "$state/.watch-triage.log" 2>/dev/null | tail -12 | sed 's/^/  /' | tee -a "$TRANSCRIPT"
say ""
bare=$(grep -c "payload=stale: $WINDOW\$" "$OUTDIR/$LABEL.durable-rows" 2>/dev/null | head -1)
case "$bare" in ''|*[!0-9]*) bare=0 ;; esac
say "RESULT: firstmate handling turns burned = $turns ; bare 'stale: $WINDOW' durable records = $bare"
printf '%s\n' "$turns $bare" > "$OUTDIR/$LABEL.counts"
