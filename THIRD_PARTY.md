# Third-party material

Paddock contains no third-party code, data, fonts, images or models. It is written in Swift against Apple's own
frameworks (AppKit, Foundation, ServiceManagement, and libproc from the system), and its icons are drawn by its own
code (`Sources/App/StatusIcon.swift`, `tools/make_icon.swift`).

## Used but not included

| What | How Paddock uses it | Licence | Source |
|---|---|---|---|
| [Ollama](https://ollama.com) | Paddock starts and stops the `ollama` command the user has installed (for example with Homebrew). It is not bundled, linked or redistributed. | MIT | <https://github.com/ollama/ollama/blob/main/LICENSE> |

Ollama is a separate download under its own licence; the models it serves come with their own terms, which Paddock
neither ships nor touches.

## Build tools

The build uses tools that come with Xcode (`swiftc`, `xcstringstool`, `swift-format`, `iconutil`, `codesign`).
None of their code ends up in the app.
