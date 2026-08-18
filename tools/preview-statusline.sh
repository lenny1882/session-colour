#!/usr/bin/env bash
# Render the status line for colour combinations that would otherwise need a
# live session in the right folder, on the right branch, holding the right
# registry claim.
#
# Works against the INSTALLED script rather than a copy, so a preview can never
# drift from what the terminal actually draws. Four substitutions are patched
# into a temporary copy:
#
#   colour=""              -> honours $PV_COLOUR   (skips the registry lookup)
#   branch=$(git ...)      -> honours $PV_BRANCH   (no repo needed)
#   GIT_BG=$PL_BLUE        -> honours $PV_GIT_BG   (try other block colours)
#   STATE_DIR=...          -> honours $PV_STATE_DIR (burn-rate samples, seeded
#                             below, so previews don't write to the real one)
#
# Everything else — widths, glyphs, thresholds, the degradation ladder — is the
# real code.
#
# Usage:
#   preview-statusline.sh                      # one line, current defaults
#   PV_COLOUR=purple PV_BRANCH=main ...        # single line, overridden
#   preview-statusline.sh --palette            # all eight, with and without git
#   preview-statusline.sh --git-colours        # eight colours x six git blocks
#
# Output is ANSI on stdout. Pipe through ansi2svg.py for a shareable image:
#   ./preview-statusline.sh --palette | ./ansi2svg.py > palette.svg
set -uo pipefail

SRC=${PV_SRC:-$HOME/.claude/hooks/statusline-project.sh}
COLS=${PV_COLS:-119}
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RENDER="$WORK/render.sh"

sed -e 's|^colour=""$|colour="${PV_COLOUR:-}"|' \
    -e 's|^branch=\$(git .*|branch="${PV_BRANCH:-}"|' \
    -e 's|^GIT_BG=\$PL_BLUE$|GIT_BG=${PV_GIT_BG:-$PL_BLUE}|' \
    -e 's|^STATE_DIR=.*|STATE_DIR="${PV_STATE_DIR:-$HOME/.claude/statusline-state}"|' \
    "$SRC" > "$RENDER"

for pat in 'PV_COLOUR' 'PV_BRANCH' 'PV_GIT_BG' 'PV_STATE_DIR'; do
  grep -q "$pat" "$RENDER" || {
    echo "patch failed: $pat not applied — has $SRC changed shape?" >&2
    exit 1
  }
done

# The climb rate is not a payload field — it is measured from samples the real
# script appends per session. One sample an hour old, four points below the
# payload's 21%, gives the \u21914%/h the README documents. Seeded into a
# throwaway state dir so a preview neither reads nor litters the real one.
export PV_STATE_DIR="$WORK/state"
mkdir -p "$PV_STATE_DIR"
printf '%s 17\n' "$(( $(date +%s) - 3600 ))" > "$PV_STATE_DIR/preview.5h"

# One line. Timestamps are relative to now so the reset times read naturally.
line() {
  # Only the basename is ever rendered, so the leading path is arbitrary.
  local dir=${PV_DIR:-$HOME/example-project} now
  now=$(date +%s)
  jq -n --arg d "$dir" \
        --argjson fh $(( now + 3 * 3600 )) \
        --argjson wk $(( now + 4 * 86400 )) '{
    session_id: "preview", cwd: $d,
    workspace: { current_dir: $d, project_dir: $d },
    model: { display_name: "Opus 5 (1M context)" },
    effort: { level: "high" },
    thinking: { enabled: true },
    context_window: {
      total_input_tokens: 167900, context_window_size: 1000000,
      used_percentage: 17
    },
    rate_limits: {
      five_hour:  { used_percentage: 21, resets_at: $fh },
      seven_day:  { used_percentage: 15, resets_at: $wk }
    }
  }' | COLUMNS=$COLS bash "$RENDER"
}

COLOURS=(red blue green yellow purple orange pink cyan)
BRANCH_DEMO=feature/HBD20-1767-bring-phase-3

case "${1:-}" in
  --palette)
    for b in "" "$BRANCH_DEMO"; do
      for c in "${COLOURS[@]}"; do
        PV_COLOUR=$c PV_BRANCH=$b line
      done
    done
    ;;
  --git-colours)
    # The six chromatic colours defined in .bashrc_custom.
    while read -r label rgb; do
      printf '  %s\n' "$label"
      for c in "${COLOURS[@]}"; do
        PV_COLOUR=$c PV_BRANCH=$BRANCH_DEMO PV_GIT_BG=$rgb line
      done
      printf '\n'
    done <<'EOF'
blue_#2d77ce 45;119;206
green_#2e7d32 46;125;50
purple_#7b1fa2 123;31;162
red_#d32f2f 211;47;47
lightgreen_#00ff00 0;255;0
teal_#1f88a2 31;136;162
EOF
    ;;
  *)
    line
    ;;
esac
