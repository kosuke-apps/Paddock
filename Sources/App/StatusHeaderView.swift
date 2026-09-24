import AppKit

/// The top of the menu: a coloured dot, the state in bold, and up to two lines of detail. A custom view, because a
/// disabled menu item would grey out the one thing the menu is there to show.
@MainActor
final class StatusHeaderView: NSView {
    enum Tone {
        case off, on, busy, warning
    }

    private static let width: CGFloat = 300

    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private var tone = Tone.off

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 44))

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        detailLabel.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        noticeLabel.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        noticeLabel.textColor = .systemRed
        for label in [detailLabel, noticeLabel] {
            label.preferredMaxLayoutWidth = Self.width - 44
            label.isSelectable = false
        }

        let text = NSStackView(views: [titleLabel, detailLabel, noticeLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(text)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(title: String, detail: String?, notice: String?, tone: Tone) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        noticeLabel.stringValue = notice ?? ""
        noticeLabel.isHidden = notice == nil
        self.tone = tone
        applyDotColor()
        setAccessibilityLabel([title, detail, notice].compactMap { $0 }.joined(separator: ". "))
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDotColor()
    }

    /// Layer colours do not follow the appearance on their own, so the colour is resolved for the current one.
    private func applyDotColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = Self.color(for: tone).cgColor
        }
    }

    private static func color(for tone: Tone) -> NSColor {
        switch tone {
        case .off: .tertiaryLabelColor
        case .on: .systemGreen
        case .busy: .systemYellow
        case .warning: .systemOrange
        }
    }
}
