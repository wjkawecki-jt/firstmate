# `.env.local` across teardown and pool reissue - test evidence

All artifacts here were produced against the real `bin/fm-spawn.sh` and
`bin/fm-teardown.sh`, over a real git project and a real linked worktree standing in
for a treehouse pool slot.
The file bytes in every fixture are a synthetic marker (`...-not-a-real-credential`),
and no transcript prints the file's contents: they report presence, mode, ownership,
and a yes/no byte-identity verdict only.

## Files

| file | what it shows |
| --- | --- |
| `e2e-env-local-reissue.sh` | the harness: spawn task-alpha into a pooled slot, `fm-teardown.sh --force` returns the slot, spawn task-bravo onto the reissued slot |
| `e2e-prefix-transcript.txt` | the reported failure on pre-fix code (base `4f89f5b`): present before teardown, ABSENT after, still ABSENT after reissue |
| `e2e-fixed-transcript.txt` | the same cycle on this branch: ABSENT after teardown, restored byte-identically on reissue, mode `640` preserved, slot `git status` clean |
| `discriminate.sh` | runs one case of `tests/fm-spawn-pool-base-freshen.test.sh` at a time against a chosen `fm-spawn.sh`, so each case gets its own verdict |
| `discrimination-prefix.txt` | all 12 colocated `.env.local` cases fail against the pre-fix spawn |
| `discrimination-entry-sweep.txt` | the case added by the target commit `4320c58` fails against `78c6659` (where the scratch sweep still sat after the pre-refresh block) while the pre-existing scratch case passes there |

## Reproducing

```sh
# fixed
bash e2e-env-local-reissue.sh /path/to/firstmate 'FIXED'

# pre-fix: copy the repo, drop the base version of the one changed script in
PRE=$(mktemp -d); rsync -a --exclude .git /path/to/firstmate/ "$PRE/"
git -C /path/to/firstmate show 4f89f5b:bin/fm-spawn.sh > "$PRE/bin/fm-spawn.sh"
bash e2e-env-local-reissue.sh "$PRE" 'PRE-FIX'

# per-case discrimination
FM_SRC_TESTS=/path/to/firstmate/tests/fm-spawn-pool-base-freshen.test.sh \
  bash discriminate.sh "$PRE" 'pre-fix'
```

The `treehouse` fake in the harness answers `return --force <slot>` with
`git reset --hard` + `git clean -fdx`, which is the state a reissued slot is observed
in: no leftover working-tree files, git-ignored ones included.
That is the end state the failure report describes, and it is what the two
transcripts differ on.
