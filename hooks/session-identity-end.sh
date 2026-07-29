#!/usr/bin/env bash
# SessionEnd hook: drop this session from its folder's colour entry.
#
# The colour is released only when this was the folder's last live session;
# otherwise the remaining sessions keep it.

set -uo pipefail

REG="${HOME}/.claude/session-colors"
LOCK="$REG/.lock"
[ -d "$REG" ] || exit 0

pid="${CLAUDE_PID:-$PPID}"

payload=$(cat)
if command -v jq >/dev/null 2>&1; then
  sid=$(printf '%s' "$payload" | jq -r '.session_id // empty')
else
  sid=""
fi
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"

acquire_lock() {
  local i=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 50 ]; then
      rm -rf "$LOCK" 2>/dev/null
      continue
    fi
    sleep 0.1
  done
  trap 'rm -rf "$LOCK" 2>/dev/null' EXIT
}
acquire_lock

for f in "$REG"/*; do
  [ -e "$f" ] || continue
  fdir=""
  keep=()
  first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      case "$line" in dir=*) fdir=${line#dir=} ;; esac
      first=0
      continue
    fi
    p=${line%% *}
    rest=${line#* }
    osid=${rest%% *}
    [ -n "$p" ] || continue
    # Drop our own line, and any whose process is gone. Session id is
    # authoritative — matching on pid as well would let one session evict
    # another that happened to share a pid value.
    if [ -n "$sid" ]; then
      [ "$osid" = "$sid" ] && continue
    else
      [ "$p" = "$pid" ] && continue
    fi
    kill -0 "$p" 2>/dev/null && keep+=("$line")
  done < "$f"

  if [ "${#keep[@]}" -eq 0 ]; then
    rm -f "$f"
  else
    { printf 'dir=%s\n' "$fdir"; printf '%s\n' "${keep[@]}"; } > "$f"
  fi
done

exit 0
