# Absorbed paused-task stale-wake leak - end-to-end evidence

Every transcript below comes from driving the REAL `bin/fm-watch.sh` (nothing in the code
under test is stubbed) against a hermetic tmux / fm-crew-state backend, in the same
arm -> wake -> handle -> re-arm loop firstmate runs in production. Each watcher exit is one
burned firstmate handling turn. Producing scripts are beside this file:
`repro-absorbed-stale-leak.sh`, `repro-preserved-behaviors.sh`, `producer-attribution.sh`.

Scenario: one ship crew in `default:w17:p2` (harness=grok, backend=tmux) that declared
`paused: awaiting the upstream tool release to land` while its grok endpoint is still LIVE,
and whose harness footer ticks a clock, so a new pane hash is minted every few polls.

## 1. The reported reproduction, on the pre-fix watcher (base bca584a)

The two records the report names, side by side: `absorbed stale (paused, awaiting external, age Ns)`
in the triage log, and the bare `stale: default:w17:p2` durable queue row that nevertheless
reached a handling turn - one per footer tick.

```
=== before-fix: live grok endpoint under a declared external wait, footer ticking ===
watcher under test : /tmp/fm-prefix/bin/fm-watch.sh
window             : default:w17:p2   (kind=ship, harness=grok, backend=tmux)
status log         : paused: awaiting the upstream tool release to land
crew state read    : state: paused - source: status-log - awaiting the upstream tool release
endpoint liveness  : tmux pane_current_command=grok  (agent ALIVE)

--- harness footer tick 1 (new pane hash) ---
  WATCHER EXITED -> firstmate handling turn #1: stale: default:w17:p2
    durable queue row: seq=1 kind=stale key=default:w17:p2 payload=stale: default:w17:p2
--- harness footer tick 2 (new pane hash) ---
  WATCHER EXITED -> firstmate handling turn #2: stale: default:w17:p2
    durable queue row: seq=2 kind=stale key=default:w17:p2 payload=stale: default:w17:p2
--- harness footer tick 3 (new pane hash) ---
  WATCHER EXITED -> firstmate handling turn #3: stale: default:w17:p2
    durable queue row: seq=3 kind=stale key=default:w17:p2 payload=stale: default:w17:p2
--- harness footer tick 4 (new pane hash) ---
  WATCHER EXITED -> firstmate handling turn #4: stale: default:w17:p2
    durable queue row: seq=4 kind=stale key=default:w17:p2 payload=stale: default:w17:p2

--- every durable wake record this run enqueued for default:w17:p2 ---
  durable queue row: seq=1 kind=stale key=default:w17:p2 payload=stale: default:w17:p2
  durable queue row: seq=2 kind=stale key=default:w17:p2 payload=stale: default:w17:p2
  durable queue row: seq=3 kind=stale key=default:w17:p2 payload=stale: default:w17:p2
  durable queue row: seq=4 kind=stale key=default:w17:p2 payload=stale: default:w17:p2

--- watcher triage log (/var/folders/4h/96rnpzn57r1146sj23ddd6h40000gq/T//fm-repro-before-fix.4nvS0f/before-fix/state/.watch-triage.log) ---
  [2026-08-28T03:02:31+0200] absorbed stale (paused, awaiting external, age 451s): default:w17:p2
  [2026-08-28T03:02:39+0200] absorbed stale (paused, awaiting external, age 459s): default:w17:p2
  [2026-08-28T03:02:41+0200] absorbed stale (paused, awaiting external, age 461s): default:w17:p2
  [2026-08-28T03:02:43+0200] absorbed stale (paused, awaiting external, age 463s): default:w17:p2
  [2026-08-28T03:02:44+0200] absorbed stale (paused, awaiting external, age 464s): default:w17:p2
  [2026-08-28T03:02:46+0200] absorbed stale (paused, awaiting external, age 466s): default:w17:p2
  [2026-08-28T03:02:48+0200] absorbed stale (paused, awaiting external, age 468s): default:w17:p2
  [2026-08-28T03:02:56+0200] absorbed stale (paused, awaiting external, age 476s): default:w17:p2
  [2026-08-28T03:02:58+0200] absorbed stale (paused, awaiting external, age 478s): default:w17:p2
  [2026-08-28T03:02:59+0200] absorbed stale (paused, awaiting external, age 479s): default:w17:p2
  [2026-08-28T03:03:01+0200] absorbed stale (paused, awaiting external, age 481s): default:w17:p2
  [2026-08-28T03:03:03+0200] absorbed stale (paused, awaiting external, age 483s): default:w17:p2

RESULT: firstmate handling turns burned = 4 ; bare 'stale: default:w17:p2' durable records = 4
```

## 2. The same run on the fixed watcher (22b3fd1)

Same absorb decisions, zero durable rows, zero handling turns.

```
=== after-fix: live grok endpoint under a declared external wait, footer ticking ===
watcher under test : /Users/wjkawecki/.no-mistakes/worktrees/f22cd5749b0c/01M12X3Z31H3CJAKCERMKDJRK0/bin/fm-watch.sh
window             : default:w17:p2   (kind=ship, harness=grok, backend=tmux)
status log         : paused: awaiting the upstream tool release to land
crew state read    : state: paused - source: status-log - awaiting the upstream tool release
endpoint liveness  : tmux pane_current_command=grok  (agent ALIVE)

--- harness footer tick 1 (new pane hash) ---
--- harness footer tick 2 (new pane hash) ---
--- harness footer tick 3 (new pane hash) ---
--- harness footer tick 4 (new pane hash) ---

--- every durable wake record this run enqueued for default:w17:p2 ---
  (none - the absorb decision kept every wake out of the durable queue)

--- watcher triage log (/var/folders/4h/96rnpzn57r1146sj23ddd6h40000gq/T//fm-repro-after-fix.I6lPyL/after-fix/state/.watch-triage.log) ---
  [2026-08-28T03:08:11+0200] absorbed stale (paused, awaiting external, age 435s): default:w17:p2
  [2026-08-28T03:08:12+0200] absorbed stale (paused, awaiting external, age 436s): default:w17:p2
  [2026-08-28T03:08:14+0200] absorbed stale (paused, awaiting external, age 438s): default:w17:p2
  [2026-08-28T03:08:17+0200] absorbed stale (paused, awaiting external, age 441s): default:w17:p2
  [2026-08-28T03:08:21+0200] absorbed stale (paused, awaiting external, age 445s): default:w17:p2
  [2026-08-28T03:08:23+0200] absorbed stale (paused, awaiting external, age 447s): default:w17:p2
  [2026-08-28T03:08:24+0200] absorbed stale (paused, awaiting external, age 448s): default:w17:p2
  [2026-08-28T03:08:27+0200] absorbed stale (paused, awaiting external, age 451s): default:w17:p2
  [2026-08-28T03:08:30+0200] absorbed stale (paused, awaiting external, age 454s): default:w17:p2
  [2026-08-28T03:08:32+0200] absorbed stale (paused, awaiting external, age 456s): default:w17:p2
  [2026-08-28T03:08:34+0200] absorbed stale (paused, awaiting external, age 458s): default:w17:p2
  [2026-08-28T03:08:35+0200] absorbed stale (paused, awaiting external, age 459s): default:w17:p2

RESULT: firstmate handling turns burned = 0 ; bare 'stale: default:w17:p2' durable records = 0
```

## 3. Which producer enqueued the bare record

The watcher POLLING loop, not the Stop-owned rewake translation: the pre-fix run under
bash xtrace names the exact frame, and no Stop hook ran at all.

```
=== which producer enqueued the bare durable record? ===
processes started in this run : bin/fm-watch.sh only (no Stop hook, no daemon)
watcher wake reason printed   : stale: default:w17:p2

--- xtrace frames around the durable append (file:line:function) ---
  1575:+ fm-watch.sh:764:surface_nonterminal_stale> fm_wake_append stale default:w17:p2 'stale: default:w17:p2'

--- the enclosing watcher frame that produced it ---
  + fm-watch.sh:771:surface_nonterminal_stale> :
  + fm-watch.sh:772:surface_nonterminal_stale> date +%s
  + fm-watch.sh:773:surface_nonterminal_stale> date +%s
  + fm-watch.sh:777:surface_nonterminal_stale> wake 'stale: default:w17:p2'

--- durable queue after that append ---
  seq=1 kind=stale key=default:w17:p2 payload=stale: default:w17:p2

--- the Stop-owned rewake translation never appends a wake record ---
  grep -c 'fm_wake_append' bin/fm-claude-stop-autoarm.sh = 0
  it only arms the watcher and turns the watcher's exit into a rewake banner
```

## 4. What the fix preserves (fixed watcher)

```
watcher under test : /Users/wjkawecki/.no-mistakes/worktrees/f22cd5749b0c/01M12X3Z31H3CJAKCERMKDJRK0/bin/fm-watch.sh

=== B. declared external wait, LIVE grok endpoint, wait older than the recheck cadence ===
status log         : paused: awaiting the upstream tool release to land   (declared 600s ago)
FM_PAUSE_RESURFACE_SECS=240  -> the bounded recheck is due
  WATCHER WOKE FIRSTMATE: stale: default:w17:p2 (paused 601s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)
  durable queue row: seq=1 kind=stale key=default:w17:p2 payload=stale: default:w17:p2 (paused 601s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)

=== C. genuine wedge: no declaration, pane frozen past FM_STALE_ESCALATE_SECS=240 ===
status log         : working: still compiling the release bundle   (no paused:/captain-held: declaration)
idle timer         : 500s on a static pane
  WATCHER WOKE FIRSTMATE: stale: default:w21:p2 (idle 501s, possible wedge, escalation 1)
  durable queue row: seq=1 kind=stale key=default:w21:p2 payload=stale: default:w21:p2 (idle 501s, possible wedge, escalation 1)

=== D. same window with the declaration LIFTED (never in a declared wait) ===
status log         : working: external wait cleared, but the pane made no progress
crew state read    : state: unknown - source: none - no current-state source available
  WATCHER WOKE FIRSTMATE: stale: default:w17:p2
  durable queue row: seq=1 kind=stale key=default:w17:p2 payload=stale: default:w17:p2
```

## 5. The regression test fails before the fix and passes after it

`tests/fm-watch-triage.test.sh :: test_declared_waits_use_bounded_cadence_until_released`,
run unchanged against the base `bin/fm-watch.sh` and then against the branch's:

### Before (base bca584a watcher)
```
ok - repeated busy turn-age escalations reuse the existing escalation counter and demand deep inspection at the threshold
ok - the production default busy-turn-age bound is 3600s (5min under does not wedge, 66min over does)
ok - a busy pane under a declared pause is rechecked on the long cadence, and lifting the pause restores the wedge escalation
ok - away mode hands a busy declared pause to the daemon as a plain stale, and lifting the declaration restores the wedge escalation
ok - away mode wakes the daemon once per declaration for a busy pane whose footer ticks on every capture
ok - a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)
ok - a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated
not ok - live declared external wait produced a bare stale wake: stale: test:fm-gate

(suite exit code: 1 - tests/fm-watch-triage.test.sh run against the base bca584a bin/fm-watch.sh)
```

### After (branch watcher)
```
37:ok - declared waits use the bounded cadence for live or exited endpoints and across a churning pane hash, a live captain hold surfaces once then falls back to that cadence, and lifting the pause restores genuine stale delivery

62 ok, 0 not ok - tests/fm-watch-triage.test.sh run against the branch bin/fm-watch.sh (exit code 0)
```
