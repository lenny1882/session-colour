#!/usr/bin/env bash
# Installer for session-colour.
#
# Everything except the shell alias can be done without asking: files are copied
# into ~/.claude, and the settings.json keys are merged in with jq, replacing
# only this project's own entries. The alias is the one step that has to touch a
# file this script does not own, so it asks first and verifies afterwards.
#
#   ./install.sh              copy files into place, ask before editing the rc
#   ./install.sh --link       symlink instead of copying, for working on the repo
#   ./install.sh --yes        assume yes to every prompt (unattended)
#   ./install.sh --no-alias   skip the alias entirely; status line only
#
# Re-running is safe and is how you upgrade: every step replaces what it wrote
# last time and leaves everything else alone.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(head -1 "$REPO/VERSION" | tr -d '[:space:]')"
SETTINGS="$HOME/.claude/settings.json"
HOOK_DIR="$HOME/.claude/hooks"
BIN_DIR="$HOME/.claude/bin"
LIB_DIR="$HOME/.local/share/session-colour"
ALIAS_LINE="alias claude='\$HOME/.claude/bin/claude-session'"

LINK=0; ASSUME_YES=0; WANT_ALIAS=1
for a in "$@"; do
  case "$a" in
    --link)     LINK=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --no-alias) WANT_ALIAS=0 ;;
    -h|--help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

# Ask, unless --yes. Default is yes; anything starting with n declines.
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply
  read -r -p "$1 [Y/n] " reply </dev/tty || return 1
  case "$reply" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

install_file() {   # src, dest
  mkdir -p "$(dirname "$2")"
  rm -f "$2"
  if [ "$LINK" -eq 1 ]; then ln -s "$1" "$2"; else cp "$1" "$2"; fi
  chmod +x "$2" 2>/dev/null || true
}

say "== session-colour v$VERSION"
say "   repo: $REPO"
[ "$LINK" -eq 1 ] && say "   mode: symlink (edits in the repo take effect immediately)"

# --- 1. what this needs ------------------------------------------------------
step "Checking prerequisites"
missing=()
for c in jq git; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if [ "${#missing[@]}" -gt 0 ]; then
  say "  Missing: ${missing[*]}"
  say "  Install them and re-run, e.g.: sudo apt install ${missing[*]}"
  exit 1
fi
ok "jq and git present"

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  say "  bash 4+ required (associative arrays); this is ${BASH_VERSION}."
  exit 1
fi
ok "bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"

# The status line draws powerline separators and Nerd Font private-use glyphs.
# Without a patched font they show as tofu — the layout still works, so this is
# a warning rather than a failure.
if command -v fc-list >/dev/null 2>&1 && fc-list 2>/dev/null | grep -qi 'nerd font'; then
  ok "a Nerd Font is installed"
else
  warn "no Nerd Font found. The status line's separators and clock/calendar"
  warn "glyphs will render as boxes. Install one (e.g. DejaVuSansM Nerd Font)"
  warn "and set it as your terminal font, or as its fallback."
fi

case "${COLORTERM:-}" in
  truecolor|24bit) ok "terminal reports 24-bit colour" ;;
  *) warn "COLORTERM is not truecolor; the 24-bit colours may be approximated" ;;
esac

# --- 2. files ----------------------------------------------------------------
step "Installing files"
install_file "$REPO/hooks/statusline-project.sh"  "$HOOK_DIR/statusline-project.sh"
install_file "$REPO/hooks/session-identity.sh"    "$HOOK_DIR/session-identity.sh"
install_file "$REPO/hooks/session-identity-end.sh" "$HOOK_DIR/session-identity-end.sh"
install_file "$REPO/bin/claude-session"           "$BIN_DIR/claude-session"
install_file "$REPO/lib/update-check.sh"          "$LIB_DIR/update-check.sh"
ok "$HOOK_DIR/{statusline-project,session-identity,session-identity-end}.sh"
ok "$BIN_DIR/claude-session"
ok "$LIB_DIR/update-check.sh"

# --- 3. settings.json --------------------------------------------------------
# Merged with jq rather than rewritten: this file holds your permissions,
# plugins and any other hooks, none of which are ours to touch. Each hook array
# has our own entries stripped by command match, then re-added, so re-running
# never stacks duplicates.
step "Merging into $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

if ! jq empty "$SETTINGS" 2>/dev/null; then
  say "  $SETTINGS is not valid JSON. Fix it and re-run — refusing to overwrite."
  exit 1
fi

existing_sl=$(jq -r '.statusLine.command // ""' "$SETTINGS")
if [ -n "$existing_sl" ] && [ "$existing_sl" != "~/.claude/hooks/statusline-project.sh" ]; then
  warn "a different status line is configured:"
  warn "  $existing_sl"
  if confirm "  Replace it? (the old value is saved to $SETTINGS.pre-session-colour)"; then
    cp "$SETTINGS" "$SETTINGS.pre-session-colour"
  else
    say "  Leaving the status line alone. The hooks will still be installed,"
    say "  but nothing will show the folder colour. Re-run to change your mind."
    WANT_SL=0
  fi
fi

tmp=$(mktemp)
jq --argjson want_sl "${WANT_SL:-1}" '
  # Drop any hook entry whose command names one of our scripts, at any path.
  def ours: (.command // "") | (contains("session-identity") or contains("statusline-project"));
  def strip_ours: map(.hooks |= map(select(ours | not))) | map(select((.hooks | length) > 0));

  (if $want_sl == 1
     then .statusLine = {type: "command", command: "~/.claude/hooks/statusline-project.sh"}
     else . end)
  # startup, resume and clear all re-claim the folder colour. resume and clear
  # matter because SessionEnd fires for both, releasing the claim first.
  | .hooks.SessionStart = (((.hooks.SessionStart // []) | strip_ours) + [
      {matcher: "startup", hooks: [{type: "command", command: "~/.claude/hooks/session-identity.sh"}]},
      {matcher: "resume",  hooks: [{type: "command", command: "~/.claude/hooks/session-identity.sh"}]},
      {matcher: "clear",   hooks: [{type: "command", command: "~/.claude/hooks/session-identity.sh"}]}
    ])
  | .hooks.SessionEnd = (((.hooks.SessionEnd // []) | strip_ours) + [
      {hooks: [{type: "command", command: "~/.claude/hooks/session-identity-end.sh"}]}
    ])
' "$SETTINGS" > "$tmp"

if diff -q "$tmp" "$SETTINGS" >/dev/null 2>&1; then
  rm -f "$tmp"; ok "already up to date"
else
  mv "$tmp" "$SETTINGS"; ok "statusLine, SessionStart (startup/resume/clear), SessionEnd"
fi

# --- 4. the alias ------------------------------------------------------------
# This is what colours the prompt bar, and it is the only part that edits a file
# outside ~/.claude. Aliases apply to interactive shells only, so scripts, cron
# and tooling that call `claude` directly are unaffected.
step "Prompt bar alias"
if [ "$WANT_ALIAS" -eq 0 ]; then
  say "  Skipped (--no-alias). The status line will still be coloured; the"
  say "  prompt bar itself will not."
else
  rc="$HOME/.bashrc"
  [ -n "${ZSH_VERSION:-}" ] && rc="$HOME/.zshrc"
  case "${SHELL:-}" in */zsh) rc="$HOME/.zshrc" ;; esac

  if [ -f "$rc" ] && grep -q "claude/bin/claude-session" "$rc"; then
    ok "already present in $rc"
  elif [ ! -w "$rc" ] && [ -e "$rc" ]; then
    # A read-only rc is a real setup here — this machine keeps shell config on
    # a read-only mount — so say what to add rather than failing.
    warn "$rc is not writable. Add this line yourself:"
    say  "    $ALIAS_LINE"
  elif confirm "  Append the alias to $rc?"; then
    { echo; echo "# session-colour: colour the prompt bar per folder"; echo "$ALIAS_LINE"; } >> "$rc"
    if grep -q "claude/bin/claude-session" "$rc"; then
      ok "added to $rc"
    else
      warn "the append did not take. Add it yourself:"
      say  "    $ALIAS_LINE"
    fi
  else
    say "  Not added. To colour the prompt bar later, put this in $rc:"
    say  "    $ALIAS_LINE"
  fi
fi

# --- 5. version state --------------------------------------------------------
step "Recording the installed version"
"$LIB_DIR/update-check.sh" record-install "$VERSION" "$REPO"
ok "v$VERSION, repo at $REPO"

# --- 6. verify ---------------------------------------------------------------
step "Verifying"
fail=0
for f in "$HOOK_DIR/statusline-project.sh" "$HOOK_DIR/session-identity.sh" \
         "$HOOK_DIR/session-identity-end.sh" "$BIN_DIR/claude-session" \
         "$LIB_DIR/update-check.sh"; do
  if [ -x "$f" ]; then ok "$(basename "$f")"; else warn "MISSING: $f"; fail=1; fi
done
jq -e '.hooks.SessionStart | map(.hooks[].command) | any(contains("session-identity.sh"))' \
  "$SETTINGS" >/dev/null && ok "SessionStart hook registered" || { warn "SessionStart hook NOT registered"; fail=1; }
jq -e '.hooks.SessionEnd | map(.hooks[].command) | any(contains("session-identity-end.sh"))' \
  "$SETTINGS" >/dev/null && ok "SessionEnd hook registered" || { warn "SessionEnd hook NOT registered"; fail=1; }

say
if [ "$fail" -eq 0 ]; then
  say "Done. Open a NEW terminal in a folder no current session uses:"
  say "  - the prompt bar should come up already coloured (needs the alias)"
  say "  - the status line under it should match"
  say
  say "Sessions already running predate the install and stay uncoloured until"
  say "restarted. If Claude Code is open, /hooks forces a settings reload."
else
  say "Finished with problems — see the warnings above."
  exit 1
fi
