# Paddock

A menu bar app that owns the one shared ollama server on this Mac: it starts it local-only with cloud features
off, stops it, and shows whether it runs and who started it. Workspace rules are in `~/Developer/AGENTS.md`; Mac
utilities rules (signing, String Catalogs, measuring resident apps, distribution) are in `../AGENTS.md`. This file
adds what is specific to Paddock. The README is the user-facing description, including the measured idle cost.

## Product

- Purpose: Gijiroku, Taiyaku, and later apps use LLMs through one ollama server on `http://127.0.0.1:11434`, sharing
  `~/.ollama/models`. They only connect; Paddock alone starts and stops the server. It exists because a forgotten
  `ollama serve` ran for six days and talked to ollama.com the whole time.
- Core journey: open the menu, Turn On Server, apps work; Quit Paddock (or Turn Off) stops it.
- Always: `OLLAMA_HOST=127.0.0.1:11434`, `OLLAMA_NO_CLOUD=1`, every inherited `OLLAMA_*` variable dropped.
- Decided with the user (2026-09-23): name Paddock; "Turn On Server When Paddock Opens" exists and is off by default;
  keep-alive is a preset menu (0, 1m, 5m default, 30m) applied at the next start, never by restarting on its own.
- Out of scope: model download or deletion, details of loaded models, chat, installing ollama. Do not add them.
- Other apps' wording that points users to Paddock is changed in their own projects, not from here.

## Technical context

- Swift 6 language mode, AppKit, macOS 26, arm64. No Xcode project and no dependencies: `build.sh` assembles the
  bundle with `swiftc`. Bundle identifier `dev.kosuke.paddock`. Builds before the first release used
  `local.paddock`; `SettingsMigration` copies their settings over once.
- `LSUIElement` menu bar app with an `NSStatusItem`; login item through `SMAppService.mainApp`, registered on the
  first launch from an Applications folder only.
- Signed with the shared `Mac Utilities Code Signing` certificate; ad-hoc with a warning when it is missing.
- Strings: `String(localized:)` only. `build.sh` compiles with `-emit-localized-strings`, syncs
  `Resources/Localizable.xcstrings` with `xcstringstool sync`, and fails (`tools/check_strings.swift`) while a
  string lacks Japanese or is unused. Add the Japanese value to the catalog when adding a string. Interpolate
  numbers that are identifiers (pid, port) as `String(...)`: an interpolated integer is formatted with grouping.

### Files

- `Sources/Core/` — Foundation only; everything here is covered by `tests/`.
  - `ServerController.swift` — `@MainActor` state machine: `stopped`, `starting`, `running`, `stopping` (servers
    Paddock started), `external`, `stoppingExternal`, plus a `notice` for failures. Launches `ollama serve` with
    `Process`, its output going straight to the log file (not a pipe, so output survives a Paddock crash). Watches
    its own child through `terminationHandler`, other processes through a `DispatchSource` process-exit source.
    Probes the port on a timer only while stopped or while a non-ollama process holds the port (10 s), and while
    starting (0.25 s, 60 s timeout). Stop: SIGTERM, SIGKILL to the server and its children after 10 s. Keeps a record
    (pid, start time, log path, keep-alive) in the defaults under `ownedServer`, so after a crash the next launch
    adopts the same process instead of calling it external.
  - `ServerEnvironment.swift` — `KeepAlive`, the server environment, ollama's install locations.
  - `ProcessInspector.swift` — libproc: process name and start time, the pid holding a listening socket on a port,
    child pids.
  - `PortProbe.swift` — non-blocking connect to 127.0.0.1; sends nothing.
  - `LogStore.swift` — `~/Library/Logs/Paddock/ollama-serve-*.log`, one per start, five kept, whole-file deletion
    (never truncation), `O_APPEND` writes, tail reading.
  - `SettingsMigration.swift` — copies the settings of the pre-release identifier `local.paddock` once.
- `Sources/App/` — AppKit.
  - `AppDelegate.swift` — wiring; SIGTERM becomes Quit; wake triggers a refresh; `applicationShouldTerminate`
    stops the owned server with `.terminateLater` plus a run-loop timer as a safety net.
  - `StatusMenu.swift` — the status item, the menu (rebuilt state in `update()`, refreshed in `menuNeedsUpdate`),
    the external-stop confirmation, and `Presentation`, which maps controller state to all visible text.
  - `StatusHeaderView.swift` — custom view at the top of the menu (dot, bold state, detail, red notice).
  - `StatusIcon.swift` — template fence icons with a state mark: none (off, dimmed), ring (transition), dot (on),
    `!` (external), struck through (missing, dimmed).
  - `LogWindowController.swift` — last 500 lines, follows the file through a `DispatchSource` file watch.
  - `Preferences.swift` — `UserDefaults` settings and `LoginItem`.
- `tests/main.swift` — test runner; `tests/support/fake-ollama.swift` builds a binary named `ollama` that prints its
  `OLLAMA_*` environment and listens where `OLLAMA_HOST` says (`FAKE_OLLAMA_EXIT`, `FAKE_OLLAMA_LISTEN_DELAY`,
  `FAKE_OLLAMA_IGNORE_TERM` simulate failures). Tests use ports 11490–11499 and never touch port 11434.
- `tools/make_icon.swift` (writes `Resources/AppIcon.icns` when missing), `tools/check_strings.swift`.
- `tools/netwatch.swift` samples every socket of a process tree every 50 ms and flags anything not loopback-only;
  `tools/long-run.sh <new dir>` records a Paddock-started server past its model-recommendation refresh with it and
  with the mDNSResponder log. Write records outside the repository: they hold local paths and usage times. What the
  recorders can miss is in `docs/network-verification.md`.

### Pitfalls already met

- Never start a nested run loop (such as quitting with `.terminateLater`) from inside a main-queue block: the main
  queue does not run re-entrantly, so the server's exit report never arrives and Paddock hangs. The SIGTERM
  handler therefore calls `terminate` through `perform(_:with:afterDelay:)`.
- The status item may sit behind the notch; accessibility still reaches it (`System Events`, process "Paddock").

## Commands

- Build: `./build.sh` (`--install` copies to `/Applications`, `--release` makes `dist/Paddock-<version>.dmg`
  and its `.sha256`, after checking the packed app's signature and identifier).
- Test and lint: `./tests/run.sh` (runs `swift-format lint --strict`, then the tests).
- Format: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift-format format -i -r Sources tests tools`
- Run: `open Paddock.app`. Japanese UI: `open Paddock.app --args -AppleLanguages '(ja)'`.
- Settings and state: `defaults read dev.kosuke.paddock`. Logs: `~/Library/Logs/Paddock/`.

## Definition of done

- `./tests/run.sh` and `./build.sh` pass with no warnings; the catalog has Japanese for every string.
- Menu states checked in the running app (English and Japanese), including a server started in Terminal.
- Idle memory and CPU re-measured and the README updated when anything that runs at idle changes.
- Paddock connects to nothing but 127.0.0.1.
