import AppKit
import RedpenCore

/// The card that opens when an underline is clicked: a proofreader's note. The correction is set in the
/// Mac's serif (New York) the way a red pen marks a proof, the lesson reads as a sentence, and the actions
/// stay quiet. It never takes focus from the app being typed in.
final class SuggestionPanel: NSObject {
    private let panel: NSPanel
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

    /// `next`: in the Keyboard style, the card moves on to the next mistake after this choice runs.
    struct Choice { let title: String; var next = false; let run: () -> Void }

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
        /// Quiet links, such as Add to dictionary.
        var footer: [Choice] = []
        /// What is wrong in a few words ("Misspelled word"), for the Whole sentence style.
        var title: String? = nil
        /// The sentence holding the mistake and the mistake's range inside it.
        var sentence: (text: String, range: NSRange)? = nil
        /// This mistake's place among all of them in the field: (1, 4) is "1 of 4".
        var position: (Int, Int)? = nil
        var ignore: Choice? = nil
        var fixAll: (count: Int, choice: Choice)? = nil
        /// Opens the next (1) or previous (-1) mistake, or the one now at this spot (0) after a fix.
        var onStep: ((Int) -> Void)? = nil
        /// Whether Return, Esc and Tab may go to the card. Off for the Terminal card, which opens while you type,
        /// so Return still runs your command.
        var takesKeys = true
    }

    /// "roomy", "sentence" or "keyboard", from the settings.
    var style = "roomy"
    private var current: Card?
    private var shownAt: (anchor: CGRect, avoid: [CGRect])?
    private var whyOpen = false
    private var keyTap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    // Paper and ink, light and dark.
    private struct Palette { let paper, ink, mid, line, soft, fix: NSColor }
    private var palette: Palette {
        // Dark: near-white ink and a light grey for secondary text, so nothing on the card reads dim.
        return dark
            ? Palette(paper: NSColor(srgbRed: 0.118, green: 0.122, blue: 0.137, alpha: 1), ink: NSColor(srgbRed: 0.980, green: 0.976, blue: 0.965, alpha: 1),
                      mid: NSColor(srgbRed: 0.82, green: 0.83, blue: 0.85, alpha: 1), line: NSColor(white: 1, alpha: 0.18),
                      soft: NSColor(white: 1, alpha: 0.06), fix: NSColor(srgbRed: 0.33, green: 0.78, blue: 0.53, alpha: 0.24))
            : Palette(paper: NSColor(srgbRed: 0.988, green: 0.988, blue: 0.980, alpha: 1), ink: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.122, alpha: 1),
                      mid: NSColor(srgbRed: 0.36, green: 0.38, blue: 0.43, alpha: 1), line: NSColor(white: 0, alpha: 0.12),
                      soft: NSColor(white: 0, alpha: 0.045), fix: NSColor(srgbRed: 0.12, green: 0.55, blue: 0.32, alpha: 0.16))
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

    private var width: CGFloat { style == "keyboard" ? 460 : style == "sentence" ? 440 : 420 }
    private var inset: CGFloat { style == "roomy" ? 24 : 22 }
    private var textWidth: CGFloat { width - inset * 2 }

    /// `anchor` is the underline's rect; `avoid` holds the other underlines, which the card tries not to cover.
    func show(_ card: Card, below anchor: CGRect, avoid: [CGRect] = []) {
        whyOpen = false
        present(card, anchor, avoid)
    }

    private func present(_ card: Card, _ anchor: CGRect, _ avoid: [CGRect]) {
        current = card
        shownAt = (anchor, avoid)
        let (box, size) = build(card)
        panel.contentView = box

        var origin = CGPoint(x: anchor.minX - inset + 2, y: anchor.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main {
            origin = CardPlacement.origin(anchor: anchor, size: size, visible: screen.visibleFrame, avoid: avoid, inset: inset)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        if style == "keyboard" && card.takesKeys { installKeys() } else { removeKeys() }

        if outsideMonitor == nil {
            // Left clicks are the watcher's call (a click on the same word keeps the card, on another word
            // switches it). Typing or a right-click, which opens the app's own menu, closes it. In the Keyboard
            // style Return, Esc and Tab belong to the card and never reach here.
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .keyDown]) { [weak self] e in
                guard let self else { return }
                if e.type == .keyDown, self.keyTap != nil, Self.cardKeys.contains(Int(e.keyCode)) { return }
                self.hide()
            }
        }
    }

    /// Draws a card into a PNG without showing it, for checking type and layout from the command line.
    static func render(_ card: Card, appearance: String, style: String = "roomy", to path: String) {
        let p = SuggestionPanel()
        p.appearance = appearance
        p.style = style
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
        choices = []
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var card = card
        // The mark colours are tuned for paper; lift them on the dark card so the fix word stays easy to read.
        if dark { card.color = card.color.blended(withFraction: 0.35, of: .white) ?? card.color }

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = p.paper.cgColor
        box.layer?.cornerRadius = 4
        box.layer?.borderWidth = 1
        box.layer?.borderColor = p.line.cgColor
        box.layer?.masksToBounds = true

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 0
        outer.translatesAutoresizingMaskIntoConstraints = false
        switch style {
        case "sentence": sentenceCard(card, p, outer)
        case "keyboard": keyboardCard(card, p, outer)
        default: roomyCard(card, p, outer)
        }

        box.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            outer.topAnchor.constraint(equalTo: box.topAnchor),
            outer.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            outer.widthAnchor.constraint(equalToConstant: width),
        ])
        box.layoutSubtreeIfNeeded()
        return (box, outer.fittingSize)
    }

    // MARK: - The three styles

    /// Roomy note: the proofreader's mark large, the lesson under a thin rule.
    private func roomyCard(_ card: Card, _ p: Palette, _ outer: NSStackView) {
        let s = section(top: 20, bottom: 18, spacing: 14)
        let close = Choice(title: "Close") { }
        s.addArrangedSubview(spread(kindLabel(card), link(close, p, size: 13)))
        s.addArrangedSubview(wrapping(markText(card, p, size: card.marks.count > 1 ? 19 : 29)))
        if let msg = card.message { s.addArrangedSubview(wrapping(serifText(msg, 19, p.ink))) }
        var buttons = buttonsFor(card, p, height: 40, size: 15, primaryTitle: nil, altPrefix: "")
        if let ig = card.ignore { buttons.append(button(ig, filled: false, p, height: 40, size: 15)) }
        if !buttons.isEmpty { s.addArrangedSubview(row(buttons, spacing: 8)) }
        if let lesson = lessonText(card, p, size: 17, countSize: 13) {
            s.addArrangedSubview(rule(p))
            s.setCustomSpacing(12, after: s.arrangedSubviews.last!)
            s.addArrangedSubview(wrapping(lesson))
        }
        var links: [NSView] = []
        if let f = card.fixAll { links.append(link(Choice(title: "Fix all \(f.count) sure mistakes in this paragraph", run: f.choice.run), p, size: 14)) }
        links += card.footer.map { link($0, p, size: 14) }
        if !links.isEmpty { s.addArrangedSubview(row(links, spacing: 20)) }
        outer.addArrangedSubview(s)
    }

    /// Whole sentence: a plain title, the sentence with the fix shown in place, the lesson behind "Why?".
    private func sentenceCard(_ card: Card, _ p: Palette, _ outer: NSStackView) {
        let s = section(top: 18, bottom: 0, spacing: 12)
        let title = NSTextField(labelWithAttributedString: NSAttributedString(string: card.title ?? card.kind, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: p.ink]))
        s.addArrangedSubview(spread(title, kindLabel(card)))
        if let sent = card.sentence, let fix = card.marks.first?.new {
            let ns = sent.text as NSString
            let t = NSMutableAttributedString(string: ns.substring(to: sent.range.location), attributes: [.font: Self.serif(19), .foregroundColor: p.ink])
            t.append(NSAttributedString(string: ns.substring(with: sent.range), attributes: [
                .font: Self.serif(19), .foregroundColor: p.mid,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: card.color]))
            t.append(NSAttributedString(string: " ", attributes: [.font: Self.serif(19)]))
            t.append(NSAttributedString(string: fix.isEmpty ? "(cut)" : fix, attributes: [
                .font: Self.serif(19, weight: .medium), .foregroundColor: p.ink, .backgroundColor: p.fix]))
            t.append(NSAttributedString(string: ns.substring(from: NSMaxRange(sent.range)), attributes: [.font: Self.serif(19), .foregroundColor: p.ink]))
            t.addAttribute(.paragraphStyle, value: lines(1.3), range: NSRange(location: 0, length: t.length))
            s.addArrangedSubview(tinted(wrapping(t, width: textWidth - 32), p.soft))
        } else {
            s.addArrangedSubview(wrapping(markText(card, p, size: card.marks.count > 1 ? 18 : 26)))
        }
        let msg = [card.message, card.count >= 2 ? "You\u{2019}ve fixed this \(card.count) times this month." : nil].compactMap { $0 }.joined(separator: " ")
        if !msg.isEmpty { s.addArrangedSubview(wrapping(serifText(msg, 17, p.mid))) }
        if card.why != nil || card.example?.isEmpty == false {
            if whyOpen, let lesson = lessonText(card, p, size: 16.5, countSize: 0) {
                s.addArrangedSubview(wrapping(lesson))
            } else {
                let why = Choice(title: "Why?") { [weak self] in
                    guard let self, let c = self.current, let at = self.shownAt else { return }
                    self.whyOpen = true
                    self.present(c, at.anchor, at.avoid)
                }
                s.addArrangedSubview(link(why, p, size: 13.5, keepOpen: true))
            }
        }
        var buttons = buttonsFor(card, p, height: 40, size: 15, primaryTitle: "Accept", altPrefix: "Use ")
        if let ig = card.ignore { buttons.append(button(Choice(title: "Dismiss", next: ig.next, run: ig.run), filled: false, p, height: 40, size: 15)) }
        if !buttons.isEmpty { s.setCustomSpacing(16, after: s.arrangedSubviews.last!); s.addArrangedSubview(row(buttons, spacing: 8)) }
        outer.addArrangedSubview(s)

        var left: [NSView] = card.footer.map { link($0, p, size: 13.5) }
        if left.isEmpty, let f = card.fixAll {
            left = [NSTextField(labelWithAttributedString: NSAttributedString(string: "\(f.count) sure mistakes in this paragraph", attributes: [
                .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: p.mid]))]
        }
        let right = card.fixAll.map { button(Choice(title: "Fix all \($0.count)", run: $0.choice.run), filled: false, p, height: 32, size: 14) }
        if !left.isEmpty || right != nil { outer.addArrangedSubview(strip(left, right, p, top: 16, ruled: true)) }
        else { outer.addArrangedSubview(spacer(18)) }
    }

    /// Keyboard: "1 of 4" with arrows; Return accepts, Esc skips, Tab moves on.
    private func keyboardCard(_ card: Card, _ p: Palette, _ outer: NSStackView) {
        var head: [NSView] = [kindLabel(card)]
        if let pos = card.position {
            head.append(NSTextField(labelWithAttributedString: NSAttributedString(string: "\(pos.0) of \(pos.1)", attributes: [
                .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: p.mid])))
        }
        var nav: NSView?
        if let step = card.onStep, (card.position?.1 ?? 0) > 1 {
            nav = row([button(Choice(title: "\u{2039}") { step(-1) }, filled: false, p, height: 28, size: 15, minWidth: 30),
                       button(Choice(title: "\u{203A}") { step(1) }, filled: false, p, height: 28, size: 15, minWidth: 30)], spacing: 4)
        }
        outer.addArrangedSubview(strip(head, nav, p, top: 0, ruled: false, underline: true, background: false, vertical: 10, sideInset: 18))

        let s = section(top: 18, bottom: 0, spacing: 10)
        s.addArrangedSubview(wrapping(markText(card, p, size: card.marks.count > 1 ? 19 : 27)))
        if let msg = card.message { s.addArrangedSubview(wrapping(serifText(msg, 18, p.ink))) }
        if let lesson = lessonText(card, p, size: 16.5, countSize: 0) { s.addArrangedSubview(wrapping(lesson)) }
        if !card.alts.isEmpty {
            s.addArrangedSubview(row(card.alts.prefix(3).map { a in
                button(Choice(title: "or \u{201C}\(a.title)\u{201D}", next: a.next, run: a.run), filled: false, p, height: 34, size: 14)
            }, spacing: 8))
        }
        var buttons: [NSView] = []
        if let pc = card.primary { buttons.append(button(Choice(title: "Accept", next: pc.next, run: pc.run), filled: true, p, height: 40, size: 15, hint: "Return")) }
        if let ig = card.ignore { buttons.append(button(Choice(title: "Skip", next: ig.next, run: ig.run), filled: false, p, height: 40, size: 15, hint: "Esc")) }
        if let f = card.fixAll { buttons.append(button(Choice(title: "Fix all \(f.count)", run: f.choice.run), filled: false, p, height: 40, size: 15, hint: "\u{2303}\u{2325}\u{21E7}R")) }
        if !buttons.isEmpty { s.setCustomSpacing(16, after: s.arrangedSubviews.last!); s.addArrangedSubview(row(buttons, spacing: 8)) }
        outer.addArrangedSubview(s)

        var left: [NSView] = []
        if card.onStep != nil, (card.position?.1 ?? 0) > 1 {
            left.append(NSTextField(labelWithAttributedString: NSAttributedString(string: "Tab for the next mistake", attributes: [
                .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: p.mid])))
        }
        left += card.footer.map { link($0, p, size: 13.5) }
        let right: NSView? = card.count >= 2 ? NSTextField(labelWithAttributedString: NSAttributedString(
            string: "Fixed \(card.count) times this month", attributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .medium), .foregroundColor: card.color])) : nil
        if !left.isEmpty || right != nil { outer.addArrangedSubview(strip(left, right, p, top: 16, ruled: false)) }
        else { outer.addArrangedSubview(spacer(18)) }
    }

    // MARK: - Pieces

    private func section(top: CGFloat, bottom: CGFloat, spacing: CGFloat) -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.edgeInsets = NSEdgeInsets(top: top, left: inset, bottom: bottom, right: inset)
        return s
    }

    private func kindLabel(_ card: Card) -> NSView {
        NSTextField(labelWithAttributedString: NSAttributedString(string: card.kind.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: card.color, .kern: 0.9]))
    }

    /// The mark: old text struck through, the fix in italic beside it.
    private func markText(_ card: Card, _ p: Palette, size: CGFloat) -> NSAttributedString {
        let mark = NSMutableAttributedString()
        for (i, m) in card.marks.enumerated() {
            if i > 0 { mark.append(NSAttributedString(string: "\n")) }
            if let new = m.new {
                mark.append(NSAttributedString(string: m.old, attributes: [
                    .font: Self.serif(size), .foregroundColor: p.mid,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: card.color]))
                mark.append(NSAttributedString(string: "   "))
                mark.append(NSAttributedString(string: new.isEmpty ? "(cut)" : new, attributes: [
                    .font: Self.serif(size, italic: true, weight: .medium), .foregroundColor: card.color]))
            } else {
                mark.append(NSAttributedString(string: m.old, attributes: [
                    .font: Self.serif(size - 2), .foregroundColor: p.ink,
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: card.color]))
            }
        }
        mark.addAttribute(.paragraphStyle, value: lines(1.1), range: NSRange(location: 0, length: mark.length))
        return mark
    }

    private func serifText(_ s: String, _ size: CGFloat, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Self.serif(size), .foregroundColor: color, .paragraphStyle: lines(1.35)])
    }

    /// The rule, its example and how often you have made this mistake. `countSize` 0 leaves the count out.
    private func lessonText(_ card: Card, _ p: Palette, size: CGFloat, countSize: CGFloat) -> NSAttributedString? {
        let why = NSMutableAttributedString()
        if let w = card.why { why.append(NSAttributedString(string: w, attributes: [.font: Self.serif(size), .foregroundColor: p.mid])) }
        if let ex = card.example, !ex.isEmpty {
            why.append(NSAttributedString(string: (why.length > 0 ? "\n" : "") + ex, attributes: [.font: Self.serif(size, italic: true), .foregroundColor: p.ink]))
        }
        if countSize > 0, card.count >= 2 {
            why.append(NSAttributedString(string: (why.length > 0 ? "\n" : "") + "You\u{2019}ve fixed this \(card.count) times in the last 30 days.",
                                          attributes: [.font: NSFont.systemFont(ofSize: countSize, weight: .medium), .foregroundColor: card.color]))
        }
        guard why.length > 0 else { return nil }
        why.addAttribute(.paragraphStyle, value: lines(1.35), range: NSRange(location: 0, length: why.length))
        return why
    }

    /// The fix as the dark button, other fixes outlined beside it.
    private func buttonsFor(_ card: Card, _ p: Palette, height: CGFloat, size: CGFloat, primaryTitle: String?, altPrefix: String) -> [NSView] {
        var out: [NSView] = []
        if let pc = card.primary { out.append(button(primaryTitle.map { Choice(title: $0, next: pc.next, run: pc.run) } ?? pc, filled: true, p, height: height, size: size)) }
        for a in card.alts.prefix(3) {
            let t = altPrefix.isEmpty ? a.title : "\(altPrefix)\u{201C}\(a.title)\u{201D}"
            out.append(button(Choice(title: t, next: a.next, run: a.run), filled: false, p, height: height, size: size))
        }
        return out
    }

    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = spacing
        return r
    }

    /// Two views at opposite ends of the text width.
    private func spread(_ left: NSView, _ right: NSView) -> NSView {
        let r = NSStackView(views: [firm(left), gap(), firm(right)])
        r.orientation = .horizontal
        r.alignment = .firstBaseline
        r.distribution = .fill
        r.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return r
    }

    /// A full-width band: links or a note on the left, one control on the right.
    private func strip(_ left: [NSView], _ right: NSView?, _ p: Palette, top: CGFloat, ruled: Bool,
                       underline: Bool = false, background: Bool = true, vertical: CGFloat = 11, sideInset: CGFloat? = nil) -> NSView {
        let side = sideInset ?? inset
        let band = NSView()
        band.wantsLayer = true
        if background && !ruled { band.layer?.backgroundColor = p.soft.cgColor }
        band.translatesAutoresizingMaskIntoConstraints = false
        var items = left.map(firm)
        items.append(gap())
        if let right { items.append(firm(right)) }
        let r = NSStackView(views: items)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 16
        r.translatesAutoresizingMaskIntoConstraints = false
        band.addSubview(r)
        NSLayoutConstraint.activate([
            r.leadingAnchor.constraint(equalTo: band.leadingAnchor, constant: side),
            r.trailingAnchor.constraint(equalTo: band.trailingAnchor, constant: -side),
            r.topAnchor.constraint(equalTo: band.topAnchor, constant: vertical),
            r.bottomAnchor.constraint(equalTo: band.bottomAnchor, constant: -vertical),
            band.widthAnchor.constraint(equalToConstant: width),
        ])
        if ruled || underline {
            let l = NSView(); l.wantsLayer = true; l.layer?.backgroundColor = p.line.cgColor
            l.translatesAutoresizingMaskIntoConstraints = false
            band.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: band.leadingAnchor), l.trailingAnchor.constraint(equalTo: band.trailingAnchor),
                l.heightAnchor.constraint(equalToConstant: 1),
                ruled ? l.topAnchor.constraint(equalTo: band.topAnchor) : l.bottomAnchor.constraint(equalTo: band.bottomAnchor),
            ])
        }
        guard top > 0 else { return band }
        let wrap = NSStackView(views: [spacer(top), band])
        wrap.orientation = .vertical
        wrap.spacing = 0
        return wrap
    }

    /// Keeps a label or control at its natural width in a row; the gap beside it takes the slack.
    private func firm(_ v: NSView) -> NSView {
        if let t = v as? NSTextField {
            t.widthAnchor.constraint(equalToConstant: ceil(t.attributedStringValue.size().width) + 4).isActive = true
        }
        v.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        v.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return v
    }

    private func gap() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func rule(_ p: Palette) -> NSView {
        let l = NSView(); l.wantsLayer = true; l.layer?.backgroundColor = p.line.cgColor
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([l.heightAnchor.constraint(equalToConstant: 1), l.widthAnchor.constraint(equalToConstant: textWidth)])
        return l
    }

    /// A text block on a soft tinted ground, padded.
    private func tinted(_ content: NSView, _ color: NSColor) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = color.cgColor
        v.layer?.cornerRadius = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: v.topAnchor, constant: 13),
            content.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -13),
            v.widthAnchor.constraint(equalToConstant: textWidth),
        ])
        return v
    }

    // MARK: - Keys (Keyboard style)

    private static let cardKeys: Set<Int> = [36, 76, 53, 48]  // Return, Enter, Esc, Tab

    /// While a Keyboard card is open, Return, Esc and Tab go to the card instead of the app. Every other key
    /// passes through and closes the card as usual.
    private func installKeys() {
        guard keyTap == nil else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let card = Unmanaged<SuggestionPanel>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = card.keyTap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let back = event.flags.contains(.maskShift)
            guard event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
                  card.handles(code) else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { card.key(code, back: back) }
            return nil
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                          callback: callback, userInfo: me) else {
            Log.note("card keys: no event tap"); return
        }
        keyTap = tap
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeKeys() {
        guard let tap = keyTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        keyTap = nil; tapSource = nil
    }

    private func handles(_ code: Int) -> Bool {
        guard panel.isVisible, let c = current else { return false }
        switch code {
        case 36, 76: return c.primary != nil
        case 53: return true
        case 48: return c.onStep != nil && (c.position?.1 ?? 0) > 1
        default: return false
        }
    }

    private func key(_ code: Int, back: Bool) {
        guard let c = current else { return }
        switch code {
        case 36, 76: if let pc = c.primary { choose(pc) }
        case 53: if let ig = c.ignore { choose(ig) } else { hide() }
        case 48: hide(); c.onStep?(back ? -1 : 1)
        default: break
        }
    }

    /// Runs a choice; in the Keyboard style a fix or skip moves straight on to the next mistake.
    private func choose(_ c: Choice) {
        let step = style == "keyboard" && c.next ? current?.onStep : nil
        hide()
        c.run()
        step?(0)
    }

    private func lines(_ multiple: CGFloat) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle(); s.lineHeightMultiple = multiple
        s.lineBreakStrategy = [.pushOut, .standard]  // no single word alone on the last line
        return s
    }

    private func wrapping(_ s: NSAttributedString, width: CGFloat? = nil) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: "")
        f.attributedStringValue = Self.joinLastWords(s)
        f.preferredMaxLayoutWidth = width ?? textWidth
        f.widthAnchor.constraint(equalToConstant: width ?? textWidth).isActive = true
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

    private var choices: [Choice] = []
    private func register(_ c: Choice) -> Int { choices.append(c); return choices.count - 1 }

    private func button(_ c: Choice, filled: Bool, _ p: Palette, height: CGFloat, size: CGFloat, hint: String? = nil, minWidth: CGFloat = 0) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(tap(_:)))
        b.tag = register(c)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 3
        let ink = filled ? p.paper : p.ink
        let t = NSMutableAttributedString(string: c.title, attributes: [.font: NSFont.systemFont(ofSize: size, weight: filled ? .semibold : .regular), .foregroundColor: ink])
        if let hint {
            t.append(NSAttributedString(string: "  " + hint, attributes: [.font: NSFont.systemFont(ofSize: size - 4, weight: .medium), .foregroundColor: ink.withAlphaComponent(0.65)]))
        }
        b.attributedTitle = t
        if filled { b.layer?.backgroundColor = p.ink.cgColor } else { b.layer?.borderWidth = 1; b.layer?.borderColor = p.line.cgColor }
        let w = min(max(ceil(t.size().width) + (height >= 40 ? 32 : 24), minWidth), textWidth)
        b.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: w), b.heightAnchor.constraint(equalToConstant: height)])
        return b
    }

    /// `keepOpen`: the choice changes the card itself (Why?) instead of acting and closing it.
    private func link(_ c: Choice, _ p: Palette, size: CGFloat, keepOpen: Bool = false) -> NSButton {
        let b = NSButton(title: "", target: self, action: keepOpen ? #selector(tapInPlace(_:)) : #selector(tap(_:)))
        b.tag = register(c)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: c.title, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: p.mid,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: p.line])
        return b
    }

    @objc private func tap(_ sender: NSButton) { choose(choices[sender.tag]) }
    @objc private func tapInPlace(_ sender: NSButton) { choices[sender.tag].run() }

    func hide() {
        panel.orderOut(nil)
        removeKeys()
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }
}
