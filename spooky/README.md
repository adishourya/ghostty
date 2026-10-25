# spooky

A minimal terminal multiplexer for Ghostty. Panes outlive their windows and
are resurrected after a reboot.

spooky does no rendering or layout. Each pane is a real Ghostty surface (tab or
split) running `spooky`, a thin proxy that passes bytes through unchanged. The
daemon owns the ptys, so what reaches Ghostty is exactly what the program
wrote: images, OSC sequences, synchronized output and so on.

```
ghostty tab/split ──pty──> spooky (proxy) ──unix socket──> spooky daemon ──pty──> shell / nvim
  layout, tabs              raw passthrough                 owns the ptys, plus one
                                                            libghostty-vt Terminal per
                                                            pane (replay + snapshots)
```

## Build

spooky links a prebuilt libghostty-vt, so working on spooky never rebuilds
Ghostty. Build the library once from the repo root:

```sh
zig build -Demit-lib-vt -Doptimize=ReleaseFast   # from the ghostty root
cd spooky
zig build                                        # warm rebuilds take about 1s
zig build test
```

Use the ReleaseFast library. A Debug libghostty-vt runs expensive integrity
checks and parses output far too slowly for a daemon.

For `spooky-integration`, also build Ghostty itself from the repo root. This
needs `blueprint-compiler` installed. The flags keep it from using every core
and all the memory:

```sh
nice -n 19 zig build -Doptimize=ReleaseFast -j4 --maxrss 8000000000
```

## Use

Add this to the Ghostty config so Ghostty works with spooky to keep track of
sessions:

```
spooky-integration = true
```

Ghostty windows start as plain shells. `spooky new NAME` turns the terminal
it runs in into a session, and new tabs and splits opened from a spooky pane
run spooky too, joining that session. Tabs and splits opened from a plain
shell stay plain.

`spooky-integration` needs a Ghostty built from this repo. Without it, set
`command = /path/to/spooky` so every tab and split is a spooky pane; sessions
are then grouped by the "active" session (the one you last typed in), and
window layouts can't be restored.

```sh
spooky ls                # sessions: state, tabs, panes, what's running
spooky ls -p             # every pane
spooky new [NAME]        # a new session, here (or in a new window inside one)
spooky attach NAME       # reopen a session's window, tabs and splits
spooky attach -p ID      # attach to one pane (steals it from another view)
spooky rename [OLD] NEW  # rename a session (default: the current pane's)
spooky rm NAME...        # delete sessions: end their panes and forget them
spooky restart-server    # save everything and restart the daemon, e.g. to upgrade
spooky kill-server       # stop everything and forget saved state
```

**Sessions are windows.** Each session is shown in one Ghostty window. A
session started without a name gets the next free number (`1`, `2`, ...)
until you `rename` it. Ghostty reports its layout to the daemon whenever it
changes, so `spooky attach work` (also after a reboot) reopens the window
with the same tabs and splits, at the same ratios. Attaching to a session
that is already open brings its window to the front.

**Closing:** closing a split or a tab ends its panes. Closing a whole window,
or quitting Ghostty, only detaches the session. `spooky rm NAME` ends all of
a session's panes, closing its window, and forgets it, so it doesn't come
back after a reboot either.

Inside a spooky pane, `new` and `attach` never nest; they open a new window.
A bare `spooky` inside a pane is refused.

## Resurrection

Every 2 seconds the daemon records each pane's working directory and
foreground program (read from `/proc`), and at most every 10 seconds it saves
a libghostty-vt snapshot of the screen and scrollback. All of this goes to
`$XDG_STATE_HOME/spooky` (default `~/.local/state/spooky`). It also saves
everything on SIGTERM, which is what a clean shutdown sends.

When the daemon next starts (on the first `spooky` command after a reboot,
e.g. `spooky ls` or `spooky attach NAME`), every pane comes back with a fresh shell in its
old directory, its old scrollback, and, if a program was running, a prompt:

```
 ⏎ Enter: resume nvim src/main.zig   Esc: shell
```

Enter types the command into the new shell, so it also ends up in history.
Esc dismisses the prompt. Any other key dismisses it and goes to the shell.

Shells killed during shutdown slightly before the daemon (within 5s) are
kept rather than forgotten. Panes killed by a signal are always kept.

## Design notes

- **Hot path**: read pty, write socket, nothing else. VT parsing is deferred
  until the pane has been quiet for 15ms, or done right away while detached
  (so terminal queries still get answers). On `seq 1 3000000`, spooky
  matches a bare pty: about 28 vs 30 MB/s.
- **Backpressure**: if a client falls 4MB behind, the daemon stops reading
  the pane, just as a slow terminal would.
- **Single threaded** poll loop: no locks.

## Not yet

- A tab bar listing sessions.
- Ghostty shell integration isn't injected, because Ghostty starts spooky
  rather than the shell. OSC 7 from your own shell config still works.
- Linux only so far (`/proc` for foreground detection).
