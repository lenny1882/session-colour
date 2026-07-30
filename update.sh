#!/usr/bin/env bash
# Update session-colour to the newest GitHub Release, then re-run the installer.
#
# "Newest" means whatever the GitHub Releases API calls /releases/latest — a
# release left as a draft, or marked pre-release, is skipped no matter how its
# version number sorts. Releases are tags vX.Y.Z cut on release/vX.Y branches.
# This checks out the release branch rather than the tag where it can, so you
# end up on a branch you can pull again rather than at a detached HEAD.
#
#   ./update.sh            check, ask, upgrade, reinstall
#   ./update.sh --check    report what is available and stop
#   ./update.sh --yes      no prompts (the reinstall inherits this)
#
# Any other options are passed straight through to install.sh, so
# `./update.sh --link` upgrades a symlinked development install.
#
# Needs `curl` and a github.com origin remote; `jq` is used when present and
# otherwise a plain-text scrape of the API response takes over.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="session-colour"
CURRENT="$(head -1 "$REPO/VERSION" | tr -d '[:space:]')"

CHECK_ONLY=0; ASSUME_YES=0; PASSTHROUGH=()
for a in "$@"; do
  case "$a" in
    --check)   CHECK_ONLY=1 ;;
    --yes|-y)  ASSUME_YES=1; PASSTHROUGH+=("$a") ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# "owner/repo" from a GitHub origin URL, whichever form it's in.
github_slug() {
  local url="$1"
  case "$url" in
    git@github.com:*)       url="${url#git@github.com:}" ;;
    ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
    https://github.com/*)   url="${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
  url="${url%.git}"
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

# Pull one string field out of a JSON blob: $1 is the JSON, $2 the field name.
json_field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // empty'
  else
    printf '%s' "$1" \
      | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
      | sed -E 's/.*:[[:space:]]*"(.*)"$/\1/'
  fi
}

cd "$REPO"
[ -d .git ] || die "$REPO is not a git repository."
origin_url=$(git remote get-url origin 2>/dev/null) \
  || die "No 'origin' remote. Add one first:  git remote add origin <url>"
slug=$(github_slug "$origin_url") \
  || die "origin ($origin_url) isn't a github.com URL — can't query the Releases API."

say "== $PROJECT — installed v$CURRENT"
say "   asking github.com/$slug for the latest release"

response=$(curl -sSL -w '\n%{http_code}' -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$slug/releases/latest") \
  || die "Could not reach the GitHub Releases API. Check the network."
http_code=$(printf '%s' "$response" | tail -1)
release_json=$(printf '%s' "$response" | sed '$d')

case "$http_code" in
  200) ;;
  404) die "GitHub reports no releases yet for $slug. (Only tags exist? Push one through the release workflow, or run 'gh release create'.)" ;;
  *)   die "GitHub Releases API returned HTTP $http_code for $slug." ;;
esac

tag=$(json_field "$release_json" tag_name)
[ -n "$tag" ] || die "GitHub reports no releases yet for $slug."
latest="${tag#v}"
rel_url=$(json_field "$release_json" html_url)

# sort -V puts 1.10.0 above 1.9.0, which a string comparison gets backwards.
if [ "$latest" = "$CURRENT" ] \
   || [ "$(printf '%s\n%s\n' "$CURRENT" "$latest" | sort -V | tail -1)" = "$CURRENT" ]; then
  say "   already on the newest release (latest: v$latest)"
  exit 0
fi

say "   fetching from $origin_url"
git fetch --quiet --tags --prune origin \
  || die "Could not reach the remote. Check the network or your credentials."

branch="release/v$(printf '%s' "$latest" | cut -d. -f1-2)"
say
say "   v$latest is available."
if git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
  target_desc="branch $branch (at tag v$latest)"
else
  target_desc="tag v$latest (no $branch on the remote — this will be a detached HEAD)"
fi
say "   would move to: $target_desc"
[ -n "$rel_url" ] && say "   release notes: $rel_url"
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
  # Local branch keeps the full release/vX.Y name, tracking its remote
  # counterpart, so a later `git pull` here does the obvious thing.
  git checkout --quiet -B "$branch" "refs/tags/v$latest"
  git branch --set-upstream-to "origin/$branch" "$branch" >/dev/null 2>&1 || true
else
  git checkout --quiet "refs/tags/v$latest"
fi

say "   now at $(git describe --tags --always)"
say
say "== Re-running the installer"
"$REPO/install.sh" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
