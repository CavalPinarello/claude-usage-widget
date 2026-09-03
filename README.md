# Claude Usage

A macOS menu bar widget for how much Claude quota you have left, in the two
windows that actually gate you: the **5-hour session** and the **rolling week**.

![menu bar](docs/menubar.png)

Two meters — session on top, week below — plus the remaining percentages. Colour
goes green → yellow → orange → red as you burn through, and the text only picks
up colour past 80% used, so it stays quiet when there's nothing to worry about.

Click it for the detail:

![panel](docs/panel.png)

Per-model weekly caps (`Week · Opus` above) appear only once they are actually
non-zero. An extra-usage-credits row appears only if you have credits enabled.

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

It is a single ~660-line Swift file. Read it.

## Rate limiting

The usage endpoint sits behind a tight sliding-window limiter. It answers 429
with `Retry-After: 65`, and — the part that bites — **a request made during the
hold re-arms the window**, so a naive 30-second poll can stay 429'd indefinitely.

The widget parses `Retry-After` and makes no network call at all until the hold
expires. Base interval is 90 seconds, plus a refresh on menu open (throttled to
one per 30s) and on wake from sleep. If you fork this, keep that behaviour.

## Terminal companion

```sh
bin/claude-usage           # coloured bars
bin/claude-usage --bar     # one line, statusline-friendly
bin/claude-usage --json    # raw API response
```

```
  ● Session (5h)     [####....................]  83% left   resets in 4h 3m (Thu 17:00)
    Week (all)       [#.......................]  97% left   resets in 3d 13h (Mon 02:00)
```

Symlink it onto your `PATH` if you want it in a shell prompt or a Claude Code
statusline.

## Development

```sh
./build.sh                                     # compile, sign, relaunch
"$HOME/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" \
    --snapshot out.png [--demo] [--dark]       # render the dropdown panel
    --icon out.png [--dark]                    # render the menu bar item
```

The two renderers draw straight to a PNG under an explicit appearance, so you can
check the design in light and dark without a visible screen. `--demo` uses
synthetic data — no network call, no real numbers — which is how the screenshots
above are produced.

| Path | What |
|---|---|
| `Sources/main.swift` | the whole app: fetch, parse, menu bar item, panel, login item |
| `build.sh` | compile + ad-hoc sign + relaunch |
| `uninstall.sh` | remove app, login item, LaunchAgent |
| `bin/claude-usage` | the same query, in the terminal |

## Notes on the API shape

The response carries a `limits[]` array (`kind`: `session`, `weekly_all`,
`weekly_scoped`) which the widget prefers, falling back to the older flat
`five_hour` / `seven_day` objects if a future build drops it. `resets_at` jitters
across the minute boundary (`…T14:59:59.99…`), so timestamps are rounded to the
nearest second before display — truncating renders "4:59 PM" for a 5:00 reset.
`spend` drives the extra-usage-credits row.

This is an undocumented internal endpoint. It can change without warning; the
parser is defensive about missing fields, but if Anthropic reshapes it, this
breaks until someone updates the parser.

## License

MIT — see [LICENSE](LICENSE).
