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

extension Issue {
    var color: NSColor { tentative ? NSColor(srgbRed: 0.55, green: 0.55, blue: 0.58, alpha: 0.95) : kind.color }
    var label: String { tentative ? "Maybe (Apple model)" : kind.label }
}

struct Mark { let issue: Issue; let rect: CGRect }  // rect in Cocoa screen coordinates

/// A transparent, click-through window laid over the text field that draws the underlines.
final class Overlay {
    private let window: NSWindow
    private let view = UnderlineView()
    private var refreshed = Date.distantPast
    private var expiry: Timer?

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
        refreshed = Date()
        if expiry == nil {
            // Underlines are redrawn four times a second. If that stops for any reason, they must not stay
            // painted over whatever is on screen next. 2 s outlasts the 1.5 s Chrome focus blip.
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window.isVisible, Date().timeIntervalSince(self.refreshed) > 2 else { return }
                    Log.note("underlines cleared: not refreshed for 2 s")
                    self.hide()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            expiry = t
        }
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
            if m.issue.tentative {
                // Softer mark for the model's guesses: a grey dotted line, no wave.
                path.lineCapStyle = .round
                path.setLineDash([0.1, 4], count: 2, phase: 0)
                path.move(to: CGPoint(x: r.minX, y: r.minY + 1))
                path.line(to: CGPoint(x: r.maxX, y: r.minY + 1))
                m.issue.color.setStroke()
                path.stroke()
                continue
            }
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
