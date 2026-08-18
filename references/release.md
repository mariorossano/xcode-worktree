# Release a managed worktree

Explicit release authorizes discarding all staged, unstaged, untracked, and
ignored files inside the release target. Do not reconfirm dirtiness or infer
release from completion.

## Validate the target

1. Resolve exactly one registered worktree; ask the user when the target is
   ambiguous.
2. If both its directory and Git registration are absent, report that the
   worktree is already gone and stop. If only one is absent, stop without
   attempting repair.
3. Record branch and `HEAD`. Release only if all of these checks pass:
   - it is not the main worktree;
   - its canonical path is below the managed root;
   - neither its repository parent nor its leaf is a symlink;
   - Git registers that exact canonical path in the target repository's Git
     common directory; and
   - `HEAD` is attached to an `xcode-worktree/...` branch that still points to
     that `HEAD` commit.
4. Run `git status --porcelain=v1 --untracked-files=all`; summarize the tracked
   and untracked content that removal will discard (`-z` when parsing), and
   state that removal also discards ignored content. Only check whether
   worktree-local DerivedData exists; enumerate or measure ignored files only
   when asked.

## Prepare for removal

1. Stop only identified processes that are using the release target; do not
   kill processes by a broad name or pattern.
2. Before deleting the worktree directory, complete any cleanup that another
   applicable skill requires from inside that directory. Follow the other
   skill's procedure. If required cleanup fails, preserve the worktree.
3. If this skill changed a build interface's project/workspace or DerivedData
   path, restore the recorded previous value when it is still valid. Clear the
   setting when it was previously unset or the previous value is no longer
   valid. Re-read the interface and verify that it no longer references the
   release target or its worktree-local DerivedData. Invocation-scoped settings
   require no cleanup.

## Remove last

After completing the preparation above, make worktree removal the final
state-changing action. Run it separately:

```bash
git worktree remove --force <exact-registered-path>
```

Use one `--force`. Afterwards only verify, read-only, that directory and
registration are gone and the branch remains at its commit. Report the removed
checkout and DerivedData, discarded content, any prerequisite cleanup, and the
preserved branch.

On lock, detached branch, Git/filesystem mismatch, or refusal, stop. Never use
a second force, `rm -rf`, worktree prune, automatic stash/WIP commit, branch
deletion, unlock, or improvised recovery without a separate user request.
