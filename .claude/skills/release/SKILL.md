---
name: release
description: Cut a new session-colour release — bump VERSION on main, merge main into the matching release/vX.Y branch, and tag there so the GitHub Actions release workflow publishes it. Use when the user asks to cut, ship, or publish a new release/version of this repo.
---

# Cutting a session-colour release

[`.github/workflows/release.yml`](../../../.github/workflows/release.yml)
turns any pushed `vX.Y.Z` tag into a GitHub Release. It does **not** check
which branch the tag came from — a tag push and a branch push are separate
events, so the workflow can't tell. That guarantee is enforced here instead,
by process: **a release tag only ever gets created on its `release/vX.Y`
branch, after `main` has been merged into it.** This skill is the only place
that should create release tags in this repo — follow it in order, and don't
tag straight off `main` or anywhere else.

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

## 3. Merge `main` into the release branch

- The release branch is `release/vX.Y`, from the new version's major.minor.
- **New minor line** (branch doesn't exist yet): `git branch release/vX.Y
  main`, then push it.
- **Existing line**: check out `release/vX.Y` (create it tracking
  `origin/release/vX.Y` if there's no local copy), `git merge main`
  (fast-forward is the expected case since nothing else commits to a release
  branch directly).
- A merge conflict means `release/vX.Y` diverged from `main` some other way —
  stop and ask rather than resolving it blindly.
- Confirm, then push the branch.

## 4. Tag on the release branch

- With `release/vX.Y` checked out at the commit that was just pushed:
  `git tag -a vX.Y.Z -m "session-colour vX.Y.Z"` — annotated, matching the
  message convention of the existing `v1.0.0` tag.
- Confirm, then `git push origin vX.Y.Z`. This is the step that fires the
  release workflow.

## 5. Wrap up

- Switch back to `main` — that's the branch this repo normally works from.
- Point the user at the Actions run (`https://github.com/<owner>/<repo>/actions`)
  and, once it finishes, the published release
  (`https://github.com/<owner>/<repo>/releases/tag/vX.Y.Z`). Derive
  `<owner>/<repo>` from `git remote get-url origin`.
