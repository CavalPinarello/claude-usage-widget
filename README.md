# Headroom

Headroom (called Claude Usage until 2026-11-09) is a macOS menu bar widget for
two kinds of headroom: the RAM your Mac has left, and how much Claude quota you have left this week, and
in the **5-hour session** too on plans that still have one.

![menu bar](docs/menubar.png)

One meter for the week plus the percentage left. Plans with a 5-hour limit get a
second meter above it and two percentages (session, then week). Colour goes green → yellow → orange → red as you burn through, and the text only picks
up colour past 80% used, so it stays quiet when there's nothing to worry about.

Click it for the detail:

![panel](docs/panel.png)

A model with its own weekly cap (`Week · Fable` above) always gets a row, even
at zero. An extra-usage-credits row appears only if you have credits enabled.

## Week by model

The usage API reports a percentage only for models with their own cap, so the
**Week by model** section is an estimate from Claude Code's local logs. It totals
each model's tokens since the week began, weights them by API list price, and
shows each model's share. Read it as "where my Claude Code usage went", not as a
percentage of a limit: Anthropic doesn't publish how plan limits weigh tokens,
claude.ai chats and cloud sessions leave no local log, and Claude Code runs billed
to an API key are counted even though they don't touch your plan. Prices live at
the top of `bin/claude-usage-models` and need updating when Anthropic changes them.

To count other Macs on the same account, list them in
`~/.config/claude-usage/hosts`, one `Label ssh-target` per line. They need python3
and key-based ssh, and the panel says so if one can't be reached. The estimate runs
every 15 minutes and makes no API calls.

## Requirements

- macOS 13 or later
- Xcode command line tools (`xcode-select --install`) — you build it yourself
- Claude Code, logged in with a **subscription account** (Pro or Max)

It reads the OAuth login Claude Code already stores. If you drive Claude Code
with an `ANTHROPIC_API_KEY`, or through Bedrock/Vertex, there is no subscription
quota to report and the widget will say it found no login.

## Install

```sh
git clone <this repo> claude-usage-widget
cd claude-usage-widget
./build.sh
```

That compiles `~/Applications/Claude Usage.app`, ad-hoc signs it, and launches
it. Because you built it locally there is no Gatekeeper quarantine and no
"unidentified developer" dialog.

**Open at Login** is a toggle in the widget's own menu. It writes
`~/Library/LaunchAgents/com.claudeusage.widget.plist` and bootstraps it with
`launchctl` — no Developer ID needed.

To remove everything: `./uninstall.sh`

## Where the numbers come from

`GET https://api.anthropic.com/api/oauth/usage` — the same endpoint Claude Code's
own `/usage` command calls. So these are your real limits, not a token-count
estimate reconstructed from local transcripts.

The bearer token is your existing Claude Code OAuth token, read from the login
Keychain (item `Claude Code-credentials`) by shelling out to `/usr/bin/security`.
That binary already holds the ACL grant, so you never see a "wants to access your
keychain" prompt.

### On credentials

Worth knowing before you run something that touches your Keychain:

- It **reads** one Keychain item and never writes to it.
- It **never refreshes or rotates the token.** It could — the refresh token is
  right there — but rotating it would invalidate the copy Claude Code holds and
  can log you out of Claude Code. Instead the widget treats an expired token as a
  read failure: it keeps showing the last known good numbers with a banner, and
  recovers by itself the next time you run a Claude Code session (which refreshes
  the token roughly every 8 hours).
- The token goes to `api.anthropic.com` and nowhere else. There is no telemetry,
  no analytics, no config file, no network call other than the one above.

It is two Swift files, about 1,500 lines. Read them.

## Mac health

The widget also watches the Mac itself, because Claude Code can take it down.
On 2026-09-19 the `claude-mem` plugin's background worker had spawned one
headless summarizer per session for three days and never reaped any: 144
copies of `claude --output-format stream-json`, 8.5 GB resident, 57 of them
spinning, load average 88, swap full, free memory zero. A second leak was a
headless Chrome tree from screenshot automation, orphaned to launchd for 14
hours on a full core. The `MAC` section in the panel, and a coloured dot in the
menu bar, exist so that never sneaks up again.

### What it senses

Nothing is shelled out. Every 30 seconds (`health.pollSeconds`) a background
queue reads:

- **Memory**: `kern.memorystatus_level`, which is the exact number
  `memory_pressure` prints as "System-wide memory free percentage", plus
  free, wired and compressed pages from `host_statistics64` and swap from
  `vm.swapusage`.
- **Load**: `getloadavg`, shown per core (`hw.ncpu`).
- **Processes**: `proc_listpids` and `proc_pidinfo` / `proc_pidpath` for
  every process you own, then `proc_pid_rusage` and `KERN_PROCARGS2` only for
  the two executables that matter (the Claude Code binary under
  `~/.local/share/claude/versions/` or `~/.local/bin/claude`, and the Chrome
  main binary). This is what `ps` does internally, minus the fork and minus
  the argv of 700 processes nobody asked about. A full pass takes about 2 ms.

The kernel's memory-pressure notification (`DispatchSource.makeMemoryPressureSource`)
also triggers an immediate sample, so the widget reacts before the 30-second
tick when things go bad fast; a `.critical` event is treated as an emergency
for that run whatever the polled percentage says, and the panel's memory line
shows `kernel: critical` for that sample.

**Unknown never authorises a kill.** Every reading carries its own validity
(`validity` in `--health-json`). A sensor that fails is not a zero: the memory
row says "unavailable", the panel's Last action row says "inspection
incomplete", a warning reason "memory metric unavailable" is raised, and the
emergency mode (which shortens the summarizer age limit) cannot engage from a
metric that was not read.

### The two leaks it reaps

The fingerprints are the same ones `~/.local/bin/claude-hygiene hourly` uses,
so the two tools always agree on what is a leak:

| Leak | Fingerprint | Why it is safe to kill |
|---|---|---|
| claude-mem summarizer | **All** of: resolved executable under `~/.local/share/claude/versions/` or `~/.local/bin/claude` · argv[0] named `claude` (Claude Code re-execs itself as `ugrep`; those are not sessions) · `--output-format stream-json` · `--input-format stream-json` · no `-p`/`--print` (options are read up to the first bare `--`) · **and its current parent is the claude-mem worker**: the parent's executable ends in `/bun` and its argv contains `plugin/scripts/worker-service.cjs`. Age over **2 h** (`health.summarizerMaxAgeMin`), or over **10 min** (`health.emergencySummarizerAgeMin`) while the machine is in an emergency (kernel memory critical, load critical, 20+ summarizers piled up, or a kernel critical-pressure event). | It is a headless, tool-less Sonnet channel the claude-mem worker keeps open per session and forgets to close; killing one costs at most the memory summary it was in the middle of, and the worker opens a fresh one when it next needs it. Nothing you typed lives in it. `--output-format stream-json` is a public CLI mode, so the shape alone proves nothing: your own `claude -p --output-format stream-json` scripts, or a stream-json child of anything that is not the worker, are never touched. A ppid-1 leftover is not the widget's job either: the worker's own reaper already SIGKILLs any orphaned `claude … --output-format` process every 5 minutes. The 2-hour limit matches the `claude-hygiene hourly` bash tool; the 10-minute emergency limit is what keeps a thrashing Mac from needing a hard reboot. |
| orphaned headless Chrome | **All** of: resolved executable is exactly `…/Google Chrome.app/Contents/MacOS/Google Chrome` (helpers never match) · parent is launchd (pid 1) · an option starting with `--headless` · a `--user-data-dir=<path>` (or `--user-data-dir <path>`) that is absolute and, once standardised (`..` and `.` resolved), lies under `/tmp/`, `/private/tmp/`, `/var/folders/` or `/private/var/folders/`. Age over **60 min** (`health.chromeMaxAgeMin`). | Screenshot automation launches Chrome with a throwaway profile in a temp directory, and when the automation dies Chrome is left with launchd as its parent and nobody to talk to. A headless Chrome on a persistent profile, with a relative one, or with none, is somebody's deliberate daemon: it is counted (`headlessChromeIgnored` in `--health-json`) and never signalled. Of the main's children only real helpers (path containing `Google Chrome Helper` or `Google Chrome Framework.framework`) are signalled, each with its parent re-fingerprinted first; any other child is left alone and counted as `skipped`. |

**Interactive Claude Code sessions are never killed.** They match the same
binary but are not summarizer-shaped and carry no `-p`/`--print`; the widget
counts them, shows the oldest one's age, and leaves them alone. Nothing outside
those two fingerprints is ever signalled, and the widget never signals itself,
its parent, or the claude-mem worker. Before **every** signal (the `SIGTERM`,
and the `SIGKILL` of whatever is still there after a two-second grace) the
target is re-read: same owner, same start time to the microsecond, not a
zombie, readable at all (an unreadable pid is never assumed dead and never
signalled), and its *current* executable and argv still pass the exact
fingerprint above, including the parent check. A pid that no longer matches
is skipped silently and counted as `skipped`.

The numbers it reports are outcomes, not intentions: a process counts as
terminated only once it is confirmed gone (`ESRCH`, a zombie, or a recycled
pid) a moment after the escalation; `signalled` and `survived` are kept
alongside. The bytes are what those processes had resident when sampled, and
the widget says so ("2.1 GB was resident"), because macOS decides what comes
back and when.

Reaping runs on every poll that finds a stale target (when **Auto-reap Leaks**
is on, the default), immediately on a memory-pressure event, and on **Reap
Leaks Now** (⌘K) regardless of the toggle.

### Thresholds

The panel and the menu bar dot stay uncoloured while the machine is fine.

| Level | Any of |
|---|---|
| **warn** (yellow) | memory < 35% free · load > 2.0 per core · ≥ 5 stale summarizers · Claude stack > 4 GB resident · any orphaned headless Chrome past its age limit |
| **critical** (red) | memory < 15% free · swap > 6 GB with < 512 MB free · load > 4.0 per core · ≥ 20 stale summarizers |

Disk (added 2026-11-07) has its own row and its own colour: **warn** under
50 GB free, **critical** under 20 GB, measured with `statfs` on
`/System/Volumes/Data` the way `df` does (purgeable space not counted). Swap
files live on the same volume, so a nearly full disk is also a swap ceiling.
A full disk colours the menu bar but never counts as an emergency, because
killing summarizers frees no disk space.

A level is promoted only when the previous sample was already at that level
or worse *and* is at least 20 seconds old, so neither a single spike nor two
back-to-back queued samples can light the menu bar; demotion is immediate. The
last six samples are kept with their timestamps. Sampling runs on its own
dispatch queue (a `DispatchSourceTimer`, not a main-run-loop timer, so an open
menu never stalls it), and timer, menu-open, wake, pressure and manual requests
coalesce into at most one run in flight plus one queued.

### Notifications and the audit trail

After a reap that killed anything, a notification says what went:
"37 summarizers terminated · 2.1 GB was resident". If the level is critical and there was
nothing to reap, "Mac under pressure" names the top two reasons and how many
Claude sessions are open (with the oldest one's age once it passes a day), at
most once every 15 minutes. It never kills a session for you.

Every kill is one line in `~/.claude-mem/hygiene.log`, the same file the bash
tool writes, in the same shape:

```
[2026-09-19 09:33:12] widget: killed 37 stale claude-mem summarizer(s) (2150 MB) (pids 52692@1789838496.855666, …)
```

Each pid is recorded with its start time, so the line names exactly which
process went, not just how many. The file is opened `O_APPEND` and written
with `write(2)`, so it interleaves safely with the bash tool; a line that
cannot be written is dropped rather than crashing anything.

The panel's **Last action** row says only what is true: "auto-reap off ·
N suspected leaks" when there are targets it is not allowed to touch,
"inspection incomplete" when the memory metric could not be read, "N
terminated · X was resident · time" after a reap in this session, "N suspected
leaks" while a reap is pending, and "no leaks found · checked HH:MM" only when
the last check found nothing. The last reap is also persisted
(`health.lastReapJSON`).

### Menu items

- **Speed Up…** (⌘U): one dialog listing what can be done right now, as
  checkboxes. Nothing runs until you press **Speed Up**.
  - *Leaks* the reaper already knows about (ticked).
  - *Heavy jobs*: Xcode builds and tests (`xcodebuild`), booted iOS
    simulators and `ffmpeg` renders, each with its age, process count and
    CPU (never ticked: they belong to someone's work). A job is signalled
    (`SIGTERM`) only if the same pid still runs the same full command line;
    a simulator goes through `xcrun simctl shutdown`.
  - *Rebuildable caches* with their sizes, from a fixed list (uv, Codex,
    Playwright, Adobe Camera Raw, pip). Ticked only while the disk is low.
    uv is cleared with `uv cache clean`. Nothing outside that list is
    ever deleted; Xcode DeviceSupport and DerivedData are left out on purpose.
  Every action is logged to `~/.claude-mem/hygiene.log` as `widget: speed-up: …`,
  and a notification sums up what was done.
- **Reap Leaks Now** (⌘K): sample and reap, toggle or not.
- **Auto-reap Leaks**: the `health.autoReap` toggle.
- **Suspected Leaks…**: enabled only while there are targets; lists each one
  (pid, age, resident MB, owner) with a **Terminate** button that runs a
  manual reap, and **Cancel**.
- **Open Activity Monitor**: for when you want to see the rest.

### Staying up

The widget is also the leak reaper, so it must not stay down (on 2026-11-06
it was gone for 1h40 and 56 summarizers piled up). The LaunchAgent carries
`KeepAlive: {SuccessfulExit: false}` with a 30 s `ThrottleInterval`: launchd
brings it back after a crash, a signal or a memory kill (tested: `kill -9`,
back in 28 s), while **Quit** exits cleanly and stays quit. Older plists are
upgraded in place at launch and take effect at the next login or `build.sh`.
`build.sh` now boots the job out of launchd before building and bootstraps it
afterwards, so a rebuild never races an automatic relaunch.

### Opting out and tuning

```sh
defaults write com.claudeusage.widget health.autoReap -bool false       # sense, never kill
defaults write com.claudeusage.widget health.summarizerMaxAgeMin -int 120
defaults write com.claudeusage.widget health.emergencySummarizerAgeMin -int 10
defaults write com.claudeusage.widget health.chromeMaxAgeMin -int 60
defaults write com.claudeusage.widget health.pollSeconds -int 30
```

### Debug flags

```sh
"$HOME/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" --health-json     # one sample + assessment as JSON, timing on stderr
"$HOME/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" --reap-dry-run   # what a reap would kill, without killing
"$HOME/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" --notify-test    # one test notification through the reaper's path
"$HOME/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" --argv-selftest  # KERN_PROCARGS2 parser + fingerprint fixtures; non-zero exit on any failure
"$HOME/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" --speedup-dry-run                 # what Speed Up would offer now, cache sizes included
"$HOME/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" --speedup-snapshot out.png         # the dialog with synthetic rows, as a PNG (light only)
```

`--health-json` reports `level` after the hysteresis (it assesses the sample
twice, the first copy backdated past the promotion age, so the number you see
is the steady state) alongside `rawLevel`, `emergency` and `validity`, and
lists every process it classified with its first three arguments.
`--argv-selftest` runs the argv parser against malformed payloads (truncated,
missing terminator, argc larger than the payload, empty argument, bad UTF-8)
and the option scanner against `--` handling; the parser is a kill gate, so it
fails closed on anything it cannot read.

## Free Up Memory

The button under the MAC rows (also the menu, ⌘M) turns orange when memory is
under 35% free and red under 15%. One click clears the leaks the reaper already
owns, at any age while memory is low, then opens a window:

- **Before → Now**: memory free, swap and compressed, measured again after
  every action and on Recheck.
- **Claude Code sessions** with their MCP servers, by physical footprint, with
  folder, age, keyboard idle time and tmux session. Detached or 3 h idle
  sessions are marked suggested. Close kills the tmux pane, or sends SIGTERM.
- **Simulators** (Shut Down), **apps** over 300 MB (Quit, so they can ask to
  save; a terminal hosting sessions says so), **background processes** over
  800 MB started by launchd (Stop). Apps and background processes are never
  suggested.

A second click on a row that survived escalates to SIGKILL / force quit. Every
signal re-checks pid and start time first and is logged to
`~/.claude-mem/hygiene.log`. Debug: `--relief-dry-run`, `--relief-snapshot
out.png`, `--relief-window` (opens the live window at launch).

## Rate limiting

The usage endpoint sits behind a tight sliding-window limiter at the Cloudflare
edge, and the budget is **shared with Claude Code's own calls** to the same
endpoint (it fetches usage on startup, for extra-usage checks, and when a
session hits its limit). Ten open Claude Code sessions plus this widget can trip
it together. Two things bite:

- **A request made during the hold re-arms the window**, so a naive poll can
  stay 429'd indefinitely. Measured 2026-09-04: a 2-minute poll kept the block
  armed for as long as it ran; it cleared after 2.5-5 minutes of complete
  silence.
- The `Retry-After` header is not a usable hint. It used to say `65`; it now
  says `0`, which would tell a naive client to retry immediately, forever.

So the widget polls every 5 minutes, treats a 429 as a strike and backs off
5 → 10 → 15 minutes (honouring a larger `Retry-After` if one ever appears),
makes no network call at all until the hold expires, and resets the strike
count on the next 200. While it is holding, the panel keeps the last good
numbers, turns the banner amber, and says "next try 2:58 PM" rather than
counting down. Opening the menu refreshes at most once per 2 minutes; ⌘R
forces a fetch unless a hold is active; waking from sleep refreshes too. Every
network outcome is logged as one line in `~/Library/Logs/ClaudeUsage.log`
(status, strike, hold; never numbers or tokens). If you fork this, keep that
behaviour.

## Terminal companion

```sh
bin/claude-usage           # coloured bars
bin/claude-usage --bar     # one line, statusline-friendly
bin/claude-usage --json    # raw API response
```

```
  * Week (all)       [####....................]  83% left   resets in 3d 5h (Mon 01:00)
    Week (Fable)     [........................] 100% left   up to 50% of week, resets in 3d 5h (Mon 01:00)
    This week: Claude Code 99%, Other 1%

  Estimated split by model since Mon Nov 02 01:00 (This Mac + Mini)
    Opus 5.5       92.5%   $395.14      3892 messages
    Haiku 5.5       6.3%   $26.95        494 messages
    Sonnet 5.5      1.2%   $5.00         170 messages
```

Symlink it onto your `PATH` if you want it in a shell prompt or a Claude Code
statusline.

## Development

```sh
./build.sh                                     # compile, sign, relaunch
"$HOME/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" \
    --snapshot out.png [--demo [--stale]] [--dark]  # render the dropdown panel
    --icon out.png [--dark] [--health warn|critical]  # render the menu bar item
```

The two renderers draw straight to a PNG under an explicit appearance, so you can
check the design in light and dark without a visible screen. `--demo` uses
synthetic data — no network call, no real numbers — which is how the screenshots
above are produced.

| Path | What |
|---|---|
| `Sources/main.swift` | fetch, parse, menu bar item, panel, login item, debug flags |
| `Sources/Health.swift` | Mac health: sensing (Mach + libproc), scoring, reaping, notifications |
| `build.sh` | compile + ad-hoc sign + relaunch |
| `uninstall.sh` | remove app, login item, LaunchAgent |
| `bin/claude-usage` | the same query, in the terminal |
| `bin/claude-usage-models` | the per-model estimate; `build.sh` copies it into the app |

## Notes on the API shape

The response carries a `limits[]` array (`kind`: `session`, `weekly_all`,
`weekly_scoped`) which the widget prefers, falling back to the older flat
`five_hour` / `seven_day` objects if a future build drops it. The `session` entry
is absent for verified Ultra accounts, which have no 5-hour limit, and Opus and
Sonnet no longer have entries. `weekly_scoped_shares` gives a scoped limit's
allowance as a share of the week, matched to `limits[]` by `limit_index`.
`seven_day_breakdown` splits the week by product. `resets_at` jitters
across the minute boundary (`…T14:59:59.99…`), so timestamps are rounded to the
nearest second before display — truncating renders "4:59 PM" for a 5:00 reset.
`spend` drives the extra-usage-credits row.

This is an undocumented internal endpoint. It can change without warning; the
parser is defensive about missing fields, but if Anthropic reshapes it, this
breaks until someone updates the parser.

## License

MIT — see [LICENSE](LICENSE).
