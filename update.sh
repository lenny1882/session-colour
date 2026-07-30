#!/usr/bin/env bash
# Update session-colour to the newest GitHub Release, then re-run the installer.
#
# "Newest" means whatever the GitHub Releases API calls /releases/latest — a
# release left as a draft, or marked pre-release, is skipped no matter how its
# version number sorts. This downloads that release's session-colour.tar.gz
# asset and extracts it over this directory, so it works the same whether you
# installed from a downloaded tarball or a git clone — no git required.
#
#   ./update.sh            check, ask, upgrade, reinstall
#   ./update.sh --check    report what is available and stop
#   ./update.sh --yes      no prompts (the reinstall inherits this)
#
# Any other options are passed straight through to install.sh, so
# `./update.sh --link` upgrades a symlinked development install.
#
# Needs `curl` and `tar`; `jq` is used when present and otherwise a plain-text
# scrape of the API response takes over.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="session-colour"
GITHUB_SLUG="lenny1882/session-colour"
TARBALL_NAME="session-colour.tar.gz"

[ -f "$REPO/VERSION" ] || {
  printf '%s does not look like a %s install (no VERSION file).\n' "$REPO" "$PROJECT" >&2
  exit 1
}
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

say "== $PROJECT — installed v$CURRENT"
say "   asking github.com/$GITHUB_SLUG for the latest release"

response=$(curl -sSL -w '\n%{http_code}' -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$GITHUB_SLUG/releases/latest") \
  || die "Could not reach the GitHub Releases API. Check the network."
http_code=$(printf '%s' "$response" | tail -1)
release_json=$(printf '%s' "$response" | sed '$d')

case "$http_code" in
  200) ;;
  404) die "GitHub reports no releases yet for $GITHUB_SLUG." ;;
  *)   die "GitHub Releases API returned HTTP $http_code for $GITHUB_SLUG." ;;
esac

tag=$(json_field "$release_json" tag_name)
[ -n "$tag" ] || die "GitHub reports no releases yet for $GITHUB_SLUG."
latest="${tag#v}"
rel_url=$(json_field "$release_json" html_url)

# sort -V puts 1.10.0 above 1.9.0, which a string comparison gets backwards.
if [ "$latest" = "$CURRENT" ] \
   || [ "$(printf '%s\n%s\n' "$CURRENT" "$latest" | sort -V | tail -1)" = "$CURRENT" ]; then
  say "   already on the newest release (latest: v$latest)"
  exit 0
fi

say
say "   v$latest is available."
[ -n "$rel_url" ] && say "   release notes: $rel_url"
say

if [ "$CHECK_ONLY" -eq 1 ]; then
  say "   --check given; stopping here. Run without it to upgrade."
  exit 0
fi

confirm "   Update now?" || { say "   Left alone."; exit 0; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
asset_url="https://github.com/$GITHUB_SLUG/releases/download/$tag/$TARBALL_NAME"
say "   downloading $TARBALL_NAME (v$latest)"
curl -fsSL -o "$tmp/$TARBALL_NAME" "$asset_url" \
  || die "Could not download $asset_url"

say "   extracting into $REPO"
tar -xzf "$tmp/$TARBALL_NAME" -C "$REPO" --strip-components=1

say "   now at v$latest"
say
say "== Re-running the installer"
"$REPO/install.sh" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
