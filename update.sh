#!/usr/bin/env bash
# Update session-colour to the newest tagged release, then re-run the installer.
#
# Releases are tags vX.Y.Z cut on release/vX.Y branches. This checks out the
# release branch rather than the tag where it can, so you end up on a branch you
# can pull again rather than at a detached HEAD.
#
#   ./update.sh            check, ask, upgrade, reinstall
#   ./update.sh --check    report what is available and stop
#   ./update.sh --yes      no prompts (the reinstall inherits this)
#
# Any other options are passed straight through to install.sh, so
# `./update.sh --link` upgrades a symlinked development install.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="session-colour"
CURRENT="$(head -1 "$REPO/VERSION" | tr -d '[:space:]')"

CHECK_ONLY=0; ASSUME_YES=0; PASSTHROUGH=()
for a in "$@"; do
  case "$a" in
    --check)   CHECK_ONLY=1 ;;
    --yes|-y)  ASSUME_YES=1; PASSTHROUGH+=("$a") ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         PASSTHROUGH+=("$a") ;;
  esac
done

say()  { printf '%s\n' "$*"; }
die()  { printf '%s\n' "$*" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply
  read -r -p "$1 [Y/n] " reply </dev/tty || return 1
  case "$reply" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

cd "$REPO"
[ -d .git ] || die "$REPO is not a git repository."
git remote get-url origin >/dev/null 2>&1 \
  || die "No 'origin' remote. Add one first:  git remote add origin <url>"

say "== $PROJECT — installed v$CURRENT"
say "   fetching from $(git remote get-url origin)"

git fetch --quiet --tags --prune origin \
  || die "Could not reach the remote. Check the network or your credentials."

latest=$(git tag -l 'v*' | sed 's/^v//' | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1)
[ -n "$latest" ] || die "No release tags (v*) found on the remote."

# sort -V puts 1.10.0 above 1.9.0, which a string comparison gets backwards.
if [ "$latest" = "$CURRENT" ] \
   || [ "$(printf '%s\n%s\n' "$CURRENT" "$latest" | sort -V | tail -1)" = "$CURRENT" ]; then
  say "   already on the newest release (latest tag: v$latest)"
  exit 0
fi

branch="release/v$(printf '%s' "$latest" | cut -d. -f1-2)"
say
say "   v$latest is available."
if git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
  target_desc="branch $branch (at tag v$latest)"
else
  target_desc="tag v$latest (no $branch on the remote — this will be a detached HEAD)"
fi
say "   would move to: $target_desc"
say

if [ "$CHECK_ONLY" -eq 1 ]; then
  say "   --check given; stopping here. Run without it to upgrade."
  exit 0
fi

# Refuse to move a dirty tree. Losing local edits to these scripts is exactly
# the kind of thing that is invisible until the next time something breaks.
if [ -n "$(git status --porcelain)" ]; then
  say "Working tree has uncommitted changes:"
  git status --short | sed 's/^/    /'
  say
  die "Commit, stash or discard them first — refusing to overwrite local edits."
fi

confirm "   Update now?" || { say "   Left alone."; exit 0; }

if git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
  git checkout --quiet -B "${branch#release/}" "refs/tags/v$latest" 2>/dev/null \
    || git checkout --quiet "refs/tags/v$latest"
  git branch --quiet --set-upstream-to "origin/$branch" "${branch#release/}" 2>/dev/null || true
else
  git checkout --quiet "refs/tags/v$latest"
fi

say "   now at $(git describe --tags --always)"
say
say "== Re-running the installer"
"$REPO/install.sh" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
