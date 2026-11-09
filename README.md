# Headroom

<p align="center"><img src="docs/mascot-fast.png" width="420" alt="A cartoon computer in sunglasses and a red cape, speeding past"></p>

Headroom is a macOS menu bar widget for two kinds of headroom: how much Claude
you have left this week (and in the 5-hour session, on plans that still have
one), and how much memory your Mac has left before it slows down. When either
gets tight, one click helps.

Made by **Martin Kawalski**. It was called Claude Usage until 2026-11-09.

![menu bar](docs/menubar.png)

The ring fills with what is left: the outer ring is the week, the inner ring the
5-hour session. Next to it, small columns give the same numbers as text. They go
green, yellow, orange and red as you use them up, and the text only takes a
colour past 80% used. When the Mac itself is in trouble a third column appears,
here memory at 9% free:

![menu bar with a memory warning](docs/menubar-warn.png)

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

## Install

### From the disk image

1. Download `Headroom-1.1.dmg` from the Releases page, or build one yourself with
   `tools/make-dmg.sh` (it lands in `dist/`).
2. Open it and drag **Headroom** onto **Applications**.
3. Open Headroom from Applications. It is signed ad hoc, not notarized, so the
   first time macOS says it cannot check it. Open **System Settings > Privacy &
   Security**, scroll down, and click **Open Anyway**.

If you open it straight from the disk image, the setup window offers to move it
to Applications for you and restarts from there.

### First-run setup

![setup](docs/setup.png)

Four short pages:

- **Meet Headroom**, with the move to Applications if needed.
- **Connect to Claude.** Headroom finds the login Claude Code keeps in your
  Keychain and makes one test call to Anthropic's usage API. There is no API key
  to paste and nothing extra is billed. If Claude Code is not installed or not
  signed in, the page says so, copies the install command
  (`curl -fsSL https://claude.ai/install.sh | bash`) and checks again once you
  have run `claude` and signed in. macOS may ask once whether `security` may
  read the item: choose Always Allow.
- **A few choices**: open at login, warn before the Mac slows down, clear
  leaked Claude helpers automatically. All three stay in the menu afterwards.
- **Done**, with the faster Mac.

**Setup & About…** (⌘,) in the menu opens it again.

### Requirements

- macOS 13 or later, Apple silicon or Intel (the DMG is universal)
- Claude Code, signed in with a **subscription account** (Pro, Max or Ultra)
- To build from source: Xcode command line tools (`xcode-select --install`)

It reads the OAuth login Claude Code already stores. If you drive Claude Code
with an `ANTHROPIC_API_KEY`, or through Bedrock or Vertex, there is no
subscription quota to report and the widget says it is not connected.

The **Week by model** estimate needs python3, which comes with the command line
tools. Without them that section simply stays hidden.

### From source

```sh
git clone https://github.com/CavalPinarello/claude-usage-widget
cd claude-usage-widget
./build.sh
```

That compiles `~/Applications/Headroom.app`, ad-hoc signs it, and launches
it. Because you built it locally there is no Gatekeeper quarantine and no
"unidentified developer" dialog.

**Open at Login** is a toggle in the widget's own menu. It writes
`~/Library/LaunchAgents/com.claudeusage.widget.plist` and bootstraps it with
`launchctl`, so no Developer ID is needed.

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

Reaping runs on every poll that finds a stale target (when **Clear Leaks Automatically**
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

- **Speed Up Mac…** (⌘U) and **Free Up Disk Space…** (⌘D): see above.
- **Warn Before It Slows Down**: the `health.earlyWarning` toggle.
- **Clear Leaks Automatically**: the `health.autoReap` toggle.
- **Open at Login**.
- **Setup & About…** (⌘,): the first-run setup again, with the version and credit.
- **Quit Headroom**.

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
defaults write com.claudeusage.widget health.summarizerBurstMax -int 10   # burst rule; 0 = off
```

### Debug flags

```sh
"$HOME/Applications/Headroom.app/Contents/MacOS/Headroom" --health-json     # one sample + assessment as JSON, timing on stderr
"$HOME/Applications/Headroom.app/Contents/MacOS/Headroom" --reap-dry-run   # what a reap would kill, without killing
"$HOME/Applications/Headroom.app/Contents/MacOS/Headroom" --notify-test    # one test notification through the reaper's path
"$HOME/Applications/Headroom.app/Contents/MacOS/Headroom" --argv-selftest  # KERN_PROCARGS2 parser + fingerprint fixtures; non-zero exit on any failure
"$HOME/Applications/Headroom.app/Contents/MacOS/Headroom" --relief-dry-run         # what Clean Up would list now, cache sizes included
"$HOME/Applications/Headroom.app/Contents/MacOS/Headroom" --relief-snapshot out.png  # the window with synthetic rows, as a PNG (light only)
```

`--health-json` reports `level` after the hysteresis (it assesses the sample
twice, the first copy backdated past the promotion age, so the number you see
is the steady state) alongside `rawLevel`, `emergency` and `validity`, and
lists every process it classified with its first three arguments.
`--argv-selftest` runs the argv parser against malformed payloads (truncated,
missing terminator, argc larger than the payload, empty argument, bad UTF-8)
and the option scanner against `--` handling; the parser is a kill gate, so it
fails closed on anything it cannot read.

## Speed Up Mac, Free Up Disk Space, and the early warning

Two actions, because they answer different needs. Memory and CPU go wrong
within minutes, so that is the daily one. Disk is maintenance, every few weeks.

**Speed Up Mac…** (⌘U, the big button under the MAC rows, red or orange when
memory, load or the Claude stack is in trouble). One click clears the leaks the
reaper already owns (any age while memory is low), then opens a window with
memory before → now in large numbers and four sections, each opening with one
sentence on when it matters: **Claude Code sessions** (folder, age, keyboard
idle time, tmux session; detached or 3 h idle are suggested; Close kills the
tmux pane, or SIGTERM), **heavy jobs** (Xcode builds and tests, ffmpeg, booted
simulators; busy ones suggested), **apps** over 300 MB (Quit, so they can ask
to save), and **background processes** over 800 MB started by launchd (never
suggested). Memory is re-measured after every action and on Recheck.

**Free Up Disk Space…** (⌘D, the small Disk Space button). Disk before → now
and a fixed list of caches that rebuild themselves: uv, Codex, Playwright,
Adobe Camera Raw, pip, npm, Homebrew downloads. Suggested at 1 GB or more, or
all of them while the disk is under 50 GB. It never touches a process.

**Warn Before It Slows Down** (on by default, `health.earlyWarning`). Every
30 s sample goes into a 10-minute trend. A notification goes out when memory is
at 40% free or less and falling fast enough to reach the critical line (15%)
within about 10 minutes, or when swap grows by 1.5 GB in 5 minutes with memory
under 50% free. At most one every 20 minutes. The older "Mac is slowing down"
notice still fires once memory is critical. Under 20 GB of free disk a "Disk
almost full" reminder goes out, at most once a day. Clicking any of them opens
the matching window.

Every signal re-checks pid and start time (jobs: the full command line) and is
logged to `~/.claude-mem/hygiene.log`. The rest of the menu: Clear Leaks
Automatically (the 30-second reaper, with the burst rule), Open at Login, Quit.
Refresh is the button in the panel footer (⌘R still works).

Debug: `--relief-dry-run`, `--relief-snapshot out.png [--disk]`,
`--relief-window [--disk] [--dark]`. The early-warning rules have fixtures in
`--argv-selftest`. The icon is drawn by `swift tools/make-icon.swift`.

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
"$HOME/Applications/Headroom.app/Contents/MacOS/Headroom" \
    --snapshot out.png [--demo [--stale]] [--dark]  # render the dropdown panel
    --icon out.png [--session] [--dark] [--health warn|critical]  # render the menu bar item
    --mascot out.png [--sluggish]                  # render the cartoon Mac
    --setup-window [0-3] [--dark]                  # open the setup window on a page
tools/make-dmg.sh                              # universal build into dist/Headroom-<version>.dmg
```

The two renderers draw straight to a PNG under an explicit appearance, so you can
check the design in light and dark without a visible screen. `--demo` uses
synthetic data — no network call, no real numbers — which is how the screenshots
above are produced.

| Path | What |
|---|---|
| `Sources/main.swift` | fetch, parse, menu bar item, panel, login item, debug flags |
| `Sources/Health.swift` | Mac health: sensing (Mach + libproc), scoring, reaping, notifications |
| `Sources/Relief.swift`, `Sources/SpeedUp.swift` | the Speed Up Mac and Disk Space windows |
| `Sources/Setup.swift` | first-run setup, move to Applications |
| `Sources/Mascot.swift` | the cartoon Mac, drawn in code |
| `tools/make-dmg.sh` | the disk image |
| `build.sh` | compile + ad-hoc sign + relaunch (or a standalone copy for the DMG) |
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

## Credits and license

Made by Martin Kawalski. MIT, see [LICENSE](LICENSE).

<p align="center"><img src="docs/mascot-sluggish.png" width="300" alt="The same computer before: sweating, half asleep, too many windows open"><br><sub>Before Headroom.</sub></p>
