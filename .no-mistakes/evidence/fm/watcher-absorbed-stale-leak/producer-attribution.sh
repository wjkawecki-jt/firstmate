#!/usr/bin/env bash
# Producer attribution for the bare `stale: <window>` durable record.
#
# The intent asks to separate the watcher POLLING producer from the Stop-owned
# rewake translation and prove which one enqueues the bare record. This runs the
# PRE-FIX watcher under bash xtrace with a PS4 that prints file:line:function,
# then reports the exact frame that called fm_wake_append for the bare payload.
# No Stop hook (bin/fm-claude-stop-autoarm.sh) runs here at all.
set -u
REPO=${FM_REPRO_REPO:?}
# shellcheck source=/dev/null
. "$REPO/tests/wake-helpers.sh"
WATCH_BIN=$1; OUTDIR=$2
TMP_ROOT=$(fm_test_tmproot fm-repro-producer)
seen_sig() { if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1"; else stat -c '%s:%Y' "$1"; fi; }
dir=$(make_case producer); state="$dir/state"; fakebin="$dir/fakebin"
capture="$dir/pane.txt"; window="default:w17:p2"
key=$(printf '%s' "$window" | tr ':/.' '___')
printf '> paused: awaiting the upstream tool release to land\n\n  upstream release watch - idle\n' > "$capture"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/release.meta"
printf 'paused: awaiting the upstream tool release to land\n' > "$state/release.status"
printf '%s' "$(seen_sig "$state/release.status")" > "$state/.seen-release_status"
printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"

trace="$dir/xtrace.log"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
  FM_FAKE_TMUX_CURRENT_COMMAND=grok \
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}> ' \
  bash -x "$WATCH_BIN" > "$dir/out" 2>"$trace" &
pid=$!
wait_for_exit "$pid" 200 || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

OUT="$OUTDIR/producer-attribution.transcript.txt"
{
  echo "=== which producer enqueued the bare durable record? ==="
  echo "processes started in this run : bin/fm-watch.sh only (no Stop hook, no daemon)"
  echo "watcher wake reason printed   : $(head -1 "$dir/out")"
  echo
  echo "--- xtrace frames around the durable append (file:line:function) ---"
  grep -nE "fm_wake_append stale" "$trace" | tail -3 | sed 's/^/  /'
  echo
  echo "--- the enclosing watcher frame that produced it ---"
  grep -E "^\+ fm-watch.sh:[0-9]+:(surface_nonterminal_stale|stale_scan|main)>" "$trace" \
    | grep -E "fm_wake_append|surface_nonterminal_stale" | tail -4 | sed 's/^/  /'
  echo
  echo "--- durable queue after that append ---"
  awk -F '\t' -v w="$window" '$4 == w { printf "  seq=%s kind=%s key=%s payload=%s\n", $2, $3, $4, $5 }' "$state/.wake-queue"
  echo
  echo "--- the Stop-owned rewake translation never appends a wake record ---"
  echo "  grep -c 'fm_wake_append' bin/fm-claude-stop-autoarm.sh = $(grep -c 'fm_wake_append' "$REPO/bin/fm-claude-stop-autoarm.sh")"
  echo "  it only arms the watcher and turns the watcher's exit into a rewake banner"
} | tee "$OUT"
