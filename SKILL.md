---
name: xcode-worktree
description: Manage durable Git worktrees for Xcode tasks and keep DerivedData inside each checkout. Use whenever the user asks to create, use, inspect, measure, resume, or release any Git worktree for an Xcode task—even if they say only "use a worktree"; when a session starts inside a registered managed worktree; or before an Xcode interface action after the session has made one active. Create and release only on explicit request.
---

# Manage Xcode worktrees

Git is the source of truth. Resolve its common directory to a canonical absolute
path with `git rev-parse --path-format=absolute --git-common-dir`; never prepend
the worktree path to an already absolute result. Managed worktrees always use
this layout:

```text
~/.xcode-worktrees/<repo-slug>/<task-slug>-<short-id>
```

## Read the procedure for the current phase

Read each applicable reference completely before acting:

| Phase | Required procedure |
| --- | --- |
| Create a worktree | [references/create.md](references/create.md) |
| Load, inspect, discover, list, resolve, build, test, or run an Xcode project | [references/xcode-isolation.md](references/xcode-isolation.md) |
| Release a worktree | [references/release.md](references/release.md) |

## Invariants

- A request such as "use a worktree" explicitly authorizes one fresh managed
  worktree for that task unless the user identifies an exact existing path.
  Every later creation requires another explicit request.
- Release only when the user explicitly asks to release, remove, or discard a
  worktree. Completion, push, exit, clear, resume, or compaction is not release.
  Releasing a worktree preserves its branch.
- A worktree has one writer. Concurrent agents or comparison variants use
  separate worktrees; equivalent variants start at the same commit, never from
  each other. Do not release one while a known agent or build uses it.
- Keep every managed `HEAD` attached to its registered branch for its entire
  life. Identify a managed worktree by its canonical path, exact Git
  registration, and Git common directory—not by folder or branch name alone.
- The managed root (`~/.xcode-worktrees`) and each repository directory below
  it must be ordinary non-symlink directories owned by the current user,
  writable, and mode `0700`. Ask before repairing an existing directory that
  fails these checks.
- Treat every path whose filter is `git-crypt` or `git-crypt-*` as protected
  for the worktree's whole life. Never read or parse one merely to verify
  decryption—no `cat`, `head`, `tail`, `strings`, `file`, `plutil`, preview, or
  parser. Use attributes, filter state, command results, `git status`, and
  metadata that exposes no file bytes.
- For non-Xcode projects, apply only the Git lifecycle. Do not claim that build
  caches are isolated without independently verifying that build system's
  output paths.

## Keep one worktree active

A session has at most one active managed worktree. Read-only discovery and
inspection do not make one active. When a session starts inside an exactly
registered managed worktree, make that path active without creating another.
Otherwise make a worktree active only when the user creates, resumes, or
identifies it explicitly. Never select one because a tool default or filesystem
scan found it.

Keep the exact active path across prompts, subtasks, compaction, directory
changes, and tool changes. Before later task work, confirm its registration,
Git common directory, and attached branch. Stop if the path is missing or
ambiguous.

When the user requests a Git ref, resolve it to one commit. Continue in the
active worktree only when its `HEAD` already equals that commit. Otherwise
leave it unchanged and ask whether to create a fresh worktree. The ref request,
a build/test/run request, and any earlier approval do not authorize creation.
After explicit approval, follow the creation procedure and make the new path
active. Never search for or switch to a matching worktree automatically; reuse
an existing one only when the user identifies its exact path.

Never merge, rebase, checkout, reset, detach, or move a managed branch to meet
a ref request. Releasing the active worktree clears selection; do not guess a
replacement.

## Discover and inspect

With repository context, discover registrations using:

```bash
git worktree list --porcelain -z
```

Without repository context, require an explicit path/repository or enumerate
only the two managed layout levels. Never follow symlinks or recursively scan
checkout/build contents. Validate candidates with Git and ask when ambiguous.

Report path, branch, commit, dirty state, and effective DerivedData from live
checks. Do not infer an agent, owner, or session history from names or earlier
observations. Measure only when asked, separating DerivedData from the rest
without double counting or persisting results. Never attribute Git objects
stored in the shared common directory to one worktree.

## Work through the active path

Target every read, edit, command, test, and build through the explicit active
working directory or absolute path.

Do not hand managed paths to an agent's built-in worktree feature. Claude Code
never calls `EnterWorktree`, `ExitWorktree`, or its default creator for them;
Codex never creates a temporary worktree for them. When started inside the
active path, stay there. Otherwise keep the session anchored and target the
active path explicitly.

If a required phase reference cannot be completed, preserve the worktree and
stop.
