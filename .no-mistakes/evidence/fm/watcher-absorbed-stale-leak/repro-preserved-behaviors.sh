#!/usr/bin/env bash
# Preservation evidence for the absorbed paused-task stale-wake fix, driving the
# REAL bin/fm-watch.sh under the same hermetic backend as the leak reproduction.
#
# Shows the three things the fix must NOT have broken:
#   B  the deliberate long-cadence recheck for a declared external wait still
#      reaches the captain, on a LIVE endpoint, naming the wait's age
#   C  a genuine wedge (no declaration) still wakes firstmate as a possible wedge
#   D  a task not in a declared external wait is unaffected: lifting the pause
#      restores the ordinary immediate stale wake
#
# Usage: repro-preserved-behaviors.sh <path/to/fm-watch.sh> <outdir>
set -u

REPO=${FM_REPRO_REPO:?set FM_REPRO_REPO to the firstmate checkout}
# shellcheck source=/dev/null
. "$REPO/tests/wake-helpers.sh"

WATCH_BIN=$1
OUTDIR=$2
DRAIN="$REPO/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-repro-preserved)

mkdir -p "$OUTDIR"
TRANSCRIPT="$OUTDIR/preserved-behaviors.transcript.txt"
: > "$TRANSCRIPT"
say() { printf '%s\n' "$*" | tee -a "$TRANSCRIPT"; }

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}
backdate() {  # <file> <seconds-ago>
  local f=$1 back; back=$(( $(date +%s) - $2 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$f"
  else touch -m -d "@$back" "$f"; fi
}
show_queue() {  # <state> <window>
  awk -F '\t' -v w="$2" '$4 == w { printf "  durable queue row: seq=%s kind=%s key=%s payload=%s\n", $2, $3, $4, $5 }' \
    "$1/.wake-queue" 2>/dev/null | tee -a "$TRANSCRIPT"
}

say "watcher under test : $WATCH_BIN"
say ""

# --- B: the declared external wait's bounded recheck still reaches the captain ---
dir=$(make_case preserved-recheck); state="$dir/state"; fakebin="$dir/fakebin"
capture="$dir/pane.txt"; out="$dir/watch.out"
window="default:w17:p2"; key=$(printf '%s' "$window" | tr ':/.' '___')
printf '> paused: awaiting the upstream tool release to land\n\n  upstream release watch - idle\n' > "$capture"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/release.meta"
printf 'paused: awaiting the upstream tool release to land\n' > "$state/release.status"
backdate "$state/release.status" 600
printf '%s' "$(seen_sig "$state/release.status")" > "$state/.seen-release_status"
printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"

say "=== B. declared external wait, LIVE grok endpoint, wait older than the recheck cadence ==="
say "status log         : $(tail -1 "$state/release.status")   (declared 600s ago)"
say "FM_PAUSE_RESURFACE_SECS=240  -> the bounded recheck is due"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
  FM_FAKE_TMUX_CURRENT_COMMAND=grok \
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_BIN" > "$out" 2>/dev/null &
pid=$!
if wait_for_exit "$pid" 150; then
  say "  WATCHER WOKE FIRSTMATE: $(head -1 "$out")"
else
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  say "  WATCHER DID NOT WAKE (recheck lost)"
fi
show_queue "$state" "$window"
say ""

# --- C: a genuine wedge still wakes firstmate ---
dir=$(make_case preserved-wedge); state="$dir/state"; fakebin="$dir/fakebin"
capture="$dir/pane.txt"; out="$dir/watch.out"
window="default:w21:p2"; key=$(printf '%s' "$window" | tr ':/.' '___')
printf 'compiling the release bundle\n' > "$capture"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/build.meta"
printf 'working: still compiling the release bundle\n' > "$state/build.status"
printf '%s' "$(seen_sig "$state/build.status")" > "$state/.seen-build_status"
printf '%s' "$(hash_text "compiling the release bundle")" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
printf '%s' "$(hash_text "compiling the release bundle")" > "$state/.stale-$key"
echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"

say "=== C. genuine wedge: no declaration, pane frozen past FM_STALE_ESCALATE_SECS=240 ==="
say "status log         : $(tail -1 "$state/build.status")   (no paused:/captain-held: declaration)"
say "idle timer         : 500s on a static pane"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
  FM_FAKE_TMUX_CURRENT_COMMAND=grok \
  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_BIN" > "$out" 2>/dev/null &
pid=$!
if wait_for_exit "$pid" 150; then
  say "  WATCHER WOKE FIRSTMATE: $(head -1 "$out")"
else
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  say "  WATCHER DID NOT WAKE (wedge detection lost)"
fi
show_queue "$state" "$window"
say ""

# --- D: a task not in a declared external wait is unaffected ---
dir=$(make_case preserved-lifted); state="$dir/state"; fakebin="$dir/fakebin"
capture="$dir/pane.txt"; out="$dir/watch.out"
window="default:w17:p2"; key=$(printf '%s' "$window" | tr ':/.' '___')
printf '> external wait cleared\n\n  upstream release watch - idle\n' > "$capture"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/release.meta"
printf 'working: external wait cleared, but the pane made no progress\n' > "$state/release.status"
printf '%s' "$(seen_sig "$state/release.status")" > "$state/.seen-release_status"
printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"

say "=== D. same window with the declaration LIFTED (never in a declared wait) ==="
say "status log         : $(tail -1 "$state/release.status")"
say "crew state read    : state: unknown - source: none - no current-state source available"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
  FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_BIN" > "$out" 2>/dev/null &
pid=$!
if wait_for_exit "$pid" 150; then
  say "  WATCHER WOKE FIRSTMATE: $(head -1 "$out")"
else
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  say "  WATCHER DID NOT WAKE (ordinary stale delivery lost)"
fi
show_queue "$state" "$window"
