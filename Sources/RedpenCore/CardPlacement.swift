import CoreGraphics

/// Where the fix card goes, and what a click does while it is open. Pure geometry, so it can be tested
/// without a screen. All rects are in Cocoa screen coordinates (origin bottom-left).
public enum CardPlacement {
    /// Below the flagged word by default, above it when below would run off the screen or cover another
    /// underline that above would not. A card over a nearby mistake invites a click meant for that word.
    public static func origin(anchor: CGRect, size: CGSize, visible: CGRect, avoid: [CGRect],
                              inset: CGFloat = 18, gap: CGFloat = 6) -> CGPoint {
        let x = min(max(anchor.minX - inset + 2, visible.minX + 4), visible.maxX - size.width - 4)
        let below = CGPoint(x: x, y: anchor.minY - size.height - gap)
        let above = CGPoint(x: x, y: anchor.maxY + gap)
        func fits(_ p: CGPoint) -> Bool { p.y >= visible.minY && p.y + size.height <= visible.maxY }
        func covered(_ p: CGPoint) -> Int {
            let card = CGRect(origin: p, size: size)
            return avoid.filter { $0 != anchor && card.intersects($0) }.count
        }
        let options = [below, above].filter(fits)
        guard !options.isEmpty else { return fits(above) || below.y < visible.minY ? above : below }
        return options.min { covered($0) < covered($1) } ?? below  // min keeps the first on a tie: below wins
    }

    public enum ClickAction: Equatable { case open, keep, close, ignore }

    /// What a left click does. `hitSame` is a click on the mistake whose card is already open, which is the
    /// second click of a double-click: the card stays while the app selects the word.
    public static func onClick(cardOpen: Bool, hit: Bool, hitSame: Bool) -> ClickAction {
        switch (cardOpen, hit) {
        case (false, true): return .open
        case (false, false): return .ignore
        case (true, true): return hitSame ? .keep : .open
        case (true, false): return .close
        }
    }
}
