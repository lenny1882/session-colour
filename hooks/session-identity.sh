#!/usr/bin/env bash
# SessionStart hook: claim a prompt-bar colour per FOLDER.
#
# The first session in a folder claims an unused colour; every additional
# session in that same folder joins it. The colour is released only when the
# last session in the folder exits, so folders — not sessions — are what the
# colours identify.
#
# This hook is silent: it registers only. See the note at the bottom for why
# it cannot set the prompt bar colour itself.
#
# When started through ~/.claude/bin/claude-session, the wrapper has already
# picked the colour (it has to — the colour must be known before launch, and
# this hook runs too late) and passes it in CLAUDE_SESSION_COLOUR, along with
# a placeholder registry line "<pid> pending". This hook then honours that
# choice and fills in the real session id. Started without the wrapper, it
# allocates as it always did.
#
# Registered for sources `startup`, `resume` and `clear`. The latter two exist
# because SessionEnd carries no matcher and so fires with reason `resume` and
# `clear` as well, RELEASING the folder's claim. Without a matching re-claim a
# resumed session runs with no registry entry at all: the prompt bar restores
# its own colour from the transcript while the status line, finding nothing for
# the folder, falls back to its unregistered grey-green. On those two sources
# the wrapper has not run (it skips --resume, and /clear never leaves the
# process), so the colour has to be recovered here instead — see the ladder
# below.
#
# Deliberately does NOT set `sessionTitle`: a custom title permanently
# shadows the auto-generated topic title in /resume (custom ?? ai).
#
# Registry: ~/.claude/session-colors/<name>
#     line 1: dir=<folder path>
#     line n: <pid> <session_id>     (one per live session in that folder)
#
# All read-modify-write happens under a mkdir lock so concurrent starts in the
# same folder converge on one colour instead of racing to claim two.

set -uo pipefail

REG="${HOME}/.claude/session-colors"
LOCK="$REG/.lock"
mkdir -p "$REG"

PALETTE=(red blue green yellow purple orange pink cyan)

payload=$(cat)

if command -v jq >/dev/null 2>&1; then
  read -r cwd sid source transcript <<<"$(printf '%s' "$payload" | jq -r '
    [ (.cwd // "-"), (.session_id // "-"), (.source // "-"), (.transcript_path // "-") ]
    | @tsv')"
else
  cwd="-"; sid="-"; source="-"; transcript="-"
fi
for v in cwd sid source transcript; do
  [ "${!v}" = "-" ] && printf -v "$v" '%s' ""
done
[ -n "$cwd" ] || cwd="$PWD"
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-unknown}"

# transcript_path comes from the builder shared by every hook input, so it is
# always present in practice. Derived as a fallback anyway, since the colour
# ladder's resume rung is the only thing that reads it: Claude Code keys the
# projects directory on the cwd with every non-alphanumeric replaced by a dash.
if [ -z "$transcript" ] && [ "$sid" != "unknown" ]; then
  transcript="${HOME}/.claude/projects/$(printf '%s' "$cwd" | tr -c 'a-zA-Z0-9\n' '-')/${sid}.jsonl"
fi

pid="${CLAUDE_PID:-$PPID}"

# --- lock --------------------------------------------------------------------
acquire_lock() {
  local i=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 50 ]; then      # ~5s: assume the holder died mid-write
      rm -rf "$LOCK" 2>/dev/null
      continue
    fi
    sleep 0.1
  done
  trap 'rm -rf "$LOCK" 2>/dev/null' EXIT
}
acquire_lock

# --- drop dead sessions; release folders that have none left -----------------
# Sets `found` to the colour already held by $cwd, if any, and `owner` to the
# folder behind every colour that survived the sweep. The ladder below needs
# the second of those: a colour is reusable only if it is unclaimed or already
# this folder's, and "unclaimed" has to mean *after* this sweep.
found=""
declare -A owner=()
for f in "$REG"/*; do
  [ -e "$f" ] || continue
  fdir=""
  live=()
  first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      case "$line" in dir=*) fdir=${line#dir=} ;; esac
      first=0
      continue
    fi
    p=${line%% *}
    [ -n "$p" ] || continue
    kill -0 "$p" 2>/dev/null && live+=("$line")
  done < "$f"

  if [ "${#live[@]}" -eq 0 ]; then
    rm -f "$f"                    # folder has no live sessions: release colour
    continue
  fi

  { printf 'dir=%s\n' "$fdir"; printf '%s\n' "${live[@]}"; } > "$f"
  owner[$(basename "$f")]=$fdir
  [ "$fdir" = "$cwd" ] && found=$(basename "$f")
done

# A colour may be taken only if nobody holds it or this folder already does.
reusable() { [ ! -e "$REG/$1" ] || [ "${owner[$1]:-}" = "$cwd" ]; }
in_palette() {
  local n
  for n in "${PALETTE[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

# --- join this folder's colour, or claim a new one ---------------------------
# Four rungs, most authoritative first.
chosen=""

# 1. The wrapper's choice. It claimed under this same lock moments ago, so on a
#    startup it is simply right. It is also what covers /clear, where the
#    variable is still in the process environment — but by then the sweep above
#    may have handed the colour to another folder, so it is checked, not
#    trusted.
#
#    Skipped on resume. The variable survives in the environment there too, but
#    it describes the colour the process was LAUNCHED with, and an in-process
#    /resume has just replaced the prompt bar with the incoming session's own
#    restored colour. Honouring it would re-claim the colour of the session
#    that was just left.
if [ "$source" != "resume" ] && [ -n "${CLAUDE_SESSION_COLOUR:-}" ] \
   && reusable "$CLAUDE_SESSION_COLOUR"; then
  chosen="$CLAUDE_SESSION_COLOUR"
fi

# 2. The colour this folder already holds. Folder identity is the whole point,
#    so a live claim outranks anything this session would prefer for itself.
[ -n "$chosen" ] || chosen="$found"

# 3. The colour this session is about to draw its own prompt bar in. On resume
#    Claude Code restores agentColor from the transcript, and nothing here can
#    change it — so re-claiming that same colour is what keeps the status line
#    and the prompt bar in agreement, rather than agreeing by luck. The records
#    are line-anchored and rewritten on every session-state save, so the last
#    one is the live value; anchoring also avoids matching the same string
#    quoted inside a tool result.
if [ -z "$chosen" ] && [ -n "$transcript" ] && [ -r "$transcript" ]; then
  restored=$(grep -a '^{"type":"agent-color"' "$transcript" 2>/dev/null | tail -n 1 \
             | jq -r '.agentColor // empty' 2>/dev/null)
  if [ -n "$restored" ] && in_palette "$restored" && reusable "$restored"; then
    chosen="$restored"
  fi
fi

# 4. First unheld colour.
if [ -z "$chosen" ]; then
  for name in "${PALETTE[@]}"; do
    if [ ! -e "$REG/$name" ]; then
      chosen="$name"
      printf 'dir=%s\n' "$cwd" > "$REG/$name"
      break
    fi
  done
fi

# All eight colours held by other folders: stay on the default rather than
# duplicating one and making two folders indistinguishable.
[ -n "$chosen" ] || exit 0

# The wrapper exec'd Claude Code, so its $$ is this pid — its "<pid> pending"
# placeholder is this session's line, not a second one. Drop any line for this
# pid before appending, so the registry keeps exactly one entry per session.
if [ -s "$REG/$chosen" ] && grep -q "^${pid} " "$REG/$chosen" 2>/dev/null; then
  grep -v "^${pid} " "$REG/$chosen" > "$REG/$chosen.tmp" && mv "$REG/$chosen.tmp" "$REG/$chosen"
fi

# A folder claiming a colour for the first time via the wrapper has the dir=
# line written already; without the wrapper, the block above created it.
[ -s "$REG/$chosen" ] || printf 'dir=%s\n' "$cwd" > "$REG/$chosen"

printf '%s %s\n' "$pid" "$sid" >> "$REG/$chosen"

# Start the daily release check and do not wait for it. It self-limits to one
# run per calendar day and writes a state file the status line reads for its
# update badge, so nothing on this path ever touches the network synchronously.
#
# The subshell exits immediately and leaves the check reparented to init, and
# every stream is redirected: this hook's stdout is parsed as JSON by Claude
# Code, so a stray line from a background job would be a parse error.
UPDATE_CHECK="$HOME/.local/share/session-colour/update-check.sh"
[ -x "$UPDATE_CHECK" ] && ( "$UPDATE_CHECK" check >/dev/null 2>&1 </dev/null & )

# Deliberately silent.
#
# This hook used to emit `initialUserMessage: "/color <name>"` to set the
# prompt bar colour. Claude Code accepts and logs that field on SessionStart
# (the run is recorded as hook_success, exit 0) but never turns it into a user
# message in interactive mode — it is consumed only on the print/SDK path.
# Verified: a live session's transcript holds the hook_success attachment with
# our JSON in `stdout`, and no corresponding user message or `agent-color`
# record. There is no other hook field that reaches the prompt bar colour.
#
# The claim above is still what colours the status line, which is where the
# per-folder identity actually shows up. The prompt bar is now handled outside
# the hook system entirely, by ~/.claude/bin/claude-session, which passes
# "/color <name>" as the positional prompt argument — the one path that does
# reach it in an interactive session.
exit 0
