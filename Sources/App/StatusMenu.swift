import AppKit

/// The menu bar item and its menu. Everything the user sees about the server is derived from the controller here.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let controller: ServerController
    private let preferences: Preferences
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let header = StatusHeaderView()
    private let toggleItem = NSMenuItem()
    private let addressItem = NSMenuItem()
    private let keepAliveItem = NSMenuItem()
    private var keepAliveChoices: [NSMenuItem] = []
    private let startOnOpenItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let quitItem = NSMenuItem()
    private var logWindow: LogWindowController?

    init(controller: ServerController, preferences: Preferences) {
        self.controller = controller
        self.preferences = preferences
        super.init()
        buildMenu()
        update()
    }

    // MARK: - Building

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())

        configure(toggleItem, action: #selector(toggleServer))
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        configure(addressItem, action: #selector(copyAddress))
        addressItem.title = controller.address
        addressItem.subtitle = String(localized: "Click to copy")
        menu.addItem(addressItem)
        menu.addItem(.separator())

        menu.addItem(item(String(localized: "Show Log…"), action: #selector(showLog)))
        menu.addItem(item(String(localized: "Show Log in Finder"), action: #selector(revealLog)))
        menu.addItem(.separator())

        keepAliveItem.title = String(localized: "Keep Models Loaded")
        let keepAliveMenu = NSMenu()
        keepAliveMenu.autoenablesItems = false
        for choice in KeepAlive.allCases {
            let choiceItem = item(choice.title, action: #selector(chooseKeepAlive(_:)))
            choiceItem.representedObject = choice.rawValue
            keepAliveChoices.append(choiceItem)
            keepAliveMenu.addItem(choiceItem)
        }
        keepAliveMenu.addItem(.separator())
        let note = NSMenuItem(
            title: String(localized: "Used from the next server start. Apps can override it for each request."),
            action: nil, keyEquivalent: "")
        note.isEnabled = false
        keepAliveMenu.addItem(note)
        keepAliveItem.submenu = keepAliveMenu
        menu.addItem(keepAliveItem)

        configure(startOnOpenItem, action: #selector(toggleStartOnOpen))
        startOnOpenItem.title = String(localized: "Turn On Server When Paddock Opens")
        menu.addItem(startOnOpenItem)
        configure(loginItem, action: #selector(toggleLoginItem))
        loginItem.title = String(localized: "Open Paddock at Login")
        menu.addItem(loginItem)
        menu.addItem(.separator())

        configure(quitItem, action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func configure(_ menuItem: NSMenuItem, action: Selector) {
        menuItem.target = self
        menuItem.action = action
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    // MARK: - Updating

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.refresh()
        update()
    }

    func update() {
        let state = Presentation(controller: controller)

        if let button = statusItem.button {
            let image = StatusIcon.image(for: state.icon)
            image.accessibilityDescription = "Paddock: \(state.title)"
            button.image = image
            button.toolTip = "Paddock: \(state.title)"
        }
        header.show(title: state.title, detail: state.detail, notice: state.notice, tone: state.tone)

        toggleItem.title = state.toggleTitle
        toggleItem.isEnabled = state.toggleEnabled
        toggleItem.subtitle = state.toggleWarns ? Self.disconnectWarning : nil

        let chosen = preferences.keepAlive
        for choiceItem in keepAliveChoices {
            choiceItem.state = choiceItem.representedObject as? String == chosen.rawValue ? .on : .off
        }
        if let running = controller.ownedServer, running.keepAlive != chosen {
            keepAliveItem.subtitle = String(localized: "\(chosen.title) from the next server start")
        } else {
            keepAliveItem.subtitle = chosen.title
        }

        startOnOpenItem.state = preferences.startServerWhenOpened ? .on : .off
        switch LoginItem.status {
        case .enabled:
            loginItem.state = .on
            loginItem.subtitle = nil
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.subtitle = String(localized: "Needs approval in System Settings → General → Login Items")
        default:
            loginItem.state = .off
            loginItem.subtitle = nil
        }

        let stopsServer = controller.ownedServer != nil
        quitItem.title =
            stopsServer ? String(localized: "Quit Paddock and Stop Server") : String(localized: "Quit Paddock")
        quitItem.subtitle = stopsServer ? Self.disconnectWarning : nil

        logWindow?.reload()
    }

    private static var disconnectWarning: String {
        String(localized: "Apps using the server lose their connection.")
    }

    // MARK: - Actions

    @objc private func toggleServer() {
        switch controller.status {
        case .stopped:
            controller.start(keepAlive: preferences.keepAlive)
        case .starting, .running:
            controller.stop()
        case .external(let server):
            if confirmStoppingExternal(server) { controller.stop() }
        case .stopping, .stoppingExternal:
            break
        }
    }

    private func confirmStoppingExternal(_ server: ExternalServer) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Stop a server Paddock did not start?")
        // Numbers go in as text: an interpolated integer would be formatted with grouping, as in "36,434".
        let pid = String(server.pid ?? 0)
        alert.informativeText = String(
            localized: """
                This server (pid \(pid)) was started outside Paddock, for example from Terminal. \
                Apps using it lose their connection.
                """)
        alert.addButton(withTitle: String(localized: "Stop Server")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.address, forType: .string)
    }

    @objc private func showLog() {
        if logWindow == nil {
            let window = LogWindowController(controller: controller)
            window.onClose = { [weak self] in self?.logWindow = nil }
            logWindow = window
        }
        logWindow?.present()
    }

    @objc private func revealLog() {
        let store = controller.configuration.logStore
        if let log = controller.ownedServer?.logURL ?? store.latest() {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(store.directory)
        }
    }

    @objc private func chooseKeepAlive(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = KeepAlive(rawValue: raw) else { return }
        preferences.keepAlive = choice
        update()
    }

    @objc private func toggleStartOnOpen() {
        preferences.startServerWhenOpened.toggle()
        update()
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.setEnabled(LoginItem.status != .enabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Could not change the login item")
            alert.informativeText = String(
                localized:
                    "\(error.localizedDescription)\n\nYou can also change it in System Settings → General → Login Items."
            )
            NSApp.activate()
            alert.runModal()
        }
        update()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - What the menu shows

/// The menu's content for one state of the controller.
@MainActor
private struct Presentation {
    var icon = StatusIcon.Kind.off
    var tone = StatusHeaderView.Tone.off
    var title = ""
    var detail: String?
    var notice: String?
    var toggleTitle = String(localized: "Turn On Server")
    var toggleEnabled = true
    var toggleWarns = false

    init(controller: ServerController) {
        let port = String(controller.configuration.port)
        notice = controller.notice.map(Self.describe)

        switch controller.status {
        case .stopped where controller.binary == nil:
            icon = .missing
            title = String(localized: "ollama Is Not Installed")
            detail = String(localized: "Paddock looks in /opt/homebrew/bin, /usr/local/bin and Ollama.app.")
            toggleEnabled = false
        case .stopped:
            title = String(localized: "Server Off")
        case .starting:
            icon = .transition
            tone = .busy
            title = String(localized: "Starting Server…")
            detail = Self.localOnly
            toggleTitle = String(localized: "Turn Off Server")
        case .running(let server):
            icon = .on
            tone = .on
            title = String(localized: "Server On")
            let since = server.startedAt.formatted(date: .abbreviated, time: .shortened)
            detail = String(localized: "Since \(since)") + " · " + Self.localOnly
            toggleTitle = String(localized: "Turn Off Server")
            toggleWarns = true
        case .stopping, .stoppingExternal:
            icon = .transition
            tone = .busy
            title = String(localized: "Stopping Server…")
            toggleTitle = String(localized: "Turn Off Server")
            toggleEnabled = false
        case .external(let server) where server.isOllama:
            icon = .external
            tone = .warning
            title = String(localized: "Server On, Started Outside Paddock")
            var parts: [String] = []
            if let since = server.startedAt?.formatted(date: .abbreviated, time: .shortened) {
                parts.append(String(localized: "Since \(since)"))
            }
            if let pid = server.pid { parts.append("pid \(pid)") }
            detail =
                (parts.isEmpty ? "" : parts.joined(separator: " · ") + ". ")
                + String(localized: "Paddock cannot vouch for its cloud and network settings.")
            toggleTitle = String(localized: "Stop Server…")
            toggleWarns = true
        case .external(let server):
            icon = .external
            tone = .warning
            title = String(localized: "Port \(port) Is in Use")
            if let name = server.processName, let pid = server.pid {
                detail = String(localized: "By \(name) (pid \(String(pid))), not by ollama.")
            } else {
                detail = String(localized: "By a process of another user or of the system.")
            }
            toggleEnabled = false
        }
    }

    private static var localOnly: String {
        String(localized: "Local only (127.0.0.1), cloud features off")
    }

    private static func describe(_ notice: ServerNotice) -> String {
        switch notice {
        case .launchFailed(let reason):
            String(localized: "ollama could not be started: \(reason)")
        case .exitedWhileStarting:
            String(localized: "The server stopped while starting. The log has the details.")
        case .exitedUnexpectedly:
            String(localized: "The server stopped unexpectedly. The log has the details.")
        case .startTimedOut(let seconds):
            String(localized: "The server was not listening after \(seconds) seconds, so Paddock stopped it.")
        case .notPermittedToStop(let pid):
            String(localized: "Paddock is not allowed to stop this server (pid \(String(pid))).")
        }
    }
}

extension KeepAlive {
    var title: String {
        switch self {
        case .immediately: String(localized: "Unload Immediately")
        case .oneMinute: String(localized: "1 Minute")
        case .fiveMinutes: String(localized: "5 Minutes (ollama Default)")
        case .thirtyMinutes: String(localized: "30 Minutes")
        }
    }
}
