# Paddock

A menu bar app that runs the one shared ollama server on this Mac: it turns the server on and off, shows at a
glance whether it is running and who started it, and always starts it local-only with ollama's cloud features off.

Several Mac utilities (Gijiroku, taiyaku) use a language model through ollama. They share one set of models in
`~/.ollama/models` and one server, and none of them starts or stops that server. Paddock is the only thing that
does. It exists because a server started by hand and forgotten keeps running, and keeps talking to ollama.com,
for days without anyone noticing.

Requirements: macOS 26 on Apple silicon, and [Ollama](https://ollama.com) installed separately (for example
`brew install ollama`). Ollama is a separate program under its own licence (MIT); Paddock starts and stops it but
does not include it.

## The contract with other apps

- The server is **`http://127.0.0.1:11434`**.
- Apps only connect to it. They never start or stop it.
- When an app cannot connect, it tells the user to turn the server on in Paddock.

## Features

- **On and off.** Starts `ollama serve` with `OLLAMA_HOST=127.0.0.1:11434` (nothing outside this Mac can connect)
  and `OLLAMA_NO_CLOUD=1`, and stops it again. Every other inherited `OLLAMA_*` variable is dropped, so nothing set
  elsewhere (for example with `launchctl setenv`) can widen access.
- **State at a glance.** The menu bar icon is a paddock fence with a mark to its right:

  | Icon | Meaning |
  |---|---|
  | fence alone, dimmed | off |
  | fence and a filled dot | on, started by Paddock |
  | fence and `!` | on, but started outside Paddock (for example `ollama serve` in Terminal); its cloud and network settings cannot be vouched for |
  | fence and a ring | starting or stopping |
  | fence struck through, dimmed | ollama is not installed |

  The menu says the same in words, with the time the server started, so a server left running for days shows up.
- **Stopping a server started elsewhere** asks first. Paddock only ever stops a process named `ollama`; if something
  else holds the port, the menu says which process it is and offers nothing to stop.
- **The address**, with a click to copy it.
- **The log.** Everything the server prints goes to `~/Library/Logs/Paddock/ollama-serve-<date>-<time>.log`, one
  file per start. The five newest files are kept whole; older ones are deleted whole. The menu shows the last 500
  lines in a window that follows new output, or reveals the file in Finder.
- **Quitting Paddock stops the server it started.** The Quit item says so ("Quit Paddock and Stop Server"), and like
  the Turn Off item it warns that apps using the server lose their connection. The same happens at logout and when
  Paddock receives SIGTERM. A server started outside Paddock is left running.
- **Settings**
  - *Keep Models Loaded*: how long a model stays in memory after its last request (`OLLAMA_KEEP_ALIVE`): unload
    immediately, 1, 5 (ollama's default) or 30 minutes. Used from the next server start; Paddock does not restart
    a running server by itself, because that would cut off the apps using it. A request's own `keep_alive` still
    wins, so an app can always unload a model at once with `"keep_alive": 0`.
  - *Turn On Server When Paddock Opens*: off by default. Paddock opens at login, so this is how the server comes on
    at login.
  - *Open Paddock at Login*: on by default once Paddock runs from `/Applications`.

Paddock does not download, delete, or list models (use `ollama pull` and `ollama rm`), show what is loaded, offer a
chat, or install ollama. If ollama is missing, it says so and nothing more.

## Network

What Paddock guarantees by construction:

- Paddock itself only opens TCP connections to `127.0.0.1:11434`, to see whether something is listening. It sends
  no request, so the server logs nothing. It talks to nothing else.
- The server it starts gets `OLLAMA_HOST=127.0.0.1:11434` and `OLLAMA_NO_CLOUD=1`. The server's own log then says
  `Listening on 127.0.0.1:11434` and `Ollama cloud disabled: true`.

What has been observed (records in [`docs/verification/`](docs/verification/)):

- 2026-09-23, 10 minutes: the sockets of `ollama` and `llama-server`, listed with `lsof` about three times a second
  (2,174 samples) through a start, a model load and a request, a restart, and a server started in Terminal, showed
  only `127.0.0.1` addresses. A later positive control showed that sampling of this kind misses short connections,
  so this check could not have caught a brief one.
- 2026-09-25, 25 minutes, before any refresh was due: sockets sampled every 50 ms, which a positive control showed
  catches connections open for 50 ms or more, and the system resolver's log of lookups by ollama. Only
  `127.0.0.1` sockets; one lookup, of `localhost`, when a model runner started.
- 2026-09-25, 7 h 13 min of normal use with sleep, sampling every 200 ms (connections shorter than about 200 ms
  are invisible to it) plus the resolver log (`docs/verification/2026-09-25-multi-day/`): only `127.0.0.1`
  sockets, and lookups only of `localhost`. One refresh came due, at 14:06:55; the server looked up nothing,
  connected nowhere, left the cached recommendations untouched, and scheduled the next refresh with no failure
  counted. That fits a skipped refresh, on the strength of one event.
- From 2026-09-25 16:34: the same record continues over several days (`docs/verification/2026-09-25-multi-day-2/`).

What the ollama 0.33.3 binary says, read from its strings, not observed in operation:

- It contains `https://ollama.com/api/experimental/model-recommendations` and `https://ollama.com/api/web_search`,
  and logs `model recommendations cache sleep scheduled wait=…` at start (between 4 h 0 min and 4 h 45 min in the
  runs seen so far).
- It contains `skipping model recommendations refresh because cloud is disabled`. That suggests the refresh is
  skipped under `OLLAMA_NO_CLOUD=1`; the long run above tests it.
- `~/.ollama/cache/model-recommendations.json` was last written on 2026-09-12. That a forgotten server's traffic
  to ollama.com was this refresh is a hypothesis resting on these strings and that date alone.

## How Paddock keeps track

It reacts to events wherever macOS offers one and polls only where it does not:

| Situation | How Paddock notices a change |
|---|---|
| Server started by Paddock | the process exit is reported by the system |
| ollama started elsewhere | the kernel reports that process's exit (kqueue) |
| Nothing listening, or a listener that is not ollama | a connection attempt to 127.0.0.1:11434 every 10 s |
| Starting | a connection attempt every 0.25 s until the server listens (at most 60 s) |
| Opening the menu, waking from sleep | checked at once |

macOS offers no notification when some other program starts listening on a port, so the 10-second check while the
server is off is the one timer that runs at idle. It is a single refused connection on the loopback address.

If Paddock is force-quit or crashes, the server it started keeps running. Paddock records the server's process ID
and start time, and when it opens again it recognises that server as its own, instead of as one started elsewhere.

## Idle cost

Measured on 2026-09-23 on an Apple M1 Pro with 32 GB, macOS 26.6, over 10 minutes each, without touching the menu.

| State | Paddock CPU time | Paddock memory (footprint / RSS) |
|---|---|---|
| Server off: the 10-second check runs | 0.20 s in 10 min (0.03 %) | 10 MB / 42 MB |
| Server on, started by Paddock: no timer | 0.21 s in 10 min (0.03 %) | 16 MB / 59 MB |
| For comparison, `ollama serve` itself with no model loaded | 0.02 s in 10 min | 12 MB / 31 MB |

`top` counted no idle wake-ups for Paddock in either period. The footprint is what Activity Monitor shows as
Memory; RSS also counts shared system libraries. The second row is higher because the menu had been opened once,
which builds it; the first row is before any opening. The 10-second check costs too little to separate from
AppKit's own background work. A loaded model is the server's cost, not Paddock's: gemma3:4b adds a `llama-server`
process of about 3 GB (4.4 GB RSS with a 32k context) until the keep-alive time runs out.

## Permissions

Paddock asks for none of the privacy permissions (no Accessibility, Input Monitoring, Screen Recording, microphone or
files). The first time it opens from Applications it adds itself to Login Items, so its icon is there after every
login; turn that off in its menu or in System Settings → General → Login Items. See [PRIVACY.md](PRIVACY.md).

## Install

Download `Paddock-<version>.zip` from the Releases page, unzip it, and move `Paddock.app` to Applications. Paddock is
signed but not notarized, so the first time macOS refuses to open it: open System Settings → Privacy & Security and
click **Open Anyway**.

## Build

Requires Xcode (the build uses `swiftc`, `xcstringstool` and `swift-format` from it). There is no Xcode project on
purpose: `build.sh` is the whole build definition.

```bash
./build.sh            # builds ./Paddock.app, signed with the shared "Mac Utilities Code Signing" certificate
./build.sh --install  # also copies it to /Applications, quitting (and so stopping) a running copy first
./build.sh --release  # also zips it into dist/ for a GitHub release
```

Run it from `/Applications`, so that the login item points at a stable place. Without the "Mac Utilities Code
Signing" certificate in the keychain the build is signed ad hoc, with a warning.

## Uninstall

1. Quit Paddock from its menu. This stops the server it started.
2. Remove it from System Settings → General → Login Items if it is listed, and delete `/Applications/Paddock.app`.
3. Delete its logs and settings:

   ```bash
   rm -rf ~/Library/Logs/Paddock
   defaults delete local.paddock
   ```

ollama and its models in `~/.ollama` are not Paddock's and are left alone.

## Quality checks

```bash
./tests/run.sh   # swift-format lint, then the tests
./build.sh       # also syncs the String Catalog and fails if a string lacks its Japanese translation
```

The tests drive the server controller against a fake `ollama` on ports 11490–11499, never the real server: start
and stop, a server that exits while starting, one that never listens, one that ignores SIGTERM, an ollama started
elsewhere, a port held by something else, taking a server back after a crash, and a missing ollama.

## Architecture

- `Sources/Core/` (Foundation only, covered by the tests)
  - `ServerController.swift`: the state machine; starts, stops, watches, and recognises servers.
  - `ServerEnvironment.swift`: the server's environment, the keep-alive presets, where ollama is looked for.
  - `ProcessInspector.swift`: process details and the listener of a port, read from the kernel (libproc).
  - `PortProbe.swift`: the loopback connection check.
  - `LogStore.swift`: log files, their rotation, and reading the last lines.
- `Sources/App/` (AppKit)
  - `AppDelegate.swift`: launch, SIGTERM, wake, and stopping the server before quitting.
  - `StatusMenu.swift`: the menu bar item, the menu, and all user-facing text about the server.
  - `StatusHeaderView.swift`: the coloured state line at the top of the menu.
  - `StatusIcon.swift`: the fence icons.
  - `LogWindowController.swift`: the log window.
  - `Preferences.swift`: settings and the login item.
- `Resources/`: `Info.plist`, the String Catalog (English, Japanese), the app icon.
- `tools/`: the icon generator and the String Catalog check.

## License

MIT. Copyright (c) 2026 Kosuke Satake. See [LICENSE](LICENSE) and, for what Paddock uses but does not include,
[THIRD_PARTY.md](THIRD_PARTY.md).

This app was built with the help of Claude (Anthropic) through Claude Code; design, review and testing are by Kosuke Satake. Anthropic does not endorse this app.
