#!/usr/bin/env bash
# Installer for session-colour.
#
# Everything except the shell alias can be done without asking: files are copied
# into ~/.claude, and the settings.json keys are merged in with jq, replacing
# only this project's own entries.
#
# The alias is a manual step. It lives in a shell startup file this script
# usually cannot write — often one sourced from a read-only mount or a dotfiles
# repo — so the installer prints the exact line, waits while you add it, and
# then checks whether it took.
#
#   ./install.sh              copy files into place, prompt for the alias
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

# Prompts read from /dev/tty rather than stdin so they still work when the
# installer is piped. When there is no controlling terminal at all — CI, a
# hook, `sh install.sh < /dev/null` — there is nobody to answer, so every
# question declines rather than hanging or erroring.
tty_available() { { : < /dev/tty; } 2>/dev/null; }

# Ask, unless --yes. Default is yes; anything starting with n declines.
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  tty_available || return 1
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
# This is what colours the prompt bar, and it is a manual step for most people.
# Shell config is very often sourced from somewhere this script cannot write —
# a shared mount, a dotfiles repo, a company-managed file — so the installer
# tells you the line, waits, and then checks that it took, rather than assuming
# it can edit your rc.
#
# Detection asks an interactive shell what `claude` actually resolves to, so
# nothing here depends on knowing where your config lives. It sees the alias
# wherever it is defined — including files sourced two levels deep from the rc —
# which grepping a guessed list of ~/.* files does not. Getting that wrong is
# not harmless: an alias the installer cannot see is one it offers to add a
# second copy of, in a different file, that may then shadow the first.
#
# Aliases apply to interactive shells only, so scripts, cron and any tooling
# that calls `claude` directly are unaffected.

# The user's login shell, since that is what will read the alias. Falls back to
# bash, which is also what the wrapper is written for.
login_shell() {
  case "${SHELL:-}" in
    */zsh) printf 'zsh' ;;
    *)     printf 'bash' ;;
  esac
}

alias_active() {
  local sh out
  sh=$(login_shell)
  command -v "$sh" >/dev/null 2>&1 || return 1
  # -i makes it read the interactive rc chain. stdin from /dev/null and stderr
  # discarded because a non-tty interactive shell complains about job control.
  out=$("$sh" -ic 'alias claude' </dev/null 2>/dev/null) || return 1
  case "$out" in *claude-session*) return 0 ;; esac
  return 1
}

# Where it is defined, for reporting. Looks in the usual rc files and in
# anything they source with an absolute or $HOME-relative path.
alias_source_file() {
  local f p
  for f in $(rc_files); do
    [ -f "$f" ] || continue
    grep -lq "claude-session" "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
  done
  return 1
}

rc_files() {
  local f line p
  for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_aliases" \
           "$HOME/.profile" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv"; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
    # Anything sourced with `. path` or `source path`, wherever it appears on
    # the line — these are commonly wrapped in a one-line `if [ -f ... ]`.
    # Commented-out source lines are skipped — plenty of rc files carry a
    # disabled completion loader, and listing those as "files looked at" is
    # noise when reporting where the alias should go.
    { grep -v '^[[:space:]]*#' "$f" 2>/dev/null \
        | grep -oE '(^|[;[:space:]])(\.|source)[[:space:]]+[^;[:space:]"'"'"']+' \
        | awk '{print $NF}' \
        | while IFS= read -r p; do
            case "$p" in
              '~'/*)     p="$HOME/${p#\~/}" ;;
              '$HOME'/*) p="$HOME/${p#\$HOME/}" ;;
            esac
            [ -f "$p" ] && printf '%s\n' "$p"
          done
    } || true
  done
  return 0
}

# A candidate we could actually append to, if the user wants that instead.
writable_rc() {
  local f
  case "$(login_shell)" in
    zsh)  for f in "$HOME/.zshrc" "$HOME/.zprofile"; do
            { [ -f "$f" ] && [ -w "$f" ]; } && { printf '%s' "$f"; return 0; }
          done ;;
    *)    for f in "$HOME/.bash_aliases" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
            { [ -f "$f" ] && [ -w "$f" ]; } && { printf '%s' "$f"; return 0; }
          done ;;
  esac
  return 1
}

append_alias() {   # file
  { echo; echo "# session-colour: colour the prompt bar per folder"; echo "$ALIAS_LINE"; } >> "$1"
}

step "Prompt bar alias"
if [ "$WANT_ALIAS" -eq 0 ]; then
  say "  Skipped (--no-alias). The status line will still be coloured; the"
  say "  prompt bar itself will not."
elif alias_active; then
  ok "the 'claude' alias is active"
  if where=$(alias_source_file); then ok "defined in $where"; fi
else
  target=$(writable_rc || true)

  say
  say "  MANUAL STEP — the prompt bar colour needs a shell alias."
  say
  say "  Add this line to your shell startup file:"
  say
  say "      $ALIAS_LINE"
  say
  say "  Either form works — \$HOME or the full path — as long as it points at"
  say "  $BIN_DIR/claude-session."
  say

  if [ -n "$target" ]; then
    say "  A writable candidate is: $target"
  else
    say "  None of your shell startup files are writable by this script, so it"
    say "  has to be done by hand. Files it looked at:"
    rc_files | sort -u | sed 's/^/      /'
  fi
  say
  say "  Then open a NEW terminal — the current one has already read its config."
  say

  if [ "$ASSUME_YES" -eq 1 ] || ! tty_available; then
    # Unattended: append if we can, otherwise say so and carry on rather than
    # blocking a scripted install on a prompt nobody is there to answer.
    if [ -n "$target" ]; then
      append_alias "$target"
      ok "appended to $target"
    else
      warn "not added — no writable startup file, and nobody to ask."
      warn "Add the line above by hand; everything else is installed."
    fi
  else
    if [ -n "$target" ] && confirm "  Append it to $target for you?"; then
      append_alias "$target"
      if alias_active; then ok "added to $target, and confirmed active"
      else ok "added to $target"; warn "not visible yet — it will be in a new shell"; fi
    else
      # Wait for them to do it, then verify. This is the prompt-and-check the
      # step is here for: the installer cannot make the edit, but it can tell
      # you whether the edit worked.
      while true; do
        printf '  Add the line, then press Enter to re-check (or s to skip): '
        read -r reply </dev/tty || { say; break; }
        case "$reply" in
          s|S|skip|Skip)
            warn "skipped — the prompt bar will stay grey until the alias exists"
            break ;;
        esac
        if alias_active; then
          ok "found it — the alias is active"
          if where=$(alias_source_file); then ok "defined in $where"; fi
          break
        fi
        warn "still not seeing 'claude' resolve to claude-session."
        warn "Check you saved the file, and that your login shell ($(login_shell))"
        warn "actually reads it. 'type claude' in a new terminal should show it."
      done
    fi
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

# The alias is reported, not counted as a failure: the status line works
# without it, and it is the one thing the installer may legitimately not have
# been able to do.
alias_missing=0
if [ "$WANT_ALIAS" -eq 0 ]; then
  ok "alias skipped (--no-alias)"
elif alias_active; then
  ok "'claude' alias active"
else
  warn "'claude' alias NOT active — status line only, prompt bar stays grey"
  alias_missing=1
fi

say
if [ "$fail" -eq 0 ]; then
  say "Done. Open a NEW terminal in a folder no current session uses:"
  if [ "$alias_missing" -eq 1 ]; then
    say "  - the status line should be coloured"
    say "  - the prompt bar will NOT be, until you add this to your shell config:"
    say "        $ALIAS_LINE"
  else
    say "  - the prompt bar should come up already coloured"
    say "  - the status line under it should match"
  fi
  say
  say "Sessions already running predate the install and stay uncoloured until"
  say "restarted. If Claude Code is open, /hooks forces a settings reload."
else
  say "Finished with problems — see the warnings above."
  exit 1
fi
