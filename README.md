# session-colour

Tells you at a glance which project a Claude Code terminal belongs to, when you
have several open at once.

Every session in a folder gets the same colour. A new folder takes the next
unused one. The colour shows in two places: the prompt bar around the input box,
and a custom status line drawn underneath it.

```
▍claude-sandbox ▶ main                    Opus 5 | 167.9k / 1M
                                     🕐 21% (14:30)   📅 15% (Sat 11:01)
```

The status line also carries what the session is running on and how much of your
context and rate limits you have used, on two rows.

There are eight colours, because that is how many `/color` accepts. A ninth
folder gets no colour rather than a duplicate one.

---

## What's in the box

| Path | What it is |
|---|---|
| `hooks/statusline-project.sh` | The status line. Reads session JSON on stdin, prints one or two rows. |
| `hooks/session-identity.sh` | `SessionStart` hook. Claims the folder's colour. Silent. |
| `hooks/session-identity-end.sh` | `SessionEnd` hook. Releases it when the last session in the folder exits. |
| `bin/claude-session` | Launcher wrapper. Colours the prompt bar. Used through a shell alias. |
| `lib/update-check.sh` | Daily check for a new release. |
| `tools/preview-statusline.sh` | Renders the status line for colour and branch combinations without needing a live session. |
| `tools/ansi2svg.py` | Turns that preview into an SVG. |
| `docs/HANDOFF.md` | How all of this was worked out, and what didn't work. Worth reading before changing anything. |

## Entry points

Three of these you never call yourself — Claude Code calls them.

**`bin/claude-session`** is the exception. It is the launcher, and you use it
through an alias:

```bash
alias claude='$HOME/.claude/bin/claude-session'
```

After that, `claude` works exactly as before. The wrapper claims the folder's
colour, then hands off to the real binary with `/color <name>` as the opening
prompt — the only route to the prompt bar colour that works in an interactive
session. It steps aside whenever colouring would cost you something: if you pass
your own prompt, or use `-p`, `--resume`, `--continue` or `--fork-session`, it
runs the real binary unchanged. Aliases don't apply to non-interactive shells,
so scripts, cron jobs and other tooling that call `claude` are unaffected.

**`lib/update-check.sh`** you can call directly to see where you stand:

```bash
~/.local/share/session-colour/update-check.sh status
```

**`tools/preview-statusline.sh`** is for working on the status line itself:

```bash
cd tools
./preview-statusline.sh --palette     | ./ansi2svg.py > palette.svg   # all 8 colours
./preview-statusline.sh --git-colours | ./ansi2svg.py > git.svg       # 8 × 6 git blocks
```

It patches the *installed* script in a temporary copy, so a preview cannot drift
from what your terminal actually draws, and it fails loudly if the lines it
patches change shape.

## Installing

```bash
git clone <url> session-colour
cd session-colour
./install.sh
```

It copies the four scripts into `~/.claude/` and merges the `statusLine` key and
the `SessionStart`/`SessionEnd` hooks into `~/.claude/settings.json` with `jq`.
Everything inside `~/.claude` it does without asking.

**The shell alias is a manual step.** It's the one thing that lives outside
`~/.claude`, in a shell startup file the installer usually can't write — often
one sourced from a read-only mount or a dotfiles repo. So it prints the line,
waits while you add it, and then checks whether it took:

```
== Prompt bar alias

  MANUAL STEP — the prompt bar colour needs a shell alias.

  Add this line to your shell startup file:

      alias claude='$HOME/.claude/bin/claude-session'

  Either form works — $HOME or the full path — as long as it points at
  /home/you/.claude/bin/claude-session.

  None of your shell startup files are writable by this script, so it
  has to be done by hand. Files it looked at:
      /home/you/.bashrc
      /home/you/.profile
      ...

  Then open a NEW terminal — the current one has already read its config.

  Add the line, then press Enter to re-check (or s to skip):
```

Press Enter and it re-checks. When it finds it, it says where it's defined and
moves on. `s` skips — the status line still works, the prompt bar just stays
grey. If one of your startup files *is* writable, it offers to append the line
for you instead.

The check asks an interactive shell what `claude` actually resolves to, rather
than grepping a guessed list of files. So it finds the alias wherever you keep
it — including files sourced two levels deep from your rc — and no path to your
config is written down anywhere. The list above is only for reporting, and is
built by following the `source` lines in your own startup files. The final
summary reports whether the alias is active, so a skipped step doesn't go quiet.

| Option | Effect |
|---|---|
| `--link` | Symlink instead of copy, so edits in the repo take effect immediately. |
| `--yes` | Assume yes to every prompt. Appends the alias if a startup file is writable; otherwise says it didn't and carries on. |
| `--no-alias` | Skip the alias entirely. Status line only, no prompt bar colour. |

With no terminal at all — CI, a pipe, a hook — nothing hangs: every question
declines and the alias step reports what to do by hand.

Re-running is safe, and is how you upgrade. Each step replaces what it wrote
last time; the settings merge strips this project's own hook entries by command
match before re-adding them, so nothing stacks up and nothing else is touched.

**Needs:** bash 4+, `jq`, `git`, and a terminal with 24-bit colour. A Nerd Font
is strongly recommended — the status line uses powerline separators and two
private-use glyphs, which show as boxes without one. The installer warns if it
can't find one.

**Afterwards:** open a *new* terminal in a folder no current session is using.
Sessions already running predate the install and stay uncoloured until they
restart. If Claude Code is open, `/hooks` forces a settings reload.

## Updating

A check runs once a day, in the background, when a session starts. It asks the
git remote which release tags exist and writes the answer to a state file. It
never fetches, never touches your working tree, and never installs anything.

When a newer release exists, the status line grows a badge:

```
▍claude-sandbox ▶ main        ↑ v1.2.0    Opus 5 | 167.9k / 1M
```

The badge sits at the left of the right-hand group and is never dropped to make
room, so it doesn't vanish on a narrow terminal.

To take the update:

```bash
cd session-colour
./update.sh
```

That fetches, works out the newest `vX.Y.Z` tag, moves to the matching
`release/vX.Y` branch, and re-runs the installer. It refuses to move if you have
uncommitted changes. `./update.sh --check` reports what is available and stops.

Nothing updates itself. The check only ever writes a state file.

## Uninstalling

```bash
./uninstall.sh
```

Removes the scripts, the settings keys, the colour registry and the update
state, asking before each destructive step. The shell alias it will not edit for
you — it searches your startup files and anything they source, then prints the
exact lines to delete and which file they're in, flagging any that are
read-only.

## How the colours are held

One file per claimed colour, in `~/.claude/session-colors/`:

```
~/.claude/session-colors/red
    dir=/home/you/projects/api-gateway
    308167 2f3e0da6-6a8c-4270-8f41-b1843ce47d7e
    309442 8b1c4e77-...
```

Line 1 is the owning folder. Each line after it is `<pid> <session_id>` for a
live session in that folder. Every read-modify-write happens under a `mkdir`
lock, with a five-second steal for a holder that died mid-write. Sessions whose
pid is gone are swept on the next start.

Allocation is dynamic, not a hash of the path. That guarantees eight distinct
folders get eight distinct colours; the trade is that a folder's colour is not
stable across restarts.

## Known limits

- **Eight colours, hard.** `/color` accepts eight names and no hex. A ninth
  folder gets no colour.
- **`/clear` drops the prompt bar colour.** It fires `SessionEnd`, then
  `SessionStart` with source `clear`. The hook re-claims the registry entry, so
  the status line survives — but nothing re-runs `/color`, so the box goes grey
  until you restart.
- **After `/resume`, the two can disagree.** If the folder already holds a
  colour through another live session, that colour wins for the status line
  while the prompt bar restores the resumed session's own. Unavoidable while
  `/color` is unreachable after launch.
- **`--resume`, `--continue`, `-p` and a positional prompt skip colouring.**
  Deliberate. Every ambiguity resolves towards not colouring, so the failure
  mode is a plain prompt bar, never a swallowed prompt.

`docs/HANDOFF.md` has the reasoning behind each of these, the routes that were
tried and rejected, and the layout arithmetic behind the status line's width
budget.
