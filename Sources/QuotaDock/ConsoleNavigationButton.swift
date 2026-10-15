import AppKit

/// Native button actions and keyboard focus with a consistently aligned sidebar layout.
@MainActor
final class ConsoleNavigationButton: NSButton {
    var isSelected = false { didSet { updateAppearance() } }
    var badge: String? { didSet { countLabel.stringValue = badge ?? "" } }
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }
    private let handler: () -> Void

    init(title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        target = self
        action = #selector(invoke)
        nameLabel.stringValue = title
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        glyph.imageScaling = .scaleProportionallyDown
        for child in [glyph, nameLabel, countLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            child.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
            child.setAccessibilityElement(false)
        }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            glyph.heightAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countLabel.widthAnchor.constraint(equalToConstant: 25),
        ])
        setAccessibilityLabel(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }

    private func updateAppearance() {
        let color: NSColor = isSelected ? .systemTeal : .labelColor
        nameLabel.textColor = color
        glyph.contentTintColor = isSelected ? .systemTeal : .secondaryLabelColor
        countLabel.textColor = isSelected ? .systemTeal : .secondaryLabelColor
        setAccessibilityValue(isSelected ? "已选中" : "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || hovered || isHighlighted {
            (isSelected ? NSColor.systemTeal.withAlphaComponent(0.13) : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        if isSelected {
            NSColor.systemTeal.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: (bounds.height - 14) / 2, width: 3, height: 14), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}
