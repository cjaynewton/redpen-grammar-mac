import AppKit
import RedpenCore

extension IssueKind {
    var color: NSColor {
        switch self {
        case .spelling: return NSColor(srgbRed: 0.90, green: 0.22, blue: 0.21, alpha: 0.95)
        case .grammar: return NSColor(srgbRed: 0.16, green: 0.47, blue: 0.95, alpha: 0.95)
        case .voice: return NSColor(srgbRed: 0.58, green: 0.33, blue: 0.86, alpha: 0.95)
        }
    }
    var label: String {
        switch self {
        case .spelling: return "Spelling"
        case .grammar: return "Grammar"
        case .voice: return "Your rules"
        }
    }
}

struct Mark { let issue: Issue; let rect: CGRect }  // rect in Cocoa screen coordinates

/// A transparent, click-through window laid over the text field that draws the underlines.
final class Overlay {
    private let window: NSWindow
    private let view = UnderlineView()

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = view
    }

    func show(_ marks: [Mark], over frame: CGRect) {
        guard !marks.isEmpty else { hide(); return }
        if window.frame != frame { window.setFrame(frame, display: false) }
        view.marks = marks.map { Mark(issue: $0.issue, rect: $0.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)) }
        view.needsDisplay = true
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        view.marks = []
        window.orderOut(nil)
    }
}

final class UnderlineView: NSView {
    var marks: [Mark] = []

    override func draw(_ dirtyRect: NSRect) {
        for m in marks {
            let r = m.rect
            let path = NSBezierPath()
            path.lineWidth = 2
            // Gentle wave under the text, like Grammarly's underline.
            let y = r.minY + 1
            let step: CGFloat = 2.5
            var x = r.minX
            path.move(to: CGPoint(x: x, y: y))
            var up = true
            while x < r.maxX {
                x = min(x + step, r.maxX)
                path.line(to: CGPoint(x: x, y: up ? y + 1.5 : y))
                up.toggle()
            }
            m.issue.kind.color.setStroke()
            path.stroke()
        }
    }
}
