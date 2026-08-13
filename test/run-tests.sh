#!/usr/bin/env bash
# Tests for session-colour.
#
# Everything runs against a throwaway HOME, which is what keeps the real
# ~/.claude out of it — these scripts read and write $HOME/.claude directly and
# there is no CLAUDE_DIR override, so redirecting HOME is the only isolation
# there is. Never run these without it.
#
# The launcher is driven through CLAUDE_REAL_BIN, which points it at a stub
# instead of the real claude, so exec'ing is safe and the test can see what it
# was about to run.
#
# Every CLAUDE_* variable is cleared first. A session running inside Claude Code
# exports CLAUDE_CODE_CHILD_SESSION, CLAUDE_SESSION_COLOUR and CLAUDE_PID, and
# all three are read by the code under test — inherit them and the suite quietly
# tests a path nobody will ever hit, passing either way.
set -uo pipefail

while IFS='=' read -r v _; do unset "$v"; done < <(env | grep -E '^CLAUDE')

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SL="$REPO/hooks/statusline-project.sh"
ID="$REPO/hooks/session-identity.sh"
END="$REPO/hooks/session-identity-end.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
GIT="git -c user.email=test@example.com -c user.name=test -c commit.gpgsign=false"

REPO_SNAPSHOT=$(find "$REPO" -path "$REPO/.git" -prune -o -print | sort)
pass=0; fail=0
ok(){ printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n    %s\n' "$1" "$2"; fail=$((fail+1)); }

echo "sanity"
for f in "$REPO"/*.sh "$REPO"/hooks/*.sh "$REPO"/lib/*.sh "$REPO"/tools/*.sh "$REPO"/bin/claude-session; do
  [ -f "$f" ] || continue
  bash -n "$f" && ok "$(basename "$f") parses" || no "$(basename "$f") parses" "syntax error"
done
if command -v python3 >/dev/null 2>&1; then
  # Compiled to a temp file on purpose: py_compile's default drops a
  # __pycache__ directory into tools/, and a test suite must not write into
  # the checkout it is testing.
  python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$REPO/tools/ansi2svg.py" "$TMP/ansi2svg.pyc" 2>/dev/null \
    && ok "ansi2svg.py compiles" || no "ansi2svg.py compiles" "syntax error"
fi
[ -s "$REPO/VERSION" ] && ok "VERSION is set" || no "VERSION is set" "empty or missing"

# A git repository to render a status line for.
proj="$TMP/my-project"; mkdir -p "$proj"
$GIT init -q "$proj"; $GIT -C "$proj" checkout -q -b main
: > "$proj/f"; $GIT -C "$proj" add f; $GIT -C "$proj" commit -qm first
other="$TMP/other-project"; mkdir -p "$other"

payload() { # payload <dir> <session-id> [source]
  jq -n --arg d "$1" --arg s "$2" --arg src "${3:-startup}" \
    '{session_id: $s, cwd: $d, source: $src,
      transcript_path: "/nonexistent.jsonl",
      model: {display_name: "Opus 5"},
      workspace: {current_dir: $d, project_dir: $d},
      context_window: {total_input_tokens: 42000, context_window_size: 200000, used_percentage: 21},
      rate_limits: {five_hour: {used_percentage: 12}, seven_day: {used_percentage: 34}}}'
}

echo "the status line"
out=$(payload "$proj" s1 | (cd "$proj" && "$SL")); rc=$?
[ "$rc" = 0 ] && ok "renders without failing" || no "renders without failing" "exit $rc"
grep -q "my-project" <<<"$out" && ok "names the folder" || no "names the folder" "$out"
grep -q "main" <<<"$out" && ok "shows the git branch" || no "shows the git branch" "$out"
grep -q "Opus 5" <<<"$out" && ok "shows the model" || no "shows the model" "$out"
# The host drops blank rows and accumulates escape sequences downward, so every
# row has to end in a reset or row 1's colours bleed into row 2.
blank=0; unreset=0
while IFS= read -r row; do
  [ -z "$row" ] && blank=1
  case "$row" in *$'\033'"[0m") ;; *) unreset=1 ;; esac
done <<<"$out"
[ "$blank" = 0 ] && ok "emits no blank rows, which the host would drop" || no "emits no blank rows, which the host would drop" "found one"
[ "$unreset" = 0 ] && ok "every row ends in a reset, so colours cannot bleed downward" || no "every row ends in a reset, so colours cannot bleed downward" "a row does not"
[ "$(wc -l <<<"$out")" -ge 2 ] && ok "renders the second row when there is usage to show" || no "renders the second row when there is usage to show" "$(wc -l <<<"$out") row(s)"

echo "claiming a colour"
# Each session needs its own live pid: the hook replaces the line matching its
# own pid (that is how the launcher's "<pid> pending" placeholder gets filled
# in), and it drops lines whose process has gone.
sleep 300 & p1=$!
sleep 300 & p2=$!
trap 'kill $p1 $p2 2>/dev/null; rm -rf "$TMP"' EXIT
payload_out=$(payload "$proj" s1 | (cd "$proj" && CLAUDE_PID=$p1 "$ID"))
[ -z "$payload_out" ] && ok "the hook is silent, as SessionStart output is parsed" || no "the hook is silent, as SessionStart output is parsed" "$payload_out"
files=("$HOME/.claude/session-colors"/*)
[ "${#files[@]}" = 1 ] && [ -f "${files[0]}" ] \
  && ok "one colour is claimed" || no "one colour is claimed" "${files[*]}"
colour=$(basename "${files[0]}")
head -1 "${files[0]}" | grep -q "^dir=$proj$" \
  && ok "the claim records the folder" || no "the claim records the folder" "$(head -1 "${files[0]}")"
grep -q " s1$" "${files[0]}" && ok "and the session" || no "and the session" "$(cat "${files[0]}")"

payload "$proj" s2 | (cd "$proj" && CLAUDE_PID=$p2 "$ID")
[ "$(ls "$HOME/.claude/session-colors" | wc -l)" = 1 ] \
  && ok "a second session in the same folder joins it" || no "a second session in the same folder joins it" "$(ls "$HOME/.claude/session-colors")"
[ "$(grep -c ' s[12]$' "$HOME/.claude/session-colors/$colour")" = 2 ] \
  && ok "and both sessions are listed" || no "and both sessions are listed" "$(cat "$HOME/.claude/session-colors/$colour")"

payload "$other" s3 | (cd "$other" && CLAUDE_PID=$p1 "$ID")
[ "$(ls "$HOME/.claude/session-colors" | wc -l)" = 2 ] \
  && ok "a different folder takes a different colour" || no "a different folder takes a different colour" "$(ls "$HOME/.claude/session-colors")"

echo "the status line and the prompt bar agree"
rm -rf "$HOME/.claude/session-colors"
payload "$proj" s9 | (cd "$proj" && CLAUDE_PID=$p1 CLAUDE_SESSION_COLOUR=blue "$ID")
[ -f "$HOME/.claude/session-colors/blue" ] \
  && ok "the launcher's choice is honoured, not overruled" || no "the launcher's choice is honoured, not overruled" "$(ls "$HOME/.claude/session-colors")"
# 106;155;204 is /color blue in the bundled theme table. If the status line
# rendered anything else, the two halves would disagree on screen — which is
# the whole point of the package.
out=$(payload "$proj" s9 | (cd "$proj" && "$SL"))
grep -q "106;155;204" <<<"$out" \
  && ok "the status line renders that same blue" || no "the status line renders that same blue" "no match in the rendered line"

echo "releasing it"
payload "$proj" s8 | (cd "$proj" && CLAUDE_PID=$p2 "$ID")
payload "$proj" s8 | (cd "$proj" && CLAUDE_PID=$p2 "$END")
[ -f "$HOME/.claude/session-colors/blue" ] \
  && ok "one session leaving keeps the folder's colour" || no "one session leaving keeps the folder's colour" "released too early"
payload "$proj" s9 | (cd "$proj" && CLAUDE_PID=$p1 "$END")
[ -e "$HOME/.claude/session-colors/blue" ] \
  && no "the last session out releases the colour" "still claimed" || ok "the last session out releases the colour"

echo "resuming a session"
# The bug this covers: a folder's colour is released when its last session
# exits, another folder takes it overnight, and the resumed session comes back
# with a prompt bar the status line cannot match. The launcher now passes
# "/color <name>" on resume too, so the hook has to honour that choice rather
# than allocate around it.
rm -rf "$HOME/.claude/session-colors"
payload "$other" s10 | (cd "$other" && CLAUDE_PID=$p2 CLAUDE_SESSION_COLOUR=red "$ID")
printf 'dir=%s\n%s pending\n' "$proj" "$p1" > "$HOME/.claude/session-colors/green"
payload "$proj" s11 resume | (cd "$proj" && CLAUDE_PID=$p1 CLAUDE_SESSION_COLOUR=green "$ID")
grep -q " s11$" "$HOME/.claude/session-colors/green" 2>/dev/null \
  && ok "a resumed session keeps the colour the launcher gave it" || no "a resumed session keeps the colour the launcher gave it" "$(ls "$HOME/.claude/session-colors")"
head -1 "$HOME/.claude/session-colors/red" | grep -q "^dir=$other$" \
  && ok "without disturbing the folder that took its old colour" || no "without disturbing the folder that took its old colour" "$(cat "$HOME/.claude/session-colors/red" 2>&1)"

# The launcher claims before it launches, so between the claim and this hook
# another folder can win the same colour. The placeholder it left behind must
# not go on holding a colour this session does not use.
rm -rf "$HOME/.claude/session-colors"; mkdir -p "$HOME/.claude/session-colors"
printf 'dir=%s\n%s s12\n%s pending\n' "$other" "$p2" "$p1" > "$HOME/.claude/session-colors/green"
payload "$proj" s13 | (cd "$proj" && CLAUDE_PID=$p1 CLAUDE_SESSION_COLOUR=green "$ID")
grep -q "^${p1} " "$HOME/.claude/session-colors/green" \
  && no "a claim overtaken before the hook runs is given back" "still holds green" || ok "a claim overtaken before the hook runs is given back"
grep -q " s12$" "$HOME/.claude/session-colors/green" \
  && ok "and the folder that overtook it keeps green" || no "and the folder that overtook it keeps green" "$(cat "$HOME/.claude/session-colors/green" 2>&1)"
grep -lq " s13$" "$HOME/.claude/session-colors"/* 2>/dev/null \
  && ok "while this session lands on a colour of its own" || no "while this session lands on a colour of its own" "$(ls "$HOME/.claude/session-colors")"

echo "the launcher"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/fake-claude" <<'STUB'
#!/usr/bin/env bash
{ printf 'args: %s\n' "$*"; printf 'colour: %s\n' "${CLAUDE_SESSION_COLOUR:-none}"; } > "$FAKE_CLAUDE_LOG"
STUB
chmod +x "$TMP/bin/fake-claude"
export CLAUDE_REAL_BIN="$TMP/bin/fake-claude" FAKE_CLAUDE_LOG="$TMP/launched"
LAUNCH="$REPO/bin/claude-session"
# The launcher only colours when stdout is a terminal, so these run under a pty.
# Without one every case takes the same "not a terminal" exit and the suite
# proves nothing.
if command -v script >/dev/null 2>&1; then
  launch() { ( cd "$proj" && script -qec "$LAUNCH $*" /dev/null ) >/dev/null 2>&1; }

  rm -rf "$HOME/.claude/session-colors"; : > "$TMP/launched"
  launch --model opus
  grep -q 'args: --model opus' "$TMP/launched" \
    && ok "arguments reach claude unchanged" || no "arguments reach claude unchanged" "$(cat "$TMP/launched" 2>&1)"
  claimed=$(sed -n 's/^colour: //p' "$TMP/launched")
  [ -n "$claimed" ] && [ "$claimed" != none ] \
    && ok "a colour is claimed before launch, not after" || no "a colour is claimed before launch, not after" "$(cat "$TMP/launched" 2>&1)"
  [ -f "$HOME/.claude/session-colors/$claimed" ] \
    && ok "and written to the registry the hooks read" || no "and written to the registry the hooks read" "no $claimed file"
  # The hook fills the real session id in later; until then the line is a
  # placeholder against the launcher's own pid.
  grep -q ' pending$' "$HOME/.claude/session-colors/$claimed" \
    && ok "as a placeholder for the hook to complete" || no "as a placeholder for the hook to complete" "$(cat "$HOME/.claude/session-colors/$claimed")"

  # Resuming restores the session's own colour from the transcript, which is
  # the colour a folder may since have lost. The launcher colours it anyway,
  # and "/color <name>" runs after the restore, so the folder wins.
  #
  # Bare --resume takes an optional value, so the prompt needs a `--` in front
  # of it or Claude Code reads "/color <name>" as the picker's search term:
  #     claude --resume '/color red'  ->  Provided value "/color red" ...
  rm -rf "$HOME/.claude/session-colors"; : > "$TMP/launched"
  launch --resume
  claimed=$(sed -n 's/^colour: //p' "$TMP/launched")
  [ -n "$claimed" ] && [ "$claimed" != none ] \
    && ok "--resume is coloured, not skipped" || no "--resume is coloured, not skipped" "$(cat "$TMP/launched" 2>&1)"
  grep -q "args: --resume -- /color $claimed" "$TMP/launched" \
    && ok "and its prompt is fenced off with --, so the picker keeps its search term" \
    || no "and its prompt is fenced off with --, so the picker keeps its search term" "$(cat "$TMP/launched" 2>&1)"

  # With a session id the option's value is already taken, so no fence is
  # needed — and adding one would be a second positional.
  rm -rf "$HOME/.claude/session-colors"; : > "$TMP/launched"
  launch --resume 2f3e0da6-6a8c-4270-8f41-b1843ce47d7e
  claimed=$(sed -n 's/^colour: //p' "$TMP/launched")
  grep -q "args: --resume 2f3e0da6-6a8c-4270-8f41-b1843ce47d7e /color $claimed" "$TMP/launched" \
    && ok "--resume <id> takes the prompt directly" || no "--resume <id> takes the prompt directly" "$(cat "$TMP/launched" 2>&1)"

  rm -rf "$HOME/.claude/session-colors"; : > "$TMP/launched"
  launch -c
  claimed=$(sed -n 's/^colour: //p' "$TMP/launched")
  grep -q "args: -c /color $claimed" "$TMP/launched" \
    && ok "so does --continue, which carries no value" || no "so does --continue, which carries no value" "$(cat "$TMP/launched" 2>&1)"

  # A positional argument is the user's prompt: one-shot, no prompt bar to colour.
  rm -rf "$HOME/.claude/session-colors"; : > "$TMP/launched"
  launch "summarise this repo"
  grep -q 'colour: none' "$TMP/launched" \
    && ok "a prompt on the command line claims nothing" || no "a prompt on the command line claims nothing" "$(cat "$TMP/launched" 2>&1)"
else
  ok "skipped the launcher's colour cases (no 'script' to make a pty)"
fi

# Piped output is not a session anyone is looking at.
rm -rf "$HOME/.claude/session-colors"; : > "$TMP/launched"
( cd "$proj" && "$LAUNCH" --model opus >/dev/null 2>&1 )
grep -q 'colour: none' "$TMP/launched" \
  && ok "nothing is claimed when stdout is not a terminal" || no "nothing is claimed when stdout is not a terminal" "$(cat "$TMP/launched" 2>&1)"

echo "installer"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"someone-elses-thing"}]}]}}\n' \
  > "$TMP/settings-seed.json"
export HOME="$TMP/home-install"; mkdir -p "$HOME/.claude"
cp "$TMP/settings-seed.json" "$HOME/.claude/settings.json"
S="$HOME/.claude/settings.json"

"$REPO/install.sh" --yes --no-alias >"$TMP/out" 2>&1 \
  && ok "installs" || no "installs" "$(tail -6 "$TMP/out")"
for f in statusline-project.sh session-identity.sh session-identity-end.sh; do
  [ -x "$HOME/.claude/hooks/$f" ] && ok "$f is installed" || no "$f is installed" "missing"
done
[ -x "$HOME/.claude/bin/claude-session" ] && ok "claude-session is installed" || no "claude-session is installed" "missing"
jq -e '.statusLine.command | contains("statusline-project")' "$S" >/dev/null \
  && ok "sets the status line" || no "sets the status line" "$(jq -c .statusLine "$S")"
for m in startup resume clear; do
  jq -e --arg m "$m" '.hooks.SessionStart | map(select(.matcher == $m)) | map(.hooks[].command)
                      | any(contains("session-identity.sh"))' "$S" >/dev/null \
    && ok "claims the colour on $m" || no "claims the colour on $m" "not registered"
done
jq -e '.hooks.SessionEnd | map(.hooks[].command) | any(contains("session-identity-end"))' "$S" >/dev/null \
  && ok "releases it on SessionEnd" || no "releases it on SessionEnd" "not registered"
grep -q "someone-elses-thing" "$S" && ok "leaves other packages' entries alone" || no "leaves other packages' entries alone" "removed them"

before=$(jq -S . "$S")
"$REPO/install.sh" --yes --no-alias >/dev/null 2>&1
[ "$before" = "$(jq -S . "$S")" ] && ok "installing twice changes nothing" || no "installing twice changes nothing" "settings drifted"
jq -e '[.hooks.SessionStart[].hooks[].command] | map(select(contains("session-identity"))) | length == 3' "$S" >/dev/null \
  && ok "and does not register itself twice" || no "and does not register itself twice" "duplicate entries"

# Someone else's status line is a thing you can only have one of, so replacing
# it is a decision — and the old value has to survive it.
jq '.statusLine = {type: "command", command: "~/somewhere/else.sh"}' "$S" > "$TMP/j" && mv "$TMP/j" "$S"
"$REPO/install.sh" --yes --no-alias >/dev/null 2>&1
[ -f "$S.pre-session-colour" ] \
  && ok "replacing another status line backs the old one up" || no "replacing another status line backs the old one up" "no backup written"

"$REPO/uninstall.sh" --yes >/dev/null 2>&1
grep -q "someone-elses-thing" "$S" && ok "uninstall spares other packages" || no "uninstall spares other packages" "removed them"
grep -q "session-identity\|statusline-project" "$S" \
  && no "uninstall removes its own entries" "still registered" || ok "uninstall removes its own entries"

echo "the release tarball is enough to install from"
# Whether the payload list in the release workflow is complete — the one thing
# a git checkout can never show, because every file is present either way. CI
# builds this with git archive at the tag; here it is the same file list taken
# out of the checkout.
payload_list=$(sed -n 's/^ *"\$TAG" -- //p' "$REPO/.github/workflows/release.yml")
[ -n "$payload_list" ] && ok "found the payload list in the workflow" || no "found the payload list in the workflow" "no git archive line"
mkdir -p "$TMP/tarball/session-colour"
( cd "$REPO" && tar -cf - $payload_list ) | ( cd "$TMP/tarball/session-colour" && tar -xf - )
export HOME="$TMP/home-tarball"; mkdir -p "$HOME/.claude"
cp "$TMP/settings-seed.json" "$HOME/.claude/settings.json"
"$TMP/tarball/session-colour/install.sh" --yes --no-alias >"$TMP/out" 2>&1 \
  && ok "a tarball install works" || no "a tarball install works" "$(tail -6 "$TMP/out")"
[ -x "$HOME/.claude/hooks/statusline-project.sh" ] && [ -x "$HOME/.claude/bin/claude-session" ] \
  && ok "and the hooks and launcher are there afterwards" || no "and the hooks and launcher are there afterwards" "missing"

echo "the suite itself"
# A test run must leave the checkout exactly as it found it. This is here
# because one of these suites did not: python's py_compile wrote a __pycache__
# directory into the source tree, which shows up as an untracked file long
# after anyone remembers running the tests.
after=$(find "$REPO" -path "$REPO/.git" -prune -o -print | sort)
[ "$REPO_SNAPSHOT" = "$after" ] \
  && ok "leaves nothing behind in the checkout" || no "leaves nothing behind in the checkout" "$(diff <(printf '%s\n' "$REPO_SNAPSHOT") <(printf '%s\n' "$after") | head -4)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
