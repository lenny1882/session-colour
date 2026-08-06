---
name: release
description: Cut a new session-colour release — bump VERSION on main, merge main into the matching release/vX.x branch, and tag there so the GitHub Actions release workflow publishes it. Use when the user asks to cut, ship, or publish a new release/version of this repo.
---

# Cutting a session-colour release

[`.github/workflows/release.yml`](../../../.github/workflows/release.yml)
turns any pushed `vX.Y.Z` tag into a GitHub Release. It does **not** check
which branch the tag came from — a tag push and a branch push are separate
events, so the workflow can't tell. That guarantee is enforced here instead,
by process: **a release tag only ever gets created on its `release/vX.x`
branch, after `main` has been merged into it.** This skill is the only place
that should create release tags in this repo — follow it in order, and don't
tag straight off `main` or anywhere else.

There is one release branch per major version. `release/v1.x` carries every
`1.Y.Z` release, `release/v2.x` every `2.Y.Z`. Minor versions do not get
their own branch.

Treat every push in this skill as something to confirm with the user first —
they're visible to anyone watching the repo, and the last step publishes a
public GitHub Release.

## 1. Confirm `main` is ready to release

- `git status --porcelain` must be empty. If not, stop and ask whether to
  commit, stash, or discard those changes first — don't decide for the user.
- `git fetch origin`, then compare local `main` against `origin/main`. Pull
  if local is behind. If local has commits `origin/main` doesn't, that's
  expected — they're what's about to be released — but confirm that's really
  what the user wants shipped, e.g. with `git log origin/main..main`.
- Read `git log` back to the last release tag as a sanity check that there's
  actually something worth releasing.

## 2. Bump the version and push to `main`

- Read `VERSION` for the current version. Work out the new one — ask the
  user (patch/minor/major) if it isn't obvious from what's being released;
  there's no changelog to infer it from.
- Write the new version to `VERSION` and commit as `Bump version to X.Y.Z`,
  matching the wording already in this repo's history.
- Confirm, then `git push origin main`.

## 3. Move the release branch onto the new commit

The release branch is `release/vX.x`, taking `X` from the new version's major
number and leaving the `x` literal.

Do this **without checking the branch out**. Checking it out and running
`git merge main` went wrong once: the merge reported "Already up-to-date",
the branch never moved, and the tag ended up on `main` — the exact thing this
skill exists to prevent. Run the commands one at a time and read the full
output of each; don't chain them or pipe them through anything that hides it.

- **New major line** (branch doesn't exist yet): `git branch release/vX.x main`.
- **Existing line**: confirm the move is a fast-forward, then make it.

  ```bash
  git merge-base --is-ancestor release/vX.x main   # exit 0 means fast-forward
  git fetch . main:release/vX.x                    # moves the branch, worktree untouched
  ```

  A non-zero exit from the first command means `release/vX.x` has commits
  `main` doesn't — it diverged some other way. Stop and ask rather than
  forcing it.
- Check the branch actually moved: `git log -1 --oneline release/vX.x` should
  show the version-bump commit.
- Confirm, then push the branch.

## 4. Tag on the release branch

- `git tag -a vX.Y.Z release/vX.x -m "session-colour vX.Y.Z"` — annotated,
  matching the message convention of the existing tags, and naming the branch
  explicitly so the tag can't attach to whatever happens to be checked out.
- Verify with `git branch --contains vX.Y.Z`; it must list `release/vX.x`.
- Confirm, then `git push origin vX.Y.Z`. This is the step that fires the
  release workflow.

## 5. Wrap up

- Point the user at the Actions run (`https://github.com/<owner>/<repo>/actions`)
  and, once it finishes, the published release
  (`https://github.com/<owner>/<repo>/releases/tag/vX.Y.Z`). Derive
  `<owner>/<repo>` from `git remote get-url origin`.
