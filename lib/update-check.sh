#!/usr/bin/env bash
# Daily release check for session-colour.
#
# Asks the git remote what release tags exist, compares the highest against the
# version recorded at install time, and writes the answer to a state file.
# It never fetches, never touches the working tree, and never installs
# anything — upgrading is always an explicit `./update.sh`.
#
# Releases are tags of the form vX.Y.Z, cut on release/vX.Y branches. Only tags
# are consulted for the version number; the matching release branch is recorded
# alongside it so update.sh knows what to check out.
#
# The check runs at most once per calendar day. Callers should run it in the
# background: a remote that is unreachable, slow, or asking for credentials
# must never hold up a session. `git` is invoked under `timeout` with prompting
# disabled for exactly that reason, and the day stamp is written even when the
# check fails, so an offline machine tries once a day rather than every session.
#
# Everything a caller displays comes from the *previous* run's state file. That
# is deliberate: reading a file is instant, whereas waiting on the network is
# not, so the notice you see is at most a day stale and costs nothing to show.
#
#   check [--force]   run today's check if it has not run; silent; ~0.5s
#   badge             "<glyph> vX.Y.Z" if an update is waiting, else nothing
#   notice            two-line plain-text notice, else nothing
#   hook-json         {"systemMessage": "..."} for a hook to emit, else nothing
#   status            installed / available / last checked
#   record-install <version> <repo-dir>    called by install.sh
#   clear             forget what the last check found

set -uo pipefail

PROJECT="session-colour"
DISPLAY_NAME="session-colour"

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/$PROJECT"
STAMP="$STATE/last-check"
AVAIL="$STATE/available"
BRANCH_F="$STATE/available-branch"
INSTALLED="$STATE/installed"
REPO_F="$STATE/repo-dir"

read_file() { cat "$1" 2>/dev/null | head -1 | tr -d '[:space:]'; }

# True when $2 is a strictly higher version than $1. sort -V orders 1.9.0
# below 1.10.0, which a string comparison would get backwards.
newer_than() {
  [ -n "$2" ] || return 1
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]
}

update_pending() {
  local have want
  have=$(read_file "$INSTALLED"); want=$(read_file "$AVAIL")
  [ -n "$have" ] || return 1
  newer_than "$have" "$want"
}

# --- the check itself --------------------------------------------------------

do_check() {
  local repo latest branch
  mkdir -p "$STATE"

  repo=$(read_file "$REPO_F")
  # No recorded repo, or it has been moved or deleted: nothing to ask.
  [ -n "$repo" ] && [ -d "$repo/.git" ] || return 0

  # Stamp first. A remote that hangs or refuses should cost one attempt per
  # day, not one per session start.
  date +%F > "$STAMP"

  git -C "$repo" remote get-url origin >/dev/null 2>&1 || { : > "$AVAIL"; return 0; }

  latest=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
    timeout 8 git -C "$repo" ls-remote --tags --refs origin 'v*' 2>/dev/null \
    | sed 's#.*refs/tags/v##' \
    | grep -E '^[0-9]+(\.[0-9]+)*$' \
    | sort -V | tail -1)

  if [ -z "$latest" ]; then
    : > "$AVAIL"; : > "$BRANCH_F"
    return 0
  fi

  printf '%s\n' "$latest" > "$AVAIL"
  # The release branch for vX.Y.Z is release/vX.Y — recorded so update.sh can
  # offer it directly instead of guessing.
  branch="release/v$(printf '%s' "$latest" | cut -d. -f1-2)"
  printf '%s\n' "$branch" > "$BRANCH_F"
}

checked_today() {
  [ "$(read_file "$STAMP")" = "$(date +%F)" ]
}

# --- subcommands -------------------------------------------------------------

case "${1:-status}" in
  check)
    if [ "${2:-}" != "--force" ] && checked_today; then exit 0; fi
    do_check
    ;;

  badge)
    update_pending && printf '⬆ v%s' "$(read_file "$AVAIL")"
    ;;

  notice)
    if update_pending; then
      printf '%s: v%s is available (installed: v%s)\n' \
        "$PROJECT" "$(read_file "$AVAIL")" "$(read_file "$INSTALLED")"
      printf '  update with: cd %s && ./update.sh\n' "$(read_file "$REPO_F")"
    fi
    ;;

  hook-json)
    if update_pending; then
      msg=$(printf '%s v%s is available (you have v%s). Update: cd %s && ./update.sh' \
        "$DISPLAY_NAME" "$(read_file "$AVAIL")" "$(read_file "$INSTALLED")" "$(read_file "$REPO_F")")
      if command -v jq >/dev/null 2>&1; then
        jq -n --arg m "$msg" '{systemMessage: $m}'
      else
        # Only the message is interpolated and it is built from version strings
        # and a path, so escaping quotes and backslashes covers it.
        printf '{"systemMessage": "%s"}\n' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      fi
    fi
    ;;

  status)
    printf '%s\n' "$DISPLAY_NAME"
    printf '  installed:    %s\n' "$(read_file "$INSTALLED" || true)"
    printf '  available:    %s\n' "$(read_file "$AVAIL" | grep . || echo '(none found)')"
    printf '  release br:   %s\n' "$(read_file "$BRANCH_F" | grep . || echo '-')"
    printf '  last checked: %s\n' "$(read_file "$STAMP" | grep . || echo 'never')"
    printf '  repo:         %s\n' "$(read_file "$REPO_F" | grep . || echo '(not recorded)')"
    update_pending && printf '  -> update available, run ./update.sh in the repo\n'
    ;;

  record-install)
    mkdir -p "$STATE"
    printf '%s\n' "${2:?version required}"  > "$INSTALLED"
    printf '%s\n' "${3:?repo dir required}" > "$REPO_F"
    ;;

  clear)
    rm -f "$STAMP" "$AVAIL" "$BRANCH_F"
    ;;

  *)
    printf 'usage: %s {check [--force]|badge|notice|hook-json|status|clear}\n' \
      "$(basename "$0")" >&2
    exit 1
    ;;
esac
exit 0
