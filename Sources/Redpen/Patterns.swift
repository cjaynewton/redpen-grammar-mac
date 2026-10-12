import AppKit

/// "Your patterns": the mistakes that came back most this week, each with its rule.
final class PatternsWindow {
    private var window: NSWindow?

    func show(_ text: String) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Your patterns"
            w.isReleasedWhenClosed = false
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = w.contentView!.bounds
            scroll.autoresizingMask = [.width, .height]
            if let tv = scroll.documentView as? NSTextView {
                tv.isEditable = false
                tv.font = .systemFont(ofSize: 14)
                tv.textContainerInset = NSSize(width: 16, height: 16)
            }
            w.contentView!.addSubview(scroll)
            w.center()
            window = w
            return w
        }()
        if let scroll = w.contentView?.subviews.first as? NSScrollView, let tv = scroll.documentView as? NSTextView {
            tv.string = text
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
