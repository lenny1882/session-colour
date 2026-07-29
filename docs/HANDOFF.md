# Handoff — per-folder session colouring & identity in Claude Code

**Date:** 2026-07-27 (revised same day: prompt bar solved via launcher alias; palette table corrected; `/clear` behaviour documented) · **2026-07-28: status line redesign** — powerline styling, usage meters, width budget, `/rc` badge (see that section)
**Claude Code version investigated:** 2.1.220 (`/home/james/.local/share/claude/versions/2.1.220`)
**Environment:** GNOME Terminal, VTE 6003, `COLORTERM=truecolor`, no tmux, Linux

---

## Goal

Tell at a glance which project a terminal session belongs to, with several sessions open at once.

## Outcome

**Working:** a custom status line under the prompt bar showing `▍project  branch  model`, coloured per folder. All sessions in the same folder share one colour; a new folder takes the next unused one.

**Also working (added 2026-07-27):** the *prompt bar* colour itself, via a launcher alias rather than a hook. No hook mechanism reaches `/color` — that part of the original finding stands — but the positional `prompt` argument does. See "Prompt bar" below.

---

## Installed files

| Path | Role |
|---|---|
| `~/.claude/hooks/statusline-project.sh` | Status line renderer. Reads session JSON on stdin, prints one line. |
| `~/.claude/hooks/session-identity.sh` | `SessionStart` (matchers `startup`, `resume`, `clear`). Allocates a colour per folder. Silent — emits no stdout. |
| `~/.claude/hooks/session-identity-end.sh` | `SessionEnd`. Reference-counted release. |
| `~/.claude/session-colors/` | Runtime registry. Created on first session start. |
| `~/.claude/bin/claude-session` | Launcher wrapper. Claims the colour, then `exec`s claude with `/color <name>`. Needs `alias claude='$HOME/.claude/bin/claude-session'`. |

Reference copies live in this folder: `claude-session` and `statusline-project.sh`
(the latter as installed on 2026-07-28), plus `tools/` for the preview scripts.

`~/.claude/settings.json` gained a top-level `statusLine` key plus `SessionStart`/`SessionEnd` entries. Pre-existing `PreToolUse`, `Notification`, `Stop` hooks were left untouched.

### Registry format

One file per claimed colour, named for the colour:

```
~/.claude/session-colors/red
    dir=/home/james/claude-sandbox
    308167 2f3e0da6-6a8c-4270-8f41-b1843ce47d7e
    309442 8b1c4e77-...
```

Line 1 is the owning folder; each subsequent line is `<pid> <session_id>` for a live session in it. All read-modify-write happens under a `mkdir` lock (`~/.claude/session-colors/.lock`) with a 5-second steal for a holder that died mid-write.

Allocation is dynamic, **not** a hash of the path. Folders are guaranteed distinct colours until all eight are held; the trade-off is that a folder's colour is not stable across restarts.

---

## Verified behaviour

Tested against isolated `HOME` directories, not the live registry:

- 2nd and 3rd session in a folder → same colour as the 1st
- Session in a new folder → next unused colour
- 8 simultaneous starts in one folder → all converged on one colour, one registry entry, lock cleaned up
- Ending all but one session in a folder → colour retained
- Ending the last → colour released and reclaimable
- 9th distinct folder → no colour, exits 0
- 2nd session in an existing folder while all 8 are held → still joins
- Status line matches the folder's colour; unregistered folder renders uncoloured

Added 2026-07-27, for the wrapper:

- Wrapper + patched hook, 3 concurrent sessions over 2 folders → one registry line per session, real session ids, no `pending` residue, both projA sessions on red
- Hook invoked *without* the wrapper → allocates exactly as before (regression check)
- Skip matrix: colours on bare `claude`, `--effort high`, `--model opus`, `--effort=high`, `--verbose`; skips on `-p`, `--resume`, `-c`, a bare prompt, `--effort high "fix it"`, `--add-dir /tmp`, `-w feat`, `--`
- All eight status line colours diffed against the bundle's dark table — 8/8 match

Also confirmed live: `CLAUDE_PID` **is** exported to hook processes and points at the real `claude` process (verified by walking `/proc` ancestors from inside a hook).

---

## Prompt bar: what works, and what doesn't

**Works — the positional prompt argument.** In an interactive session Claude Code submits `[prompt]` as the first turn, and `/color` is a local command, so it runs with no API call:

```
$ claude '/color red'
❯ /color red
  ⎿  Session color set to: red        # box turns rgb(220,38,38)
```

`~/.claude/bin/claude-session` wraps this: it claims the folder's colour against the same registry and lock, exports `CLAUDE_SESSION_COLOUR`, then `exec`s the real binary with `/color <name>` appended. Because it `exec`s, `$$` becomes the claude process, so the registry's `kill -0` liveness check is unaffected. Install is `alias claude='$HOME/.claude/bin/claude-session'` — aliases don't apply to non-interactive shells, so scripts, cron, and tooling that call `claude` directly are untouched.

Costs and limits:

- **The prompt slot is single-use.** Passing your own prompt means no colour; the wrapper detects this and skips rather than swallowing it.
- Telling a positional prompt from an option's *value* needs the option table, so the wrapper carries three lists derived from `claude --help`. Every ambiguity resolves towards *not* colouring.
- Skipped for `-p/--print` (no prompt bar) and for `--resume`/`--continue`/`--fork-session`, which restore the session's own `agentColor` from the transcript.
- `/color` shows as a first turn in the transcript. Cosmetic.
- **Still capped at eight**, because `/color` accepts only the eight names and no hex.

`session-identity.sh` was patched to honour `CLAUDE_SESSION_COLOUR` instead of allocating a second time, and to replace the wrapper's `<pid> pending` placeholder rather than appending beside it (same pid, since `$$` survives the `exec`). Started without the wrapper, it allocates exactly as before — verified.

## Dead end: `initialUserMessage`

`SessionStart` hook output accepts `initialUserMessage`. Tracing it: stashed in a module-level var, taken once by `ynd()`, passed to `prependUserMessage()` — the same function Claude Code uses internally to inject `/workflow-launch-exec`.

- **Headless (`claude -p`): works.** Transcript contained both `"content":"/color red"` and `"type":"agent-color","agentColor":"red"`. The `agent-color` record is only written by the command's handler, so the slash command genuinely executed.
- **Interactive: silently ignored.** The transcript holds a `hook_success` attachment with our JSON intact in `stdout` and `exitCode: 0` — and no resulting user message, no `agent-color` record.

`initialUserMessage` is consumed only on the print/SDK path. There is no hook field that reaches the prompt bar colour. The hook documents this in-line and exits silently.

**Re-verified 2026-07-27 against 2.1.220.** Every occurrence of `initialUserMessage` in the bundle forms one unbranched chain — zod schema → parser → generator `yield` → `P0s` module var → `ynd()`, the only reader → **one** call site, inside the function containing `dM("runHeadless_entry")`. No second consumer exists. Interactively the value is parsed, validated, counted for telemetry, and dropped.

Also confirmed by a pty session where the hook demonstrably fired (marker file) and the box stayed `promptBorder` grey `rgb(136,136,136)`, against a control in the same setup where `/color red` typed by hand turned it red. The failure is total, not partial: `/color` itself works fine when the message *does* get injected, so no variation on the hook's output rescues it.

**Superseded by** the wrapper above, which reaches the prompt bar without the hook system.

---

## Key facts extracted from the 2.1.220 bundle

- **`/color`** — "Set the prompt bar color for this session". Accepts only `red, blue, green, yellow, purple, orange, pink, cyan`, plus `default`/`reset`/`none`/`gray`/`grey`. **No hex.** Bare `/color` picks at **random**, not an unused colour.
- **`SessionStart` hook output schema:** `additionalContext`, `initialUserMessage`, `sessionTitle`, `watchPaths`, `reloadSkills`. Nothing colour-related.
- **`sessionTitle`** works and also drives the terminal tab title (setting `terminalTitleFromRename`, default `true`). **Rejected deliberately:** Claude Code stores `custom-title` and `ai-title` separately and resolves them `custom ?? ai`, so setting it on every start permanently shadows the auto-generated topic titles — every session in a project would show the same name in `/resume`.
- **`statusLine`** — `{type: "command", command: "..."}`. Receives rich JSON on stdin (`workspace`, `git_worktree`, `context_window`, `agent`, `pr`, `cost`, …). Must live in **user** settings; it is in the group of command-executing keys ignored in project-level `.claude/settings.json`. Unavailable in safe mode. `/statusline` configures it interactively.
- **Hook stdout is captured**, not written to the terminal. Escape sequences must go to `/dev/tty`.
- **`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`** stops Claude Code overwriting the tab title. Not currently used.
- **OSC 11** (`\033]11;#rrggbb\007`) does set the background in this VTE build — confirmed by the user. OSC 111 resets it. Not currently used; the earlier whole-window-tint approach was superseded.
- **RGB for the eight `/color` names** (used by the status line to match). The bundle stores them as `<name>_FOR_SUBAGENTS_ONLY`, which is what `/color` actually sets. There are **four** rgb palettes, not three, plus the ANSI-only themes. Classified by `text`/`success`:

  | theme | red | blue | green | yellow | purple | orange | pink | cyan |
  |---|---|---|---|---|---|---|---|---|
  | **dark** *and* **light** | `220,38,38` | `106,155,204` | `22,163,74` | `202,138,4` | `130,125,189` | `217,119,87` | `196,102,134` | `8,145,178` |
  | dark-daltonized | `255,102,102` | `102,178,255` | `102,255,102` | `255,255,102` | `178,102,255` | `255,178,102` | `255,153,204` | `102,204,204` |
  | light-daltonized | `204,0,0` | `0,102,204` | `0,204,0` | `255,204,0` | `128,0,128` | `255,128,0` | `255,102,178` | `0,178,178` |

  `dark` and `light` define **identical** values for all eight, so one table serves `theme: auto` whichever way it resolves. Only the colorblind-friendly variants diverge.

  **Corrected 2026-07-27.** An earlier version of this table listed the dark-daltonized row under the heading "Dark-theme RGB". The status line shipped with those values, so its red was `255,102,102` while the prompt bar rendered `220,38,38`. Confirmed empirically: a pty session on `theme: dark` with `/color red` typed by hand draws the prompt box in `rgb(220,38,38)`. The script now carries the correct row, with the daltonized set kept alongside as `RGB_DALTONIZED` for a one-word switch. `MODE=ansi` remains the escape hatch.

---

## Open item — now closed

The earlier note here proposed widening the palette past eight, on the grounds that the status line was the sole consumer and takes arbitrary 24-bit hex. **That no longer holds.** The prompt bar is a consumer again, and `/color` accepts only the eight names — no hex. Widening would desynchronise the two: folders nine and up would get a status line colour with a default-coloured prompt bar.

Eight is now a real ceiling, not a leftover. Raising it would mean dropping the prompt bar again, or finding a route to the prompt bar that isn't `/color`.

---

## `/clear` — added 2026-07-27, verified against 2.1.220

`/clear` drops the prompt bar colour, and also releases the folder's registry claim.

**The prompt bar.** The clear handler calls the session-metadata reset — the same
function that nulls `currentSessionTitle`, `currentSessionAgentName` and
`currentSessionAgentColor` — then mints a new conversation id. It deliberately
re-saves the session's *name* onto the new id; the colour is simply not carried.
An upstream omission, not a gap in this setup. Confirmed in a pty: after
`/color blue` the box draws `38;2;106;155;204`; after `/clear` it is back to
`promptBorder` `38;2;136;136;136`.

**The registry, which is the part that bites.** `/clear` fires **`SessionEnd`
with reason `clear`**, at the top of the clear handler. `session-identity-end.sh`
is registered with no matcher, so it runs and drops this session's line. A folder
whose only session was cleared loses its colour file outright — and the colour
becomes free for another folder to claim. `SessionStart` then fires with source
`clear`, but `session-identity.sh` is registered `matcher: "startup"`, so nothing
re-claims it.

Verified: a wrapper-launched session in a fresh folder held
`blue: dir=…/ptyproj2 | <pid> <sid>`; immediately after `/clear` only `red`
remained. The status line keeps rendering the old colour for a moment — that
frame is a cached redraw — and goes uncoloured on its next real refresh.

With two or more sessions in the folder it degrades gracefully: only the cleared
session's line is dropped, the folder keeps its colour, and the cleared session's
status line still matches on `dir=`.

The full reason list is `["clear", "resume", "logout", "prompt_input_exit",
"other", "bypass_permissions_disabled"]`, so **`/resume` releases the claim the
same way** (reason `resume`, fired when switching sessions in-process).

*Fix considered, not applied:* add `{"matcher": "clear"}` alongside `startup` for
`session-identity.sh`. The wrapper's `CLAUDE_SESSION_COLOUR` is still in the
process environment, so the hook would re-claim the same name — including one
that another folder may have taken in the meantime, so the re-claim would need to
fall back to `$found` or a fresh allocation when that name now belongs to a
different `dir=`.

**Applied 2026-07-28** — see "Re-claiming after resume and clear" below. The
`resume` half of this is what actually bit in practice.

## Re-claiming after resume and clear — added 2026-07-28

The gap above showed up live: session `7fc58427` was resumed at 19:53:29Z and ran
for two minutes with a **red prompt bar and a green status line**. That green is
not session-green (`22;163;74`); it is `PL_PROJECT`'s unregistered-folder default
`46;125;50`, which is what the status line draws when no registry file names this
folder. The prompt bar was unaffected because it never consults the registry —
Claude Code restores `agentColor` from line 1 of the transcript.

Three separate pieces had to line up, all of them by design:

1. `SessionEnd` carries no matcher, so it fires on reason `resume` and releases
   the claim — deleting the file outright when that was the folder's last session.
2. `claude-session` lists `--resume`/`-c`/`--fork-session` in `DISQUALIFY`, so no
   `CLAUDE_SESSION_COLOUR` and no `pending` line.
3. `session-identity.sh` was `matcher: "startup"` only.

It appeared to fix itself when a permission prompt came up. It didn't: a *second*
session started in the same folder 20 seconds earlier and re-claimed `red`, and
the status line matches on `dir=` rather than on session id, so the resumed
session inherited the claim on its next redraw. That the colour came back as red
was luck — `red` is first in `PALETTE` and had just been freed.

**The fix.** `session-identity.sh` is now registered for `resume` and `clear` as
well as `startup`, and picks its colour by a four-rung ladder:

| | Rung | Notes |
|---|---|---|
| 1 | `CLAUDE_SESSION_COLOUR` | The wrapper's choice. **Skipped on `resume`** — the variable survives in the environment but names the colour the *process* launched with, and an in-process `/resume` has already replaced the prompt bar with the incoming session's own colour. Honouring it would re-claim the colour of the session just left. Checked against `owner[]`, not trusted, since on `clear` another folder may have taken it. |
| 2 | `$found` | The colour this folder already holds. Folder identity outranks anything one session would prefer for itself. |
| 3 | The transcript's last `agent-color` record | The rung that makes resume correct: it re-claims the exact colour the prompt bar just restored, so the two agree by construction rather than by luck. Read from `transcript_path` (present in the input builder shared by every hook, with a path derived from cwd+sid as a fallback). Records are line-anchored and rewritten on every session-state save, so `grep -a '^{"type":"agent-color"' | tail -1` is both the live value and immune to the same string quoted inside a tool result. |
| 4 | First unheld colour | As before. |

Rungs 1 and 3 both go through `reusable()`: a colour is takeable only if no file
exists for it *after* the dead-session sweep, or the surviving file's `dir=` is
this folder. Nothing is ever stolen from a live folder.

**Residual limit.** If the folder already holds a colour via another live session,
rung 2 wins and a resumed prompt bar can still disagree with the status line.
That is unavoidable while `/color` is unreachable after launch — the alternative
would be two colours for one folder, which defeats the point.

Tested in isolated `HOME`s, 15 assertions, all passing: startup regression;
wrapper hint; resume re-claiming the transcript colour over an earlier one;
derived transcript path when `transcript_path` is absent; resume joining the
folder's live claim in preference to the transcript; refusing a transcript colour
held by another folder; taking one held only by a dead session; the `clear` env
hint honoured, and rejected when stale; a non-palette `agentColor` rejected; all
eight held → no colour and no theft; two resumes leaving one registry line;
silence on every path; and a stale `CLAUDE_SESSION_COLOUR` on resume losing to
the restored colour. Suite is not kept — it is reproducible from this list.

### Routes to restoring the prompt bar colour

- **Hooks: still no.** `SessionStart` does fire with source `clear`, but
  `initialUserMessage` is consumed only on the headless path — the same dead end
  documented above for `startup`.
- **Keybindings: no.** A binding's action may be `command:<name>`, which submits
  the literal text `/<name>`. The validator rejects spaces
  (`/^command:[a-zA-Z0-9:\-_]+$/`), so `/color red` cannot be bound, and bare
  `/color` picks a colour **at random**.
- **Agent definition `color:`: yes.** Verified with `--agent colourtest` on a
  definition carrying `color: green`: the box draws `38;2;22;163;74` at launch
  and *still* draws it after `/clear`, with no grey repaint anywhere in the
  capture. It resolves from `agentDefinitions.activeAgents[state.agent].color` in
  app state, which the clear path never touches. Costs: the main thread then runs
  as that agent definition (its prompt, tools and model settings apply — not
  characterised), and the agent name appears as a badge inset in the top rule.
  Still capped at eight. **Not adopted** — kept here as the one mechanism known
  to survive `/clear`.

### Exit paths compared

| | `/clear` | `Ctrl-D` | `exit` typed at the prompt |
|---|---|---|---|
| Process | survives | exits | exits |
| Confirmation | none | second press, within about a second — a 2s gap leaves the session running | none, immediate |
| API call | no | no | no — `exit`, `quit`, `:q`, `:q!`, `:wq`, `:wq!` are matched before dispatch |
| `SessionEnd` reason | `clear` | `prompt_input_exit` | `prompt_input_exit` |
| Then | `SessionStart` source `clear` | — | — |
| Registry line | dropped, then re-added by the `clear` matcher | dropped, colour released | dropped, colour released |
| Colour after | prompt bar grey, status line keeps the folder colour | re-claimed on relaunch | re-claimed on relaunch |

Restarting is therefore still the only way to get a clean context with the
*prompt bar* colour: the `clear` matcher re-claims the registry entry, so the
status line survives `/clear`, but nothing re-runs `/color`, and only a relaunch
goes back through the wrapper.
What a restart costs over `/clear` is startup time — settings, `CLAUDE.md`,
plugins and skills re-read, MCP servers reconnected — where `/clear` keeps all of
that live in the same process.

## Status line redesign — added 2026-07-28, against 2.1.220

The status line grew from `▍project  branch  model` into a powerline bar modelled
on the `PS1` in `/mnt/sda/User/.bashrc_custom`, and gained usage meters. It now
renders:

```
 project ▶ branch                    Opus 5 (167.9k / 1M)   21% 21:44 | 15% Sat 11:01
```

Left group: the folder block in the session colour, then — in a repo — the git
block. Right group: free-standing rectangles flushed to the terminal edge, styled
like that prompt's `$HISTCMD` counter (grey `#333` background, light grey text,
one column of gap).

### Payload fields consumed

`context_window.total_input_tokens` / `.context_window_size` / `.used_percentage`,
and `rate_limits.five_hour` / `.seven_day`, each `.used_percentage` and
`.resets_at`. `rate_limits` is **absent entirely** until a response carrying the
limit headers has landed, and `context_window` is null before the first API
response, so every read tolerates `-`. `resets_at` can also be `0`; that formats
as `now` rather than being run through `date`, which would otherwise print a
plausible-looking future time.

`total_input_tokens` is input + cache_creation + cache_read — the same numerator
behind `used_percentage`. The percentage is still read, purely to pick a colour.

`model.display_name` carries the window size for long-context variants
(`"Opus 5 (1M context)"`), so that suffix is stripped before the token pair is
appended — otherwise the label reads `Opus 5 (1M context) (167.9k / 1M)`.

### Width budget

Two separate constants, near the bottom of the script:

- **`LAYOUT_INSET=3`** — Ink truncates against the footer box's own layout width,
  not `COLUMNS`. Measured by bracketing on a 119-column terminal: 116 characters
  render whole, 117 loses its tail. `COLUMNS` itself *is* exported to the status
  line command and tracks the real terminal — verified with a probe injected into
  the live hook — so the shortfall is the box, not a stale width.
- **`INDICATOR_RESERVE=4`** — see below.

Because the line pads itself to the full available width (that is how the right
group flushes to the edge), it is always exactly as wide as it is allowed to be.

### Footer layout, and the `/rc` badge

The footer is one wrapping flex row:

```js
<Box width={columns} flexDirection="row" flexWrap="wrap"
     alignItems="flex-start" paddingLeft={2} paddingRight={2} columnGap={1}>
  {left}   // column: [ status line, hint line (mode, agents, …) ]
  {right}  // column: [ notifications, badges ]  — marginLeft:"auto", flexShrink:0
</Box>
```

The badge column holds `/rc`, IDE, debug, PR and mode labels, joined by ` · `.
Consequences:

- A full-width status line **evicts the badge column onto its own line**, because
  of `flexWrap: "wrap"`. `INDICATOR_RESERVE=4` — 3 for the short `/rc` plus the
  parent's `columnGap` — keeps it on row 1.
- The badge has two forms. `/rc active` (10 wide) shows until the
  `rc-active-badge` counter in settings reaches **5** sessions, then it shortens
  to `/rc`. Covering the long form needs `INDICATOR_RESERVE=11`.
- The reservation is fixed, not conditional: nothing in the status line payload
  reports whether remote control is on. When the badges are absent it simply
  holds the right-hand blocks 4 columns off the edge.
- **Putting the badge beside the hint line is not possible.** `alignItems:
  "flex-start"` top-aligns the badge column with the status line. It is hard-coded
  JSX, and the `statusLine` settings schema offers only `type`, `command`,
  `padding`, `refreshInterval`, `hideVimModeIndicator` — no placement control.

Also from the bundle: the status line box is `<Box paddingX={padding ?? 0}
gap={2}>` with `wrap="truncate"`, and a **multi-line** status line is supported —
the text is split on `\n` and rendered as a column.

### Colour decisions

- **Folder block** — the session colour, bold, always **white** text. An earlier
  version chose black or white by WCAG contrast ratio, which flipped exactly one
  colour (blue `106;155;204`, the only one where white misses AA 4.5:1) to black.
  Bold weight carries that case, and uniform white matches the prompt. The helper
  was removed rather than left unused.
- **Git block** — blue `#2d77ce`, matching `git_info()` in `.bashrc_custom`.
  Chosen over the neutral grey after previewing all eight session colours against
  both: blue is better in six of eight, equal in green and yellow, and worse only
  against session blue and cyan, where it is the same hue family and the
  folder/branch boundary softens. `PL_GIT_ALT` (`#4e6b1f`, hue 83°) is kept in the
  script as the widest-clearance fixed colour — no colour clears all eight, and
  42° is the best any single one can do.
- **The branch glyph replaces the arrow**, it does not follow one. `git_info()`
  emits `separator branch` with no `blockright`, so the U+E0A0 glyph is drawn in
  the git block's own colours where the separator would be.
- **Meters** stay grey until 60% (amber `#ffb300`) and 85% (red `#ff5252`).
  Lightened off the `.bashrc_custom` red/amber, which are too dark to read on
  `#333`.

The six chromatic colours in `.bashrc_custom`, for reference: blue `#2d77ce`,
green `#2e7d32`, purple `#7b1fa2`, red `#d32f2f`, light green `#00ff00`
(`man` only), teal `#1f88a2` (`man` only). Everything else there is grey.

### Previewing

`tools/preview-statusline.sh` renders combinations that would otherwise need a
live session in the right folder, on the right branch, holding the right registry
claim. It patches three lines of the **installed** script in a temp copy — the
registry lookup, the `git rev-parse`, and `GIT_BG` — so a preview cannot drift
from what the terminal draws, and it fails loudly if those lines change shape.

```bash
cd session-colour/tools
./preview-statusline.sh --palette | ./ansi2svg.py > palette.svg     # 8 colours, ± git
./preview-statusline.sh --git-colours | ./ansi2svg.py > git.svg     # 8 × 6 git blocks
```

`ansi2svg.py` handles only what the status line emits: SGR 0, `38;2;r;g;b`,
`48;2;r;g;b`, bold and dim. Written because PIL was unavailable.

### Gotchas hit

- `~/.claude/hooks` is on the sandbox deny list; writes there need the sandbox
  disabled. **`TMPDIR` is only set inside the sandbox**, so a build run outside it
  silently resolved `"$TMPDIR/head.sh"` to `/head.sh` and produced a script
  missing its first 124 lines. `bash -n` passed — the remainder is valid on its
  own — and the result rendered a plausible, almost entirely blank line. Verify a
  rebuild by line count and by grepping for a known head-only marker
  (`declare -A RGB=`), not by syntax check alone.
- Powerline glyphs written as `SEP='<literal>'` were silently stripped on file
  write, leaving an empty string and a line one column short. Use `$''`.
- Tab is IFS whitespace, so `\t\t` collapses and empty fields vanish when
  splitting packed records. The segment arrays use `\x1f`.

### Backups

`statusline-project.sh.bak-prepowerline` (the last pre-redesign version) and
`.bak-20260728-prereserve` (immediately before the width reservation), alongside
the 2026-07-27 pair. Intermediate same-day backups were removed.

---

## Testing

Open one new terminal in a folder no current session uses. The prompt bar should come up already coloured, with the status line matching. Existing sessions are unaffected and hold no registry entry — they predate the install, so they stay uncoloured until restarted, and the alias only applies to shells opened after it was added.

Non-invasive headless check of the SessionStart hook:

```bash
mkdir -p /tmp/ct && (cd /tmp/ct && claude -p "hi") >/dev/null 2>&1
cat ~/.claude/session-colors/* 2>/dev/null
```

## Uninstall

Remove the alias from your shell rc, delete the four scripts (`statusline-project.sh`, `session-identity.sh`, `session-identity-end.sh`, `bin/claude-session`), delete `~/.claude/session-colors/`, and drop the `statusLine` key plus the `SessionStart`/`SessionEnd` blocks from `~/.claude/settings.json`.

Backups from the 2026-07-27 changes: `session-identity.sh.bak-20260727`, `statusline-project.sh.bak-20260727`.
