#!/usr/bin/env bash
# Custom status line: project identity at a glance, over two or three rows.
#
# Renders directly under the prompt bar, on every session, always visible.
# Receives session JSON on stdin; whatever this prints becomes the line.
#
# The colour MATCHES the prompt bar: session-identity.sh claims a /color name
# at SessionStart and records it in the registry keyed by session id, so this
# looks up the same name and renders its theme RGB.
#
# Touches no session state: /resume keeps its auto-generated topic titles.
#
# --- two rows, plus a third when an update is waiting -------------------------
# The host splits stdout on newlines: one line renders as a single truncating
# <Text>, more than one as a column of them, one <Text> per row. Three rules
# follow from how it prepares those rows, and this script depends on all three:
#
#   1. Every row is .trim()ed before rendering, so leading spaces are stripped.
#      A row whose left group is empty would therefore lose its padding and its
#      right group would slide back to column 0. ESC is not whitespace to
#      trim(), so emit_row opens such a row with a reset to protect the run of
#      spaces that follows.
#   2. Blank rows are dropped (empty lines are filtered out), so a spacer row
#      between the two is not possible.
#   3. Escape sequences accumulate DOWNWARD: before rendering, the host collects
#      every SGR/OSC-8 sequence from the preceding rows and prepends them to
#      each later row. Harmless only because every row here ends in a reset —
#      drop that and row 1's colours bleed into row 2.
#
# Each row truncates its own tail independently, so an overlong row 2 cannot
# disturb row 1. Both rows live in one column box whose width is that of its
# widest row, so the width budget below is shared rather than per-row.
#
#   ROW 1  folder → branch                    model · effort | context
#   ROW 2  GSD phase                           5h% (reset)   7d% (reset)  RC
#   ROW 3            session-colour ↑ v1.2.0            (only when one is waiting)
#
# Row 3 is centred rather than flushed to either side, which is why it is a row
# of its own rather than a block on row 2: it is a notice about the tool itself,
# not a field describing this session, and centring is what tells those apart at
# a glance.

set -uo pipefail

REG="${HOME}/.claude/session-colors"

# RGB for the eight /color names, lifted from the 2.1.220 bundle's theme table
# (the <name>_FOR_SUBAGENTS_ONLY entries, which is what /color actually sets).
#
# The "dark" and "light" themes define the SAME eight values, so this one table
# is correct however theme:auto resolves. Only the colorblind-friendly variants
# differ — on dark-daltonized or light-daltonized, swap in RGB_DALTONIZED below,
# or set MODE=ansi to use the terminal's own colour slots instead.
MODE=truecolor

declare -A RGB=(
  [red]="220;38;38"
  [blue]="106;155;204"
  [green]="22;163;74"
  [yellow]="202;138;4"
  [purple]="130;125;189"
  [orange]="217;119;87"
  [pink]="196;102;134"
  [cyan]="8;145;178"
)
# dark-daltonized. (light-daltonized differs again: red 204;0;0, blue 0;102;204,
# green 0;204;0, yellow 255;204;0, purple 128;0;128, orange 255;128;0,
# pink 255;102;178, cyan 0;178;178.)
declare -A RGB_DALTONIZED=(
  [red]="255;102;102"
  [blue]="102;178;255"
  [green]="102;255;102"
  [yellow]="255;255;102"
  [purple]="178;102;255"
  [orange]="255;178;102"
  [pink]="255;153;204"
  [cyan]="102;204;204"
)
declare -A ANSI=(
  [red]=31 [blue]=34 [green]=32 [yellow]=33
  [purple]=35 [orange]=91 [pink]=95 [cyan]=36
)

payload=$(cat)

if command -v jq >/dev/null 2>&1; then
  dir=$(printf '%s' "$payload" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // empty')
  model=$(printf '%s' "$payload" | jq -r '.model.display_name // empty')
  sid=$(printf '%s' "$payload" | jq -r '.session_id // empty')
  # Candidate folder keys. The SessionStart hook keys on .cwd; these normally
  # all agree, but /add-dir or a worktree can make them diverge.
  keydirs=$(printf '%s' "$payload" | jq -r '[.cwd, .workspace.current_dir, .workspace.project_dir] | map(select(. != null)) | unique | .[]')

  # Usage. context_window.used_percentage is a 0-100 int, null before the first
  # API response. rate_limits mirrors what /usage shows: five_hour is the
  # rolling session block, seven_day the weekly one. The whole rate_limits
  # object is absent until a response carrying the limit headers has landed,
  # so every read here has to tolerate null.
  # ctx_used is total_input_tokens: input + cache_creation + cache_read, the
  # same numerator behind used_percentage. The percentage is still read, purely
  # to pick the colour.
  #
  # fh_raw is the unfloored five-hour percentage. Everything displayed is
  # floored to match the rest of the line, but the burn rate differentiates the
  # value, and integer steps make a 1% granularity look like a rate spike.
  # tostring runs BEFORE the floor map, which only touches numbers.
  #
  # effort is present only on models that support reasoning effort; thinking is
  # always present; remote appears only in a remote/rc session and is the one
  # field here that the bundled statusLine documentation does not mention.
  read -r ctx_used ctx_max ctx_pct fh_pct fh_reset wk_pct wk_reset \
          effort thinking remote fh_raw <<<"$(printf '%s' "$payload" | jq -r '
    [ (.context_window.total_input_tokens     // "-")
    , (.context_window.context_window_size    // "-")
    , (.context_window.used_percentage        // "-")
    , (.rate_limits.five_hour.used_percentage // "-")
    , (.rate_limits.five_hour.resets_at       // "-")
    , (.rate_limits.seven_day.used_percentage // "-")
    , (.rate_limits.seven_day.resets_at       // "-")
    , (.effort.level // "-")
    , (if .thinking.enabled == true then "on" elif .thinking.enabled == false then "off" else "-" end)
    , (if (.remote.session_id // "") != "" then "on" else "-" end)
    , ((.rate_limits.five_hour.used_percentage // "-") | tostring)
    ] | map(if type == "number" then (. | floor | tostring) else . end) | @tsv')"
else
  dir=""; model=""; sid=""; keydirs=""
  ctx_used="-"; ctx_max="-"; ctx_pct="-"
  fh_pct="-"; fh_reset="-"; wk_pct="-"; wk_reset="-"
  effort="-"; thinking="-"; remote="-"; fh_raw="-"
fi
[ -n "$dir" ] || dir="$PWD"
[ -n "$keydirs" ] || keydirs="$dir"

project=$(basename "$dir")

# --- find this FOLDER's colour ----------------------------------------------
# Colours are allocated per folder and shared by every session in it, so match
# on the folder first. Fall back to this session's own registry line in case
# the folder key diverged from what the hook recorded.
colour=""
if [ -d "$REG" ]; then
  for f in "$REG"/*; do
    [ -e "$f" ] || continue
    fdir=""; match=0; first=1
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$first" -eq 1 ]; then
        case "$line" in dir=*) fdir=${line#dir=} ;; esac
        first=0
        continue
      fi
      if [ -n "$sid" ]; then
        rest=${line#* }
        [ "${rest%% *}" = "$sid" ] && match=1
      fi
    done < "$f"

    if [ -n "$fdir" ]; then
      while IFS= read -r k; do
        [ "$k" = "$fdir" ] && match=1
      done <<< "$keydirs"
    fi

    if [ "$match" -eq 1 ]; then
      colour=$(basename "$f")
      break
    fi
  done
fi


branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""

# --- GSD phase ---------------------------------------------------------------
# .planning/ sits at the project root, which is not always the directory the
# session was opened in, so walk up looking for it. Bounded, and every step is
# a stat rather than a fork.
gsd_state=""
d=$dir
for _ in 1 2 3 4 5 6 7 8; do
  [ -n "$d" ] && [ "$d" != "/" ] || break
  if [ -f "$d/.planning/STATE.md" ]; then gsd_state="$d/.planning/STATE.md"; break; fi
  d=${d%/*}
done

# STATE.md carries YAML frontmatter (milestone) and a "## Current Position"
# section holding the live phase and its plan progress. One awk pass reads
# both, and stops at the section after Current Position — the performance
# tables further down are long and none of it is wanted here.
gsd_text=""
if [ -n "$gsd_state" ]; then
  gsd_text=$(awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---"      { fm = 0; next }
    fm && /^milestone:[[:space:]]/ {
      sub(/^milestone:[[:space:]]*/, ""); gsub(/"/, ""); ms = $0; next
    }
    !fm && ph == "" && /^Phase:[[:space:]]/ {
      sub(/^Phase:[[:space:]]*/, ""); ph = $0; next
    }
    # "Plan: 2 of 4 in current phase". GSD writes it when the phase starts and
    # steps it as each plan finishes, so it names the plan now running rather
    # than counting finished ones: 2/4 is the second of four under way. The
    # frontmatter progress counts are deliberately not read — they span the
    # whole milestone, which says nothing about how far this phase has got.
    # Between milestones the line reads "Plan: —", and a phase whose plan count
    # was unknown at the start gives "1 of ?"; neither matches, and both leave
    # the counts off rather than printing half a figure.
    !fm && ph != "" && pt == 0 && /^Plan:[[:space:]]/ {
      if (match($0, /[0-9]+[[:space:]]+of[[:space:]]+[0-9]+/)) {
        split(substr($0, RSTART, RLENGTH), f, /[^0-9]+/)
        pc = f[1] + 0; pt = f[2] + 0
      }
      next
    }
    !fm && ph != "" && /^## / { exit }
    END {
      if (ms == "" && ph == "") exit
      # The phase line often repeats the milestone ("Milestone v4.1 complete");
      # printing both would spend half the block saying it twice.
      if (ph != "") out = (ms != "" && index(ph, ms) == 0) ? ms " · " ph : ph
      else          out = ms
      if (pt > 0) out = out " · " pc "/" pt
      print out
    }' "$gsd_state" 2>/dev/null)
fi

# --- five-hour burn rate -----------------------------------------------------
# rate_limits reports a level; the useful question is which way it is moving.
# Samples are appended to a per-session file and the rate is taken across the
# oldest one still inside the window.
#
# Two guards matter. A percentage that has DROPPED means the five-hour window
# rolled over, and samples from the old window say nothing about the new one —
# so everything before the drop is discarded. And this script runs on every
# render, far faster than the percentage moves, so samples are rate-limited to
# one per MININT seconds rather than one per render.
STATE_DIR="${HOME}/.claude/statusline-state"
burn=""
if [ -n "$sid" ] && [ "$fh_raw" != "-" ]; then
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR"
  sfile="$STATE_DIR/${sid}.5h"
  if [ ! -f "$sfile" ]; then
    : > "$sfile"
    # First render of this session: a good moment to sweep samples left behind
    # by sessions that have since exited. Once per session, not per render.
    find "$STATE_DIR" -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null
  fi
  printf -v now_s '%(%s)T' -1
  burn=$(awk -v now="$now_s" -v pct="$fh_raw" -v win=7200 -v minspan=600 \
             -v minint=20 -v up=$'\u2191' -v out="$sfile.tmp" '
    # n must start numeric: an uninitialised awk variable subscripts as the
    # empty string, which would file the OLDEST sample under t[""] and hide it
    # from the loops below — the span would silently start at the second
    # sample, reading high.
    BEGIN { n = 0 }
    { t[n] = $1 + 0; p[n] = $2 + 0; n++ }
    END {
      start = 0
      for (i = 0; i < n; i++) if (p[i] > pct + 0.5) start = i + 1
      k = 0
      for (i = start; i < n; i++) if (now - t[i] <= win) { kt[k] = t[i]; kp[k] = p[i]; k++ }
      for (i = 0; i < k; i++) print kt[i], kp[i] > out
      if (k == 0 || now - kt[k-1] >= minint) print now, pct > out
      if (k > 0) {
        span = now - kt[0]
        if (span >= minspan) {
          # Only ever upward. Usage accumulates within a five-hour block and is
          # reset by the block ending, never by time passing, so a fall is a
          # rollover the guard above has already discarded — and the small
          # falls it tolerates are float jitter, which would read as a trend.
          rate = (pct - kp[0]) * 3600 / span
          if (rate >= 0.5) printf "%s%d%%/h", up, rate + 0.5
        }
      }
    }' "$sfile" 2>/dev/null)
  mv -f "$sfile.tmp" "$sfile" 2>/dev/null
fi

# Unix epoch -> local wall-clock time the window resets, 24h.
#
# Bare HH:MM when that lands today, so the common case stays short. The weekly
# window is usually days out, where a bare HH:MM would be ambiguous, so those
# get a weekday prefix — and a date once it's beyond the coming week.
#
# printf's %(fmt)T is a bash builtin, so none of this forks — worth having in a
# function that runs twice on every render.
at_str() {
  local ts=$1 now today then_day
  printf -v now '%(%s)T' -1
  printf -v today '%(%Y-%m-%d)T' "$now"
  printf -v then_day '%(%Y-%m-%d)T' "$ts"

  # Already elapsed: the window has reset. Say so, rather than formatting a past
  # timestamp into something that reads like an upcoming one.
  if [ "$ts" -le "$now" ]; then
    printf 'now'
  elif [ "$then_day" = "$today" ]; then
    printf '%(%H:%M)T' "$ts"
  elif [ $(( ts - now )) -lt 518400 ]; then   # inside 6 days: weekday is unambiguous
    printf '%(%a %H:%M)T' "$ts"
  else
    printf '%(%d %b %H:%M)T' "$ts"
  fi
}

# Token count -> 130.5k / 1M / 847. One decimal, but a trailing .0 is dropped so
# round numbers stay round: 200000 -> 200k, not 200.0k.
fmt_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n < 1000) { printf "%d", n; exit }
    if (n >= 1000000) { v = n/1000000; u = "M" } else { v = n/1000; u = "k" }
    s = sprintf("%.1f", v)
    # Rounding can push a k value to 1000.0 (999999 -> "1000k"); promote it.
    if (u == "k" && s + 0 >= 1000) { s = sprintf("%.1f", n/1000000); u = "M" }
    sub(/\.0$/, "", s)
    printf "%s%s", s, u
  }'
}

# --- powerline rendering -----------------------------------------------------
# Two groups per row, mirroring .bashrc_custom:
#
#   LEFT   powerline blocks joined by U+E0B0 arrows — folder, then git branch.
#   RIGHT  free-standing rectangles with a gap between them, like the $HISTCMD
#          counter in that prompt: grey background, light grey text, no arrows.
#
# The right group is flushed to the terminal edge; Claude Code exports COLUMNS
# to the status line command, so the width is known.
SEP=$'\ue0b0'        # separator blockright
THIN=$'\ue0b1'       # separator right
GIT_GLYPH=$'\ue0a0'  # separator branch

# Row-1 marker: extended thinking.
THINK_GLYPH=$'\u273b'   # sixteen pointed asterisk

# Row-2 window labels. Nerd Font private-use glyphs, chosen over the obvious
# emoji (U+1F550, U+1F4C5) because those render double-width: visw() counts
# characters, so an emoji here would under-measure the right group by a column
# per row and push the flushed blocks past the terminal edge. These sit in the
# same patched font the powerline separators above already require.
CLOCK_GLYPH=$'\uf017'   # nf-fa-clock_o  \u2014 the rolling five-hour window
CAL_GLYPH=$'\uf073'     # nf-fa-calendar \u2014 the seven-day window

PL_GREY="51;51;51"
PL_LIGHTGREY="153;153;153"
PL_WHITE="255;255;255"
PL_BLUE="45;119;206"

# Threshold text colours. Lightened off the .bashrc_custom red/amber, which are
# too dark to read on the #333 blocks these sit in.
PL_WARN="255;179;0"    # Amber 600
PL_CRIT="255;82;82"    # Red A200

# Git block. Blue is what git_info() uses in .bashrc_custom, so the branch reads
# as the same field in both places.
#
# It is not the maximally-distinct choice: no fixed colour clears all eight
# session colours, and blue lands closest to session blue (106;155;204) and cyan
# (8;145;178) — same hue family, differing mainly in lightness, so those two
# folders show a softer folder/branch boundary. Chosen deliberately over the
# neutral grey, which clashes with nothing but reads as a gap rather than a
# field. PL_GIT_ALT is the widest-clearance fixed colour if that trade is ever
# worth revisiting.
PL_GIT_ALT="78;107;31"   # #4e6b1f — hue 83°, the furthest a fixed colour can
                         # sit from all eight session colours (42° clearance)
GIT_BG=$PL_BLUE
GIT_FG=$PL_WHITE

# GSD block. This is where PL_GIT_ALT earns its keep: the phase block is the
# only left block on row 2, sitting directly under the folder block, so it is
# the one place on the line that has to clear all eight session colours at
# once. That is exactly what the olive was computed for.
GSD_BG=$PL_GIT_ALT

# Session colour for the folder block, so status line, prompt bar and the
# folder's /color claim agree. Falls back to the prompt's directory green.
PL_PROJECT="46;125;50"
if [ -n "$colour" ] && [ -n "${RGB[$colour]:-}" ]; then
  PL_PROJECT=${RGB[$colour]}
fi

R=$'\033[0m'
BOLD=$'\033[1m'

# Visible width: character count with SGR sequences removed.
visw() {
  local s
  s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  printf '%s' "${#s}"
}

# Text is white on every left block. An earlier version picked black or white by
# WCAG contrast ratio, which flipped exactly one session colour — blue
# (106;155;204), the only one where white misses AA — to black. Bold weight
# carries that case, and a uniform white matches .bashrc_custom, so the rule was
# dropped rather than left to single out one colour.

# Usage percentage -> text colour, so the meters still signal pressure now that
# the blocks themselves are a fixed grey.
fg_for_pct() {
  if   [ "$1" -ge 85 ]; then printf '%s' "$PL_CRIT"
  elif [ "$1" -ge 60 ]; then printf '%s' "$PL_WARN"
  else                       printf '%s' "$PL_LIGHTGREY"
  fi
}

# --- left group ---------------------------------------------------------------
# Blocks are normally joined by a U+E0B0 arrow drawn in the previous block's
# colour. The git block is the exception, following git_info() in
# .bashrc_custom: it opens with the branch glyph on its own background instead
# of an arrow, so the icon IS the separator rather than sitting after one.
lsegs=()
# bg, fg ("" = white), text, lead ("" = arrow separator)
add_left() { lsegs+=("$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"); }

# Turn whatever add_left has collected into $left / $left_w.
render_left() {
  local i bg fg text lead
  left=""; left_w=0; prev_bg=""
  for i in "${!lsegs[@]}"; do
    IFS=$'\x1f' read -r bg fg text lead <<< "${lsegs[$i]}"
    [ -n "$fg" ] || fg=$PL_WHITE
    if [ -n "$lead" ]; then
      # Glyph separator: drawn in this block's own colours, no arrow.
      left+=$'\033[48;2;'"${bg}"$'m\033[38;2;'"${fg}"$'m'"$lead"
      left_w=$(( left_w + 1 ))
    elif [ "$i" -gt 0 ]; then
      left+=$'\033[38;2;'"${prev_bg}"$'m\033[48;2;'"${bg}"$'m'"$SEP"
      left_w=$(( left_w + 1 ))
    fi
    left+=$'\033[48;2;'"${bg}"$'m\033[38;2;'"${fg}"$'m '"${text}"$' '"$R"
    left_w=$(( left_w + $(visw "$text") + 2 ))
    prev_bg=$bg
  done
  if [ -n "$left" ]; then
    left+=$'\033[38;2;'"${prev_bg}"$'m'"$SEP""$R"
    left_w=$(( left_w + 1 ))
  fi
}

# Left builders take one argument: how many characters to shave off the row's
# elastic field, 0 for none. Only the last resort in fit_row passes anything
# other than 0.
shrink() {   # $1 = text, $2 = shave, $3 = floor width
  local t=$1 shave=$2 floor=$3 max
  if [ "$shave" -gt 0 ]; then
    max=$(( ${#t} - shave ))
    [ "$max" -lt "$floor" ] && max=$floor
    [ "${#t}" -gt "$max" ] && t="${t:0:$(( max - 1 ))}…"
  fi
  printf '%s' "$t"
}

build_left_ident() {
  lsegs=()
  add_left "$PL_PROJECT" "$PL_WHITE" "${BOLD}${project}" ""
  [ -n "$branch" ] && add_left "$GIT_BG" "$GIT_FG" "$(shrink "$branch" "$1" 8)" "$GIT_GLYPH"
  render_left
}

build_left_gsd() {
  lsegs=()
  [ -n "$gsd_text" ] && add_left "$GSD_BG" "$PL_WHITE" "$(shrink "$gsd_text" "$1" 12)" ""
  render_left
}

# --- update badge ------------------------------------------------------------
# Whatever the last daily check found, as recorded by lib/update-check.sh. This
# is a file read and nothing else: the status line redraws constantly, so it
# must never call git or touch the network. The check that writes these files
# runs in the background from the SessionStart hook.
#
# The text names the tool, because this row is the only thing on the line that
# is not about the current session — an unlabelled "↑ v1.2.0" beside a model
# name and a token count reads as though the SESSION has an update waiting.
#
# U+2191 rather than the obvious U+2B06: the upwards *arrow* is narrow in every
# terminal, whereas the emoji-range one renders double-width in some, and visw()
# counts characters — an under-measured block would centre off by a column.
# Same reasoning as the row-2 window glyphs above.
UPDATE_GLYPH=$'↑'
UPDATE_NAME="session-colour"
update_badge=""
_us="${XDG_STATE_HOME:-$HOME/.local/state}/session-colour"
if [ -r "$_us/available" ] && [ -r "$_us/installed" ]; then
  read -r _av < "$_us/available" || _av=""
  read -r _in < "$_us/installed" || _in=""
  if [ -n "$_av" ] && [ -n "$_in" ] && [ "$_av" != "$_in" ] \
     && [ "$(printf '%s\n%s\n' "$_in" "$_av" | sort -V | tail -1)" = "$_av" ]; then
    update_badge="${UPDATE_NAME} ${UPDATE_GLYPH} v${_av}"
  fi
fi

# --- right group: free-standing rectangles -----------------------------------
# Each entry is "fg<US>text"; rendered as a grey rectangle with one space of
# padding either side, and one column of gap between rectangles.
rsegs=()
add_right() { rsegs+=("$1"$'\x1f'"$2"); }

# Colour switch, for building a block whose parts signal separately.
sgr() { printf '\033[38;2;%sm' "$1"; }

# ROW 1 right: what this turn is running on, then what it is running through.
#
# One block, halves divided by a pipe, following the two rate windows below:
# model identity and reasoning settings on the left of it, context consumption
# on the right. Verbosity steps down by dropping the effort/thinking pair, then
# the model name — the token pair is the last thing standing because it is the
# only half that changes every turn.
build_right_ctx() {
  local level=$1 head="" tail="" combined="" name mark
  rsegs=()

  if [ -n "$model" ] && [ "$level" -ge 1 ]; then
    name=$model
    # Long-context display names carry the window size already ("Opus 5 (1M
    # context)"); drop that suffix since the token pair states it.
    case "$name" in
      *" ("*"context)") name="${name% (*context)}" ;;
    esac
    head=$name
    if [ "$level" -ge 2 ]; then
      # The star marks extended thinking; effort is only present on models that
      # support it, so the two combine into whichever parts exist.
      mark=""
      [ "$thinking" = "on" ] && mark=$THINK_GLYPH
      if   [ "$effort" != "-" ]; then head+=" · ${mark}${effort}"
      elif [ -n "$mark" ];      then head+=" · ${mark}"
      fi
    fi
  fi

  if [ "$ctx_used" != "-" ] && [ "$ctx_max" != "-" ]; then
    case "$ctx_pct" in
      ''|-|*[!0-9]*) tail=$(sgr "$PL_LIGHTGREY") ;;
      *)             tail=$(sgr "$(fg_for_pct "$ctx_pct")") ;;
    esac
    tail+="$(fmt_tokens "$ctx_used") / $(fmt_tokens "$ctx_max")"
  fi

  combined=$head
  if [ -n "$tail" ]; then
    [ -n "$combined" ] && combined+="$(sgr "$PL_LIGHTGREY") | "
    combined+=$tail
  fi
  [ -n "$combined" ] && add_right "$PL_LIGHTGREY" "$combined"
}

# One usage window as its own rectangle. The label prefix says which window this
# is: the two used to share a block and be told apart by the pipe between them,
# and once they became separate rectangles a bare pair of percentages would not
# say which was which. It is an icon rather than "5h"/"7d" text, which frees a
# column per block and leaves the percentage as the only digits in the block
# until the reset time — which is parenthesised for the same reason, so the two
# numbers cannot be read as one run.
meter_block() {   # label, pct, reset, level, burn
  local label=$1 pct=$2 reset=$3 level=$4 rate=$5 out
  case "$pct" in ''|-|*[!0-9]*) return 1 ;; esac
  out="$(sgr "$PL_LIGHTGREY")${label} $(sgr "$(fg_for_pct "$pct")")${pct}%"
  if [ "$level" -ge 2 ]; then
    case "$reset" in ''|-|*[!0-9]*) ;; *) out+="$(sgr "$PL_LIGHTGREY") ($(at_str "$reset"))" ;; esac
  fi
  [ "$level" -ge 1 ] && [ -n "$rate" ] && out+="$(sgr "$PL_LIGHTGREY") ${rate}"
  printf '%s' "$out"
}

# ROW 2 right: the two subscription windows, then the remote badge.
#
# RC comes from .remote.session_id, which is present only in a remote session.
# It is never dropped by the verbosity ladder — it is two characters, and it is
# the one item here that changes what the session IS rather than how loaded it
# is.
build_right_usage() {
  local level=$1 t
  rsegs=()
  if t=$(meter_block "$CLOCK_GLYPH" "$fh_pct" "$fh_reset" "$level" "$burn"); then
    add_right "$PL_LIGHTGREY" "$t"
  fi
  if t=$(meter_block "$CAL_GLYPH" "$wk_pct" "$wk_reset" "$level" ""); then
    add_right "$PL_LIGHTGREY" "$t"
  fi
  [ "$remote" = "on" ] && add_right "$PL_WHITE" "RC"
  return 0
}

right_width() {
  local w=0 i text
  for i in "${!rsegs[@]}"; do
    text=${rsegs[$i]#*$'\x1f'}
    w=$(( w + $(visw "$text") + 2 ))
  done
  [ ${#rsegs[@]} -gt 1 ] && w=$(( w + ${#rsegs[@]} - 1 ))
  printf '%s' "$w"
}

render_right() {
  local out="" i fg text
  for i in "${!rsegs[@]}"; do
    fg=${rsegs[$i]%%$'\x1f'*}
    text=${rsegs[$i]#*$'\x1f'}
    [ "$i" -gt 0 ] && out+=" "
    out+=$'\033[48;2;'"${PL_GREY}"$'m\033[38;2;'"${fg}"$'m '"${text}"$' '"$R"
  done
  printf '%s' "$out"
}

# --- compose -----------------------------------------------------------------
cols=${COLUMNS:-0}
[ "$cols" -gt 0 ] 2>/dev/null || cols=$(tput cols 2>/dev/null) || cols=80
[ "$cols" -gt 0 ] 2>/dev/null || cols=80
# Headroom, two parts.
#
# LAYOUT_INSET — Ink truncates against its own layout width, not COLUMNS: the
# footer box carries horizontal padding this script cannot observe. Measured by
# bracketing on a 119-column terminal — a 116-character line renders whole, 117
# loses its tail.
LAYOUT_INSET=3
#
# INDICATOR_RESERVE — the footer is one flexWrap:"wrap" row holding two columns:
# this status line (with the mode/agents hint line beneath it) on the left, and
# the badge column — /rc, IDE, debug, PR, mode labels — on the right. Since this
# line pads itself to the full width to flush its right-hand blocks, it crowds
# that column onto a line of its own. Leaving room keeps the badges on this row,
# top-aligned beside the status line.
#
# Sized for the short "/rc" badge (3) plus the parent's columnGap (1). Claude
# Code shows the longer "/rc active" for the first five sessions that see it,
# which still wraps; widen this to 11 to cover that too. Nothing in the status
# line payload reports whether that badge is showing, so this is a fixed
# reservation rather than a conditional one — when the badges are absent it
# simply holds the right-hand blocks 4 columns off the edge.
#
# It applies to BOTH rows, not just the one the badges sit beside: the rows
# share a column box whose width is that of its widest row, so a full-width
# row 2 would push the badge column down exactly as a full-width row 1 does.
INDICATOR_RESERVE=4
avail=$(( cols - LAYOUT_INSET - INDICATOR_RESERVE ))

# Fit one row: step the right group down through its verbosity levels until the
# pair fits, and only then start truncating the left group, which is the sole
# elastic field. Sets $left, $gap and leaves $rsegs ready for render_right.
fit_row() {   # left builder, right builder, top verbosity level
  local lb=$1 rb=$2 top=$3 level rw over
  for (( level = top; level >= 0; level-- )); do
    "$rb" "$level"; rw=$(right_width)
    "$lb" 0
    gap=$(( avail - left_w - rw ))
    [ "$gap" -ge 1 ] && return 0
  done
  # Still overflowing at the lowest verbosity: the left group is the problem.
  # Truncate it rather than let the host clip the row, which would drop the
  # right-hand blocks off the end — the part worth keeping.
  over=$(( left_w + rw + 1 - avail ))
  "$lb" "$over"
  gap=$(( avail - left_w - rw ))
  if [ "$gap" -lt 1 ]; then
    # Narrow enough that even a floor-width left group overflows. Drop it
    # outright rather than hand the row to the host to clip, because the host
    # clips the TAIL — it would take the usage blocks and leave a folder name.
    left=""; left_w=0
    gap=$(( avail - rw ))
    [ "$gap" -lt 1 ] && gap=1
  fi
  return 0
}

emit_row() {   # left, gap, right
  # A row with no left group would start with the padding run, and the host
  # trims each row before rendering it — so open with a reset, which is not
  # whitespace and stops trim() from reaching the spaces behind it.
  local lead=""
  [ -n "$1" ] || lead=$R
  printf '%s%s%*s%s\n' "$lead" "$1" "$2" "" "$3"
}

fit_row build_left_ident build_right_ctx 2
emit_row "$left" "$gap" "$(render_right)"

# Row 2 is conditional: no phase, no windows and no remote badge means there is
# nothing to say, and an empty row would be dropped by the host anyway.
if [ -n "$gsd_text" ] || [ "$fh_pct" != "-" ] || [ "$wk_pct" != "-" ] || [ "$remote" = "on" ]; then
  fit_row build_left_gsd build_right_usage 2
  emit_row "$left" "$gap" "$(render_right)"
fi

# Row 3 is emitted only when an update is waiting, so most sessions never see a
# third row at all.
#
# Centred, which emit_row expresses as an empty left group and a gap: the host
# trims each row before rendering, and the reset emit_row leads with is what
# stops that trim from eating the padding and sliding this back to column 0.
#
# The centre is taken over $avail, the same budget rows 1 and 2 pad themselves
# out to, so it reads as centred against them rather than against the terminal.
# A window too narrow to centre in falls back to column 0 rather than
# overflowing — the row would otherwise push past the edge and be clipped.
if [ -n "$update_badge" ]; then
  rsegs=()
  add_right "$PL_WARN" "$update_badge"
  pad=$(( (avail - $(right_width)) / 2 ))
  [ "$pad" -ge 1 ] || pad=0
  emit_row "" "$pad" "$(render_right)"
fi
