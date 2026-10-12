import ApplicationServices

/// Chrome's rich editors (Gmail, LinkedIn, Docs comments) give no word positions through the normal call.
/// Their text lives in static-text pieces under the editor. Redpen finds the piece holding the error, walks
/// "text markers" inside it one character at a time, and asks for the bounds of that marker range.
final class MarkerWalker {
    struct Leaf { let element: AXUIElement; let start: Int; let length: Int }
    private var element: AXUIElement?
    private var text = ""
    private var leaves: [Leaf] = []
    private var markerCache: [Int: [CFTypeRef]] = [:]  // leaf index -> markers from its start

    func bounds(_ el: AXUIElement, text: String, range r: NSRange) -> CGRect? {
        if element == nil || !CFEqual(element!, el) || self.text != text {
            element = el
            self.text = text
            leaves = findLeaves(el, text)
            markerCache = [:]
        }
        guard let li = leaves.firstIndex(where: { r.location >= $0.start && r.location < $0.start + $0.length }) else { return nil }
        let leaf = leaves[li]
        let local = r.location - leaf.start
        let end = min(local + r.length, leaf.length)
        var markers = markerCache[li] ?? []
        if markers.isEmpty {
            guard let whole = AX.param(leaf.element, "AXTextMarkerRangeForUIElement", leaf.element),
                  CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return nil }
            markers = [AXTextMarkerRangeCopyStartMarker(whole as! AXTextMarkerRange)]
        }
        while markers.count <= end {
            guard let next = AX.param(leaf.element, "AXNextTextMarkerForTextMarker", markers[markers.count - 1]) else { return nil }
            markers.append(next)
        }
        markerCache[li] = markers
        guard let range = AX.param(leaf.element, "AXTextMarkerRangeForUnorderedTextMarkers", [markers[local], markers[end]] as CFArray)
        else { return nil }
        return AX.rect(AX.param(leaf.element, "AXBoundsForTextMarkerRange", range))
    }

    /// Static-text descendants in reading order, each placed at its offset in the editor's full text.
    private func findLeaves(_ root: AXUIElement, _ text: String) -> [Leaf] {
        var out: [Leaf] = []
        let ns = text as NSString
        var cursor = 0
        var visited = 0
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 25, visited < 3000 else { return }
            visited += 1
            let role: String = AX.attr(e, kAXRoleAttribute) ?? ""
            if role == "AXStaticText", let v: String = AX.attr(e, kAXValueAttribute), !v.isEmpty {
                let found = ns.range(of: v, range: NSRange(location: cursor, length: ns.length - cursor))
                if found.location != NSNotFound {
                    out.append(Leaf(element: e, start: found.location, length: found.length))
                    cursor = NSMaxRange(found)
                }
                return
            }
            for c in (AX.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return out
    }
}
