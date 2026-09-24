import AppKit

/// A window with the last lines of the server log. It exists only while shown, and follows the file through kernel
/// write notifications rather than by re-reading it on a timer.
@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private static let maxLines = 500

    private let controller: ServerController
    private let captionLabel = NSTextField(wrappingLabelWithString: "")
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private var shownURL: URL?
    private var watch: DispatchSourceFileSystemObject?
    private var reloadScheduled = false

    init(controller: ServerController) {
        self.controller = controller

        let scrollView = NSTextView.scrollableTextView()
        self.scrollView = scrollView
        textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scrollView.borderType = .lineBorder

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Server Log")
        window.minSize = NSSize(width: 420, height: 240)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        captionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        captionLabel.textColor = .secondaryLabelColor
        let finderButton = NSButton(
            title: String(localized: "Show in Finder"), target: self, action: #selector(showInFinder))
        finderButton.controlSize = .small

        let bar = NSStackView(views: [captionLabel, finderButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        finderButton.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView(views: [bar, scrollView])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [bar, scrollView] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = content
        window.center()
        window.setFrameAutosaveName("ServerLog")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        reload()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // The newest lines are the interesting ones; scroll once the window has laid out its text.
        textView.scrollToEndOfDocument(nil)
    }

    /// Shows the log of the server Paddock runs, or else the newest log there is.
    func reload() {
        let store = controller.configuration.logStore
        let url = controller.ownedServer?.logURL ?? store.latest()
        let switchedFile = url != shownURL
        if switchedFile {
            shownURL = url
            watchFile(url)
        }

        var caption: [String] = []
        if case .external = controller.status {
            caption.append(
                String(
                    localized: """
                        The running server was started outside Paddock, so its output is not recorded. \
                        This is the last server Paddock started.
                        """))
        }
        guard let url, let text = LogStore.tail(of: url, maxLines: Self.maxLines) else {
            caption.append(String(localized: "No server output yet. Paddock records the output of servers it starts."))
            captionLabel.stringValue = caption.joined(separator: " ")
            textView.string = ""
            return
        }
        caption.append(String(localized: "\(url.path) (last \(Self.maxLines) lines)"))
        captionLabel.stringValue = caption.joined(separator: " ")

        let clipView = scrollView.contentView
        // Follow new output only while the reader is at the end, so scrolling back to read is not interrupted.
        let atBottom = clipView.bounds.maxY >= textView.frame.maxY - 4
        textView.string = text
        if atBottom || switchedFile { textView.scrollToEndOfDocument(nil) }
    }

    private func watchFile(_ url: URL?) {
        watch?.cancel()
        watch = nil
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watch = source
    }

    /// Output often arrives in bursts; one reload per burst is enough.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadScheduled = false
                if let url = self.shownURL, !FileManager.default.fileExists(atPath: url.path) {
                    self.shownURL = nil
                }
                self.reload()
            }
        }
    }

    @objc private func showInFinder() {
        if let url = shownURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let directory = controller.configuration.logStore.directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        }
    }

    func windowWillClose(_ notification: Notification) {
        watch?.cancel()
        watch = nil
        textView.string = ""
        onClose?()
    }
}
