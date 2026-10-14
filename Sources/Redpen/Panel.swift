import AppKit
import RedpenCore

/// The card that opens when an underline is clicked: a proofreader's note. The correction is set in the
/// Mac's serif (New York) the way a red pen marks a proof, the lesson reads as a sentence, and the actions
/// stay quiet. It never takes focus from the app being typed in.
final class SuggestionPanel: NSObject {
    private let panel: NSPanel
    private var actions: [() -> Void] = []
    private var outsideMonitor: Any?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
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
    /// "light", "dark" or "system", from the settings.
    var appearance = "light"
    private var dark: Bool {
        appearance == "dark" || (appearance == "system" && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    struct Choice { let title: String; let run: () -> Void }

    /// What the card shows. `marks` pairs each flagged text with its fix (nil when there is no fix to offer).
    struct Card {
        var kind: String
        var color: NSColor
        var marks: [(old: String, new: String?)]
        var message: String?
        var why: String?
        var example: String?
        var count = 0
        var primary: Choice?
        var alts: [Choice] = []
        var footer: [Choice] = []
    }

    // Paper and ink, light and dark.
    private struct Palette { let paper, ink, mid, line: NSColor }
    private var palette: Palette {
        // Dark: near-white ink and a light grey for secondary text, so nothing on the card reads dim.
        return dark
            ? Palette(paper: NSColor(srgbRed: 0.118, green: 0.122, blue: 0.137, alpha: 1), ink: NSColor(srgbRed: 0.980, green: 0.976, blue: 0.965, alpha: 1),
                      mid: NSColor(srgbRed: 0.82, green: 0.83, blue: 0.85, alpha: 1), line: NSColor(white: 1, alpha: 0.18))
            : Palette(paper: NSColor(srgbRed: 0.988, green: 0.988, blue: 0.980, alpha: 1), ink: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.122, alpha: 1),
                      mid: NSColor(srgbRed: 0.36, green: 0.38, blue: 0.43, alpha: 1), line: NSColor(white: 0, alpha: 0.12))
    }

    static func serif(_ size: CGFloat, italic: Bool = false, weight: NSFont.Weight = .regular) -> NSFont {
        if let name = Fonts.styleName(bold: weight >= .semibold, medium: weight == .medium, italic: italic),
           let f = NSFont(name: name, size: size * Fonts.scale) {
            return f
        }
        var d = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        d = d.withDesign(.serif) ?? d
        if italic { d = d.withSymbolicTraits(.italic) }
        return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size)
    }

    private static let width: CGFloat = 340
    private static let inset: CGFloat = 18
    private var textWidth: CGFloat { Self.width - Self.inset * 2 }

    /// `anchor` is the underline's rect; `avoid` holds the other underlines, which the card tries not to cover.
    func show(_ card: Card, below anchor: CGRect, avoid: [CGRect] = []) {
        let (box, size) = build(card)
        panel.contentView = box

        var origin = CGPoint(x: anchor.minX - Self.inset + 2, y: anchor.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main {
            origin = CardPlacement.origin(anchor: anchor, size: size, visible: screen.visibleFrame, avoid: avoid, inset: Self.inset)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()

        if outsideMonitor == nil {
            // Left clicks are the watcher's call (a click on the same word keeps the card, on another word
            // switches it). Typing or a right-click, which opens the app's own menu, closes it.
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .keyDown]) { [weak self] _ in
                self?.hide()
            }
        }
    }

    /// Draws a card into a PNG without showing it, for checking type and layout from the command line.
    static func render(_ card: Card, appearance: String, to path: String) {
        let p = SuggestionPanel()
        p.appearance = appearance
        let (box, size) = p.build(card)
        box.frame = NSRect(origin: .zero, size: size)
        box.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        box.layoutSubtreeIfNeeded()
        guard let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds) else { return }
        box.cacheDisplay(in: box.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// The card's view and its size.
    private func build(_ card: Card) -> (NSView, NSSize) {
        let p = palette
        actions = []
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var card = card
        // The mark colours are tuned for paper; lift them on the dark card so the fix word stays easy to read.
        if dark { card.color = card.color.blended(withFraction: 0.35, of: .white) ?? card.color }

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = p.paper.cgColor
        box.layer?.cornerRadius = 3
        box.layer?.borderWidth = 1
        box.layer?.borderColor = p.line.cgColor
        box.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 15, left: Self.inset, bottom: 12, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Kind, in small capitals of the mark's colour.
        let kind = NSTextField(labelWithAttributedString: NSAttributedString(string: card.kind.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: card.color, .kern: 0.9]))
        stack.addArrangedSubview(kind)

        // The mark: old text struck through, the fix in italic beside it.
        let mark = NSMutableAttributedString()
        for (i, m) in card.marks.enumerated() {
            if i > 0 { mark.append(NSAttributedString(string: "\n")) }
            if let new = m.new {
                mark.append(NSAttributedString(string: m.old, attributes: [
                    .font: Self.serif(card.marks.count > 1 ? 17 : 22), .foregroundColor: p.mid,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: card.color]))
                mark.append(NSAttributedString(string: "   "))
                mark.append(NSAttributedString(string: new.isEmpty ? "(cut)" : new, attributes: [
                    .font: Self.serif(card.marks.count > 1 ? 17 : 22, italic: true, weight: .medium), .foregroundColor: card.color]))
            } else {
                mark.append(NSAttributedString(string: m.old, attributes: [
                    .font: Self.serif(20), .foregroundColor: p.ink,
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: card.color]))
            }
        }
        mark.addAttribute(.paragraphStyle, value: lines(1.1), range: NSRange(location: 0, length: mark.length))
        stack.addArrangedSubview(wrapping(mark))

        if let msg = card.message {
            stack.addArrangedSubview(wrapping(NSAttributedString(string: msg, attributes: [
                .font: Self.serif(16), .foregroundColor: p.ink, .paragraphStyle: lines(1.3)])))
        }

        if card.why != nil || card.example?.isEmpty == false || card.count >= 2 {
            let why = NSMutableAttributedString()
            if let w = card.why {
                why.append(NSAttributedString(string: w, attributes: [.font: Self.serif(15), .foregroundColor: p.mid]))
            }
            if let ex = card.example, !ex.isEmpty {
                why.append(NSAttributedString(string: (why.length > 0 ? "\n" : "") + ex, attributes: [.font: Self.serif(15, italic: true), .foregroundColor: p.ink]))
            }
            if card.count >= 2 {
                why.append(NSAttributedString(string: (why.length > 0 ? "\n" : "") + "You\u{2019}ve fixed this \(card.count) times in the last 30 days.",
                                              attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: card.color]))
            }
            why.addAttribute(.paragraphStyle, value: lines(1.3), range: NSRange(location: 0, length: why.length))
            stack.addArrangedSubview(wrapping(why))
        }

        // Actions: one dark "Use" button, alternatives outlined, the rest as quiet links underneath.
        var buttons: [NSView] = []
        if let pc = card.primary { buttons.append(button(pc, filled: true, p)) }
        for a in card.alts.prefix(3) { buttons.append(button(a, filled: false, p)) }
        if !buttons.isEmpty {
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.spacing = 6
            stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(row)
        }
        if !card.footer.isEmpty {
            let row = NSStackView(views: card.footer.map { link($0, p) })
            row.orientation = .horizontal
            row.spacing = 16
            stack.addArrangedSubview(row)
        }

        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        box.layoutSubtreeIfNeeded()
        return (box, stack.fittingSize)
    }

    private func lines(_ multiple: CGFloat) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle(); s.lineHeightMultiple = multiple
        s.lineBreakStrategy = [.pushOut, .standard]  // no single word alone on the last line
        return s
    }

    private func wrapping(_ s: NSAttributedString) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: "")
        f.attributedStringValue = Self.joinLastWords(s)
        f.preferredMaxLayoutWidth = textWidth
        f.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return f
    }

    /// Joins the last two words of each line with a no-break space, so a paragraph never ends on one word alone.
    static func joinLastWords(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        let ns = m.string as NSString
        var end = ns.length
        while end > 0 {
            let lineStart = ns.lineRange(for: NSRange(location: end - 1, length: 0)).location
            let line = NSRange(location: lineStart, length: end - lineStart)
            let space = ns.range(of: " ", options: .backwards, range: line)
            if space.location != NSNotFound, ns.substring(with: line).split(separator: " ").count >= 4 {
                m.replaceCharacters(in: space, with: "\u{00A0}")
            }
            end = lineStart > 0 ? lineStart - 1 : 0
        }
        return m
    }

    private func register(_ c: Choice) -> Int { actions.append(c.run); return actions.count - 1 }

    private func button(_ c: Choice, filled: Bool, _ p: Palette) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(tap(_:)))
        b.tag = register(c)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 3
        let font = NSFont.systemFont(ofSize: 13, weight: filled ? .semibold : .regular)
        b.attributedTitle = NSAttributedString(string: c.title, attributes: [.font: font, .foregroundColor: filled ? p.paper : p.ink])
        if filled { b.layer?.backgroundColor = p.ink.cgColor } else { b.layer?.borderWidth = 1; b.layer?.borderColor = p.line.cgColor }
        let w = min(ceil(b.attributedTitle.size().width) + 24, textWidth)
        b.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: w), b.heightAnchor.constraint(equalToConstant: 28)])
        return b
    }

    private func link(_ c: Choice, _ p: Palette) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(tap(_:)))
        b.tag = register(c)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: c.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: p.mid,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: p.line])
        return b
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
