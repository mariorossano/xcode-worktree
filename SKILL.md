---
name: xcode-worktree
description: Create, use, inspect, measure, resume, or release durable Git worktrees for Xcode agent tasks, with Xcode DerivedData isolated inside each checkout. Use whenever the user explicitly asks Claude or Codex for an isolated Xcode worktree, asks to use, inspect, measure, or release one, or a session starts inside an already registered Xcode worktree. Do not create or release a worktree merely because a session starts, resumes, clears, compacts, or finishes a task.
---

# Manage Xcode worktrees

Use Git as the source of truth. Keep every worktree created by this skill in one
durable root and keep agent-controlled Xcode DerivedData inside its worktree.
Resolve Git common directories to canonical absolute paths; prefer
`git rev-parse --path-format=absolute --git-common-dir`, and never prepend a
worktree path to a result that is already absolute.

## Scope

This skill is Xcode-first. Its Git worktree lifecycle also works for a non-Xcode
repository, but the isolation contract below specifically covers Xcode
DerivedData. For another build system, do not claim that caches or build output
are isolated unless its project-specific paths have been inspected and kept
inside the worktree.

## Interpret the request

- Create a new worktree only when the user explicitly requests a new worktree or isolated checkout.
- If the session's initial directory is inside an exact, registered worktree below
  the canonical managed root, treat that existing worktree as the user-selected
  execution context. Validate it, keep all task commands there, and apply the
  Xcode DerivedData rules before the first build. Do not create another worktree.
- Treat every new creation request as a new worktree, even when its task matches an existing one.
- For parallel implementation variants, create one independent worktree and branch per variant. Resolve all variants from the same commit when the user is comparing equivalent approaches; never base one variant on another.
- Treat each worktree as single-writer. Never assign or resume the same worktree for concurrent agents; give each agent its own variant. An explicit release means the user considers every agent using that exact worktree finished. If known activity contradicts that, stop.
- From outside the managed worktree, resume an existing one only when the user
  explicitly asks to resume or use it.
- Release a worktree only when the user explicitly asks to release, remove, or discard it.
- Do not interpret task completion, a push, session exit, `clear`, resume, or compaction as release.
- Ask the user to choose when more than one existing worktree matches and no exact path is given.

## Use the managed root

Use the absolute expansion of:

```text
~/.xcode-worktrees
```

Only in an isolated contract test, honor an already-set absolute
`XCODE_WORKTREE_ROOT`. Never set or suggest that variable during normal use.

- Create the root with mode `0700` when absent. On every use, canonicalize it and require it to be an ordinary, non-symlink directory owned by the current user with no group or other permission bits. If an existing root is too permissive, ask before fixing it.
- If it is not writable, request the required permission or stop. Never fall back to `/tmp`, `/private/tmp`, `$TMPDIR`, `.claude/worktrees`, `.codex/worktrees`, or another agent-chosen path.
- Use this layout, where the leaf directory itself is the Git worktree:

  ```text
  <managed-root>/<repo-slug>/<task-slug>-<short-id>
  ```

- Derive `repo-slug` from the basename of the main worktree reported by `git worktree list --porcelain -z`.
- Make both slugs short, nonempty, and filesystem-safe. Generate `short-id` as 12 lowercase hexadecimal characters from a local UUID.
- Use branch `xcode-worktree/<task-slug>-<short-id>` and validate it with `git check-ref-format --branch`.
- Create a missing repo parent with mode `0700`. On every use require it to be an ordinary, non-symlink directory directly under the root, owned by the current user, with no group or other permission bits.

## Discover worktrees

When repository context is available, use:

```bash
git worktree list --porcelain -z
```

Do not infer registration from a directory alone. Validate candidates with Git and compare their Git common directory.

When no repository context is available, require an explicit repository/path or enumerate only the two directory levels defined by the managed layout. Do not follow symlinks or recursively scan checkout contents or build output. Validate every candidate with Git before reporting or using it.

## Create a worktree

1. Verify the current directory belongs to a non-bare Git checkout. Record its branch, `HEAD`, main worktree, and Git common directory.
2. Use the user-specified base ref. If none is specified, use the current `HEAD`.
3. Resolve the base to one commit before creating anything. If a requested review ref is absent locally, perform only the targeted fetch needed to resolve it; do not switch the original checkout.
4. Generate fresh slugs, ID, branch, and absolute managed path. Regenerate the ID if either branch or path collides.
5. Verify the managed root and repo parent as above and that the new path remains below them.
6. Detect `git-crypt` before creating anything by asking Git which `filter`
   attributes apply to every tracked path in the resolved base commit. Use a
   NUL-delimited `git ls-tree -r --name-only` piped to
   `git check-attr --source=<base-commit> --stdin -z filter`; do not inspect
   protected file contents or rely only on the current working tree. If no
   applied filter is `git-crypt` or starts with `git-crypt-`, continue with the
   normal creation in step 7 and do not require `git-crypt` to be installed.
   When the default `git-crypt` filter applies:

   - require `git-crypt` to be available;
   - require the repository-local `filter.git-crypt.required` setting to be
     true, confirming that the source repository has been initialized;
   - resolve `<git-common-dir>/git-crypt/keys/default` canonically and require it
     to be an ordinary, non-symlink file owned by the current user with no group
     or other permission bits;
   - stop if the key is absent or if an applied named `git-crypt-*` filter is found;
     never request, export, print, or copy decrypted files from another checkout;
   - create the fresh worktree with only the default `git-crypt` filters neutralized:

     ```bash
     git -c filter.git-crypt.smudge=cat \
         -c filter.git-crypt.clean=cat \
         -c filter.git-crypt.required=false \
         worktree add --no-track -b <branch> <absolute-path> <base-commit>
     ```

   - without running any task command in between, install the existing key into
     the linked worktree's private Git directory and then replace the temporary
     encrypted checkout through the real filters:

     ```bash
     git -C <absolute-path> \
         -c filter.git-crypt.smudge=cat \
         -c filter.git-crypt.clean=cat \
         -c filter.git-crypt.required=false \
         crypt unlock <canonical-common-key>
     git -C <absolute-path> checkout --force <base-commit> -- .
     ```

   The temporary overrides are valid only for these two setup commands. Never
   use them for status, diff, add, commit, checkout, merge, or task work. The
   final checkout must run without overrides so protected files are decrypted
   in the working tree and encrypted by Git when staged.

7. Otherwise create the branch and worktree with the equivalent of:

   ```bash
   git worktree add --no-track -b <branch> <absolute-path> <base-commit>
   ```

   Run this state-changing Git command separately from the surrounding read-only checks.

8. Verify that Git registers the exact path, that `HEAD` equals the resolved base
   commit, that `git status --porcelain=v1 --untracked-files=all` succeeds and is
   empty in the new worktree, and that the original checkout branch and dirty
   state are unchanged. A `git-crypt` filter error or an unexpectedly dirty new
   worktree is a creation failure; report it and do not begin task work.
9. Report the absolute path, branch, and base commit. For an Xcode task, also
   report the expected Xcode DerivedData path. For a non-Xcode task, state that
   the worktree is Git-only and that external build caches are not covered.
10. Direct every edit, search, command, test, and build for the task to the new worktree. Use an explicit working directory or absolute path for tools that do not change session directory.

Do not transfer uncommitted changes from the original checkout and do not assign an upstream automatically.

If creation fails, re-read Git state and report what exists. Do not use `rm -rf`, `git worktree prune`, branch deletion, or another destructive rollback.

## Enter and leave in each agent

### Claude Code

Do not call `EnterWorktree` for a managed external worktree. It relocates
Claude's permission root and causes a native confirmation for paths outside
`.claude/worktrees`, while this skill deliberately owns worktrees below
`~/.xcode-worktrees`.

If Claude starts inside the selected managed worktree, validate it and continue
in place. If Claude starts elsewhere and creates or resumes one, keep the
session anchored to its initial checkout and target the managed path with
explicit absolute paths or working directories for every read, edit, command,
test, and build. Do not use `ExitWorktree`, `claude --worktree`, or Claude's
default `.claude/worktrees` creator.

### Codex CLI

Keep the session anchored to its original checkout. Set each tool's `workdir` to the managed worktree or use absolute paths. Never create a temporary worktree to work around sandbox permissions.

## Keep Xcode DerivedData inside the worktree

Apply this section whenever the task builds an Xcode project or workspace. For
a non-Xcode build, do not invent a DerivedData path: retain the Git lifecycle
rules, inspect that build system separately, and state which local or external
outputs are not isolated.

For each agent-controlled build, determine the effective output path before building:

1. Keep a path already configured by the repository only when its normalized absolute path and nearest existing ancestor both resolve inside this worktree, no existing path component is a symlink, and `git ls-files -- <relative-path>` reports no tracked content below it.
2. Otherwise apply the same checks to `<worktree>/DerivedData`. Verify its directory ignore rule before it exists with `git check-ignore --no-index <effective-path>/`, including the trailing slash; do not create a probe.
3. If no internal ignored path is available, stop before the build and ask permission to add an appropriate ignore rule. Never silently edit `.gitignore` or invent an external fallback.

Apply the effective DerivedData path to every Xcode build interface. Inspect the interface's live
defaults or supported configuration before invoking it, use a per-invocation or
non-persistent session override, and verify that the normalized effective output
path remains inside the current worktree. If a build wrapper, plugin, or MCP does
not expose a way to control and verify its output location, stop before building
and report that isolation cannot be guaranteed; never silently use a shared
external cache.

Known interface mappings include:

- raw `xcodebuild`: pass `-derivedDataPath <effective-path>`;
- Fastlane: use its internal ignored `derived_data_path`, or override it with the effective path;
- XcodeBuildMCP: follow its installed skill, call `session_show_defaults`, then set the worktree `workspacePath` or `projectPath` plus `derivedDataPath` with `persist: false`.

For another Xcode MCP or build integration, inspect its own capabilities and use
its equivalent workspace/project and DerivedData settings. Do not assume
that an option name or behavior from XcodeBuildMCP applies to a different tool.

After switching worktrees, re-check XcodeBuildMCP defaults before every first build/test action. Restore prior session defaults before release when available. Never persist a worktree path that will later be removed.

Treat other ignored Xcode build products as managed only when they remain inside
the worktree. Report any tool or script that writes outside; do not promise to
clean external caches, manually launched Xcode builds, or simulator state.

## Inspect and measure

- Report active path, branch, commit, dirty state, and effective Xcode DerivedData path from live Git/filesystem checks.
- Do not claim last-used time, agent ownership, session ownership, or historical state.
- Measure disk usage only when the user asks. Report total worktree size, effective DerivedData size when identifiable, and the remainder without double counting.
- Do not save measurements. Do not attribute shared objects in the main Git common directory to one worktree.

## Release a worktree

Treat an explicit release request as authorization to discard staged, unstaged, untracked, and ignored files inside the selected worktree. Do not ask a second confirmation merely because it is dirty.

1. Resolve one exact candidate. If ambiguous, ask; do not guess.
2. If both its directory and Git registration are already absent, report that it is no longer present and stop.
3. If filesystem and Git registration disagree, stop without manual cleanup.
4. Record its branch and `HEAD`. Refuse release if it is the main worktree, its canonical path lies outside the canonical managed root, its managed repo parent or leaf is a symlink, it belongs to another Git common directory, it is not registered at the exact path, or it no longer has a branch to preserve.
5. Run `git status --porcelain=v1 --untracked-files=all` in the worktree and summarize tracked and untracked content that will be discarded; use `-z` if names are parsed mechanically. State that ignored content is also discarded but intentionally not exhaustively enumerated. Report known internal Xcode DerivedData directories by checking only whether they exist; do not recursively enumerate ignored files or measure them unless the user asked for a size measurement.
6. While the path still exists, complete and verify all known task cleanup: stop task processes, release task-owned external resources, and restore temporary tool state through their owning interfaces. Ignore unrelated integrations and ambiguous ownership; preserve the worktree if required cleanup fails.
7. As the last state-changing action, remove exactly the registered path with:

   ```bash
   git worktree remove --force <absolute-path>
   ```

   Run this state-changing Git command separately from the surrounding read-only checks.

8. After removal, perform only read-only verification: confirm that the directory and worktree registration are gone and that the recorded branch still exists at its recorded commit.
9. Report the removed checkout and Xcode DerivedData, preserved branch, completed external cleanup, and whether uncommitted content was discarded.

Use exactly one `--force`. If the worktree is locked or Git refuses removal, stop and preserve everything. Never use a second `--force`, `rm -rf`, `git worktree prune`, automatic stash, WIP commit, snapshot, or branch deletion.

Recovery from a lock, detached branch, or filesystem/Git mismatch is outside release. Report the exact state and stop; do not unlock, repair, prune, or invent a recovery unless the user separately requests that operation.
