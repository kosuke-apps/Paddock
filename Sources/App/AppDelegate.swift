import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private var controller: ServerController!
    private var statusMenu: StatusMenu!
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads the settings or creates the menu bar item, whose position is one of them.
        SettingsMigration.migrate(
            legacy: UserDefaults.standard.persistentDomain(forName: SettingsMigration.legacyDomain), into: .standard)
        LoginItem.setUpOnFirstLaunch(preferences)

        controller = ServerController(configuration: .standard())
        statusMenu = StatusMenu(controller: controller, preferences: preferences)
        controller.onChange = { [weak self] in self?.statusMenu.update() }

        // `kill` and `killall` send SIGTERM. Treat it as Quit so the server Paddock started is stopped too.
        // Quitting waits for the server in a nested run loop. Started from inside this main-queue handler, that loop
        // could never run the main-queue work that reports the server's exit, so it is started from the run loop.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
        source.resume()
        terminationSignal = source

        // Nothing is probed while the Mac sleeps; look again on waking.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.refresh() }
        }

        if preferences.startServerWhenOpened, case .stopped = controller.status, controller.binary != nil {
            controller.start(keepAlive: preferences.keepAlive)
        }
    }

    /// A server Paddock started is stopped before Paddock quits, including at logout and shutdown.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let server = controller?.ownedServer else { return .terminateNow }
        controller.stop { [weak self] in self?.finishQuitting() }

        // A safety net that does not depend on the main queue, so Paddock never hangs at quit or logout: if the
        // server's exit has not been reported well after the controller's own SIGKILL, kill it here and quit.
        let fallback = Timer(timeInterval: controller.configuration.stopTimeout + 5, repeats: false) { _ in
            MainActor.assumeIsolated {
                if ProcessInspector.isRunning(server.pid) {
                    for runner in ProcessInspector.childPIDs(of: server.pid) { kill(runner, SIGKILL) }
                    kill(server.pid, SIGKILL)
                }
                self.finishQuitting()
            }
        }
        RunLoop.main.add(fallback, forMode: .common)
        return .terminateLater
    }

    private var didFinishQuitting = false

    private func finishQuitting() {
        guard !didFinishQuitting else { return }
        didFinishQuitting = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
