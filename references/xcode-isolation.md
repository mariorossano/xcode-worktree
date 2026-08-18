# Isolate the Xcode checkout and DerivedData

An Xcode action loads, inspects, discovers, lists, resolves, builds, tests, or
runs a project/workspace. Apply this procedure before the first action after a
worktree becomes active and whenever input, configuration, or interface changes.

## Preflight

1. Revalidate the active worktree.
2. Resolve the exact checkout, project, or workspace input. Every explicit path
   and every current directory used for discovery must be inside the active
   worktree.
3. Keep an already configured DerivedData path only when its canonical path and
   nearest existing ancestor are inside the active worktree, no existing path
   component is a symlink, and
   `git -C <worktree> ls-files -- <relative-path>` reports no tracked content.
   Otherwise validate and use `<worktree>/DerivedData`.
4. Before using or creating the chosen DerivedData directory, derive its path
   relative to the worktree and run
   `git -C <worktree> check-ignore --no-index <relative-path>/` with the
   trailing slash. If the chosen path is not ignored, ask before adding an
   ignore rule. Never edit an ignore rule silently or fall back outside the
   active worktree.
5. Configure the selected project or workspace and DerivedData per invocation
   or non-persistently. Verify both from live settings when readable, otherwise
   from the exact invocation. Stop unless both paths are inside the active
   worktree.

Before changing a build interface's session or persistent settings for the
first time, record the exact previous project/workspace and DerivedData paths,
including any unset value. If a previous value cannot be read, use
invocation-scoped configuration that leaves no state behind, or stop.

## Discovery is not exempt

Listing, settings inspection, discovery, and dependency resolution can populate
DerivedData, so they use the same rule. When isolation is unavailable, use
non-Xcode repository metadata or stop.

Determine supported controls from documentation or help, never by trial Xcode
actions: even a rejected probe can write diagnostics outside the worktree.

Never use raw `xcodebuild -list` to discover schemes. Obtain them from
repository metadata or an interface whose outputs are all verifiably inside
the active worktree. For every other raw `xcodebuild` action, run from the
active worktree with a known project or workspace inside it and a verified
worktree-local `-derivedDataPath`.

For wrappers, editors, MCPs, and other integrations, use their documented
controls to set the same project/workspace and DerivedData paths. Stop if
either path cannot be controlled and verified.

## Continue safely

At each later prompt or subtask with an Xcode action, revalidate the active
worktree and effective configuration. Within the same prompt or subtask,
consecutive actions may reuse an unchanged, verified configuration without
repeating the preflight.

After each build, test, or run, refresh Git status before reporting clean or
dirty; generated tracked files may have changed.

Report other writes outside the worktree; never claim they are isolated or
managed by this skill.
