#!/usr/bin/env bash
# Remove session-colour from this machine.
#
# Takes out the four installed scripts, the settings.json keys, the colour
# registry and the update state. The shell alias is the one thing it will not
# edit for you — it lives in a file this project does not own — so it is
# reported with the exact line to delete.
#
#   ./uninstall.sh          ask before each destructive step
#   ./uninstall.sh --yes    no prompts
#   ./uninstall.sh --keep-settings   leave settings.json alone

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
HOOK_DIR="$HOME/.claude/hooks"
BIN_DIR="$HOME/.claude/bin"
LIB_DIR="$HOME/.local/share/session-colour"
REGISTRY="$HOME/.claude/session-colors"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/session-colour"

ASSUME_YES=0; KEEP_SETTINGS=0
for a in "$@"; do
  case "$a" in
    --yes|-y)         ASSUME_YES=1 ;;
    --keep-settings)  KEEP_SETTINGS=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply; read -r -p "$1 [Y/n] " reply </dev/tty || return 1
  case "$reply" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

printf '%s\n' "== Uninstalling session-colour"

step "Removing installed scripts"
for f in "$HOOK_DIR/statusline-project.sh" "$HOOK_DIR/session-identity.sh" \
         "$HOOK_DIR/session-identity-end.sh" "$BIN_DIR/claude-session" \
         "$LIB_DIR/update-check.sh"; do
  if [ -e "$f" ] || [ -L "$f" ]; then rm -f "$f"; ok "removed $f"; else ok "not present: $f"; fi
done
rmdir "$LIB_DIR" 2>/dev/null || true

step "settings.json"
if [ "$KEEP_SETTINGS" -eq 1 ]; then
  ok "left alone (--keep-settings)"
elif [ ! -f "$SETTINGS" ]; then
  ok "no $SETTINGS"
elif ! jq empty "$SETTINGS" 2>/dev/null; then
  warn "$SETTINGS is not valid JSON — leaving it untouched."
  warn "Remove the statusLine key and the session-identity hooks by hand."
elif confirm "  Remove the statusLine key and our SessionStart/SessionEnd hooks?"; then
  cp "$SETTINGS" "$SETTINGS.bak-uninstall"
  tmp=$(mktemp)
  jq '
    def ours: (.command // "") | (contains("session-identity") or contains("statusline-project"));
    def strip_ours: map(.hooks |= map(select(ours | not))) | map(select((.hooks | length) > 0));
    (if (.statusLine.command // "") | contains("statusline-project.sh")
       then del(.statusLine) else . end)
    | (if .hooks.SessionStart then .hooks.SessionStart |= strip_ours else . end)
    | (if .hooks.SessionEnd   then .hooks.SessionEnd   |= strip_ours else . end)
    # Drop hook arrays and the hooks object itself once they are empty, rather
    # than leaving "SessionEnd": [] behind.
    | (if (.hooks.SessionStart // null) == [] then del(.hooks.SessionStart) else . end)
    | (if (.hooks.SessionEnd   // null) == [] then del(.hooks.SessionEnd)   else . end)
    | (if (.hooks // null) == {} then del(.hooks) else . end)
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  ok "cleaned; previous file saved as $SETTINGS.bak-uninstall"
else
  ok "left alone"
fi

step "Colour registry and update state"
if [ -d "$REGISTRY" ]; then
  if confirm "  Delete $REGISTRY? (live sessions lose their colour immediately)"; then
    rm -rf "$REGISTRY"; ok "removed"
  else ok "left alone"; fi
else
  ok "no registry at $REGISTRY"
fi
[ -d "$STATE" ] && { rm -rf "$STATE"; ok "removed $STATE"; } || ok "no update state"

step "The shell alias — remove this yourself"
found=0
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
  if [ -f "$rc" ] && grep -q "claude/bin/claude-session" "$rc" 2>/dev/null; then
    found=1
    warn "$rc line $(grep -n 'claude/bin/claude-session' "$rc" | head -1 | cut -d: -f1):"
    grep -n "claude/bin/claude-session" "$rc" | sed 's/^/        /'
  fi
done
if [ "$found" -eq 1 ]; then
  printf '%s\n' "  Delete those lines (and the '# session-colour' comment above them),"
  printf '%s\n' "  then open a new terminal. Until you do, 'claude' will point at a"
  printf '%s\n' "  script that no longer exists."
else
  ok "no alias found in your shell rc files"
fi

printf '\n%s\n' "Done. Existing sessions keep their current colour until they exit."
