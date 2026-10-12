import AppKit
import RedpenCore

/// The small card that opens when an underline is clicked. It never takes focus from the app being typed in.
final class SuggestionPanel: NSObject {
    private let panel: NSPanel
    private var actions: [() -> Void] = []
    private var outsideMonitor: Any?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init()
    }

    var isVisible: Bool { panel.isVisible }

    struct Choice { let title: String; let primary: Bool; let run: () -> Void }

    /// `anchor` is the underline's rect in Cocoa screen coordinates.
    func show(title: String, color: NSColor, message: String, detail: String?, choices: [Choice], below anchor: CGRect) {
        actions = choices.map { $0.run }

        let box = NSVisualEffectView()
        box.material = .popover
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        box.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let head = NSTextField(labelWithString: title.uppercased())
        head.font = .systemFont(ofSize: 10, weight: .semibold)
        head.textColor = color
        stack.addArrangedSubview(head)

        let msg = NSTextField(wrappingLabelWithString: message)
        msg.font = .systemFont(ofSize: 13)
        msg.preferredMaxLayoutWidth = 280
        stack.addArrangedSubview(msg)

        if let detail {
            let d = NSTextField(wrappingLabelWithString: detail)
            d.font = .systemFont(ofSize: 12)
            d.textColor = .secondaryLabelColor
            d.preferredMaxLayoutWidth = 280
            stack.addArrangedSubview(d)
        }

        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        for (i, c) in choices.enumerated() {
            let b = NSButton(title: c.title, target: self, action: #selector(tap(_:)))
            b.tag = i
            b.bezelStyle = c.primary ? .push : .inline
            if c.primary { b.bezelColor = color; b.contentTintColor = .white }
            b.font = .systemFont(ofSize: c.primary ? 13 : 12, weight: c.primary ? .semibold : .regular)
            b.lineBreakMode = .byTruncatingTail
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
            row.addArrangedSubview(b)
        }
        stack.addArrangedSubview(row)

        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 308),
        ])
        panel.contentView = box
        box.layoutSubtreeIfNeeded()
        let size = stack.fittingSize

        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            if origin.y < vf.minY { origin.y = anchor.maxY + 6 }   // no room below: open above
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] _ in
                self?.hide()
            }
        }
    }

    @objc private func tap(_ sender: NSButton) {
        let run = actions[sender.tag]
        hide()
        run()
    }

    func hide() {
        panel.orderOut(nil)
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }
}
