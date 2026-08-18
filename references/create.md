# Create a managed worktree

Use this procedure only after explicit approval for this creation.

## Prepare

1. Require a non-bare source checkout. Record its branch, `HEAD`, dirty state,
   main worktree, and canonical Git common directory. Resolve the requested
   ref—or current `HEAD`—to one commit without switching the source checkout.
   If a requested review ref is missing locally, fetch only that ref.
2. Create a missing managed root or repository parent with mode `0700`. For an
   existing directory, apply the ownership, mode, and symlink checks in the
   core invariants. Never fall back to `/tmp`, `/private/tmp`, `$TMPDIR`,
   `.claude/worktrees`, `.codex/worktrees`, or elsewhere.
3. Derive `repo-slug` from the main-worktree basename and `task-slug` from the
   task. Make both short, nonempty, and filesystem-safe. Generate a local UUID
   and derive a 12-character lowercase hexadecimal ID. Use path
   `<managed-root>/<repo-slug>/<task-slug>-<id>` and branch
   `xcode-worktree/<task-slug>-<id>`. Resolve the repository directory to its
   canonical path, append the leaf name, and require the result to remain a
   direct child of that directory. Validate the branch with
   `git check-ref-format --branch`, and regenerate the ID on any collision.

## Handle git-crypt without reading protected content

Before creation, query the resolved commit's `filter` attribute for every
tracked path:

```bash
git ls-tree -rz --name-only <commit> |
  git check-attr --source=<commit> --stdin -z filter
```

Create normally when neither `git-crypt` nor `git-crypt-*` applies. Stop for a
named `git-crypt-*` filter. For default `git-crypt`:

1. Require `git-crypt`, repository-local `filter.git-crypt.required=true`, and
   canonical `<git-common-dir>/git-crypt/keys/default` as an ordinary,
   non-symlink file owned by the user with no group/other permissions.
2. Never print protected bytes, export the key, or copy decrypted files from
   another checkout. Create the encrypted worktree with only these temporary
   filter overrides:

   ```bash
   git -c filter.git-crypt.smudge=cat \
       -c filter.git-crypt.clean=cat \
       -c filter.git-crypt.required=false \
       worktree add --no-track -b <branch> <path> <commit>
   ```

3. With no task work in between, unlock the new worktree with the existing key,
   then check out the commit again through the real filters:

   ```bash
   git -C <path> \
       -c filter.git-crypt.smudge=cat \
       -c filter.git-crypt.clean=cat \
       -c filter.git-crypt.required=false \
       crypt unlock <canonical-common-key>
   git -C <path> checkout --force <commit> -- .
   ```

The overrides are setup-only; never use them for later Git or task work.

## Create and verify

Without default git-crypt, create with:

```bash
git worktree add --no-track -b <branch> <path> <commit>
```

Run creation separately, then verify:

- exact canonical registration in the expected common directory;
- `HEAD` at the resolved commit and attached to the new branch;
- `git status --porcelain=v1 --untracked-files=all` succeeds and is empty (use
  `-z` for mechanical parsing);
- when git-crypt is used, `git status` succeeds without overrides; and
- the source checkout branch, `HEAD`, and dirty state are unchanged.

Report path, branch, commit, and expected `<path>/DerivedData` for Xcode. Never
transfer source changes or set an upstream automatically.

On failure, re-read and report Git state. Do not use `rm -rf`, worktree prune,
branch deletion, or destructive rollback.
