#!/usr/bin/env bash
# Prove the colocated regression cases fail on pre-fix code.
#
#   usage: discriminate.sh <repo-with-prefix-spawn> <label> [case ...]
#
# Copies tests/fm-spawn-pool-base-freshen.test.sh verbatim except for the trailing
# runner list, which is replaced by one case at a time, so each case gets its own
# verdict instead of the suite stopping at the first failure. The tests themselves
# are unmodified; only which of them runs changes.
set -u
REPO=${1:?usage: discriminate.sh <repo-root> <label> [case ...]}
LABEL=${2:?usage: discriminate.sh <repo-root> <label> [case ...]}
shift 2
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="${FM_SRC_TESTS:?set FM_SRC_TESTS to the current tests/fm-spawn-pool-base-freshen.test.sh}"
CASES=("$@")
if [ "${#CASES[@]}" -eq 0 ]; then
  CASES=(
    test_acquired_worktree_is_seeded_with_local_env_file
    test_acquired_worktree_refreshes_a_stale_local_env_file
    test_acquired_worktree_retires_a_local_env_file_the_captain_deleted
    test_interrupted_local_env_seed_leaves_the_slot_acquirable
    test_interrupted_seed_scratch_does_not_outlive_revocation
    test_scratch_is_swept_even_when_the_pre_refresh_phase_refuses
    test_cross_filesystem_layout_degrades_to_a_loud_skip
    test_unanswerable_filesystem_question_still_refuses
    test_unignored_local_env_file_is_not_seeded
    test_unignored_copy_matching_the_source_is_retired
    test_unignored_copy_differing_from_the_source_is_kept
    test_tracked_local_env_file_is_never_touched
  )
fi
RUNNER_LINE=$(grep -n '^test_stale_pool_base_refreshes_before_branching$' "$SRC" | head -1 | cut -d: -f1)

echo "current tests/fm-spawn-pool-base-freshen.test.sh run against: $REPO/bin/fm-spawn.sh"
echo "spawn under test: $LABEL"
echo
for t in "${CASES[@]}"; do
  drv="$REPO/tests/one-case.test.sh"
  head -n $((RUNNER_LINE - 1)) "$SRC" > "$drv"
  printf '%s\n' "$t" >> "$drv"
  out=$(bash "$drv" 2>&1); rc=$?
  printf 'rc=%s  %s\n        %s\n' "$rc" "$t" "$(printf '%s\n' "$out" | grep -E '^(not )?ok - ' | tail -n 1)"
  rm -f "$drv"
done
: "$HERE"
