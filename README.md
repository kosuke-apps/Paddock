# Paddock

A menu bar app that runs the one shared ollama server on this Mac: it turns the server on and off, shows at a
glance whether it is running and who started it, and always starts it local-only with ollama's cloud features off.

Several Mac utilities (Gijiroku, taiyaku) use a language model through ollama. They share one set of models in
`~/.ollama/models` and one server, and none of them starts or stops that server. Paddock is the only thing that
does. It exists because a server started by hand and forgotten keeps running, and keeps talking to ollama.com,
for days without anyone noticing.

## The contract with other apps

- The server is **`http://127.0.0.1:11434`**.
- Apps only connect to it. They never start or stop it.
- When an app cannot connect, it tells the user to turn the server on in Paddock.

## Features

- **On and off.** Starts `ollama serve` with `OLLAMA_HOST=127.0.0.1:11434` (nothing outside this Mac can connect)
  and `OLLAMA_NO_CLOUD=1`, and stops it again. Every other inherited `OLLAMA_*` variable is dropped, so nothing set
  elsewhere (for example with `launchctl setenv`) can widen access.
- **State at a glance.** The menu bar icon is a switch:

  | Icon | Meaning |
  |---|---|
  | outlined, knob left | off |
  | filled, knob right | on, started by Paddock |
  | filled, knob right, then `!` | on, but started outside Paddock (for example `ollama serve` in Terminal); its cloud and network settings cannot be vouched for |
  | outlined, knob in the middle | starting or stopping |
  | outlined, struck through | ollama is not installed |

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

- Paddock itself only opens TCP connections to `127.0.0.1:11434`, to see whether something is listening. It sends
  no request, so the server logs nothing. It talks to nothing else.
- The server listens on `127.0.0.1` only.
- With `OLLAMA_NO_CLOUD=1`, ollama 0.33.3 logs `Ollama cloud disabled: true` and turns off remote inference, web
  search, and its model-recommendation downloads. The last one matters: without the setting, the server fetches
  `https://ollama.com/api/experimental/model-recommendations` about every four hours for as long as it runs, which
  is most likely the traffic seen earlier from a forgotten server. The binary skips that fetch with the message
  `skipping model recommendations refresh because cloud is disabled`.
- Checked on 2026-09-23: listing every socket of `ollama` and `llama-server` about three times a second for ten
  minutes (2,174 samples), through a start, a model load and a request, a restart, and a server started in
  Terminal, found only `127.0.0.1` addresses. The four-hourly refresh was not waited for; its skip message will appear in the log.

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

## Build and install

Requires Xcode (the build uses `swiftc`, `xcstringstool` and `swift-format` from it). There is no Xcode project on
purpose: `build.sh` is the whole build definition.

```bash
./build.sh            # builds ./Paddock.app, signed with the shared "Mac Utilities Code Signing" certificate
./build.sh --install  # also copies it to /Applications, quitting (and so stopping) a running copy first
./build.sh --release  # also zips it into dist/ for a GitHub release
```

Run it from `/Applications`, so that the login item points at a stable place. Paddock is not notarized; the first
time, macOS refuses to open it. Open System Settings → Privacy & Security and click **Open Anyway**.

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
  - `StatusIcon.swift`: the switch icons.
  - `LogWindowController.swift`: the log window.
  - `Preferences.swift`: settings and the login item.
- `Resources/`: `Info.plist`, the String Catalog (English, Japanese), the app icon.
- `tools/`: the icon generator and the String Catalog check.
