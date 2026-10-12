import AppKit
import ApplicationServices

/// Thin helpers over the macOS Accessibility API, which is how Redpen reads and edits other apps' text.
enum AX {
    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func range(_ el: AXUIElement, _ name: String) -> NSRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    static func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Element frame in Accessibility coordinates (origin top-left of the main screen).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Screen rect of a text range, in Accessibility coordinates.
    static func bounds(_ el: AXUIElement, for r: NSRange) -> CGRect? {
        var cf = CFRange(location: r.location, length: r.length)
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, param, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }

    static func param(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &v) == .success ? v : nil
    }

    static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.width > 0 || r.height > 0 else { return nil }
        return r
    }

    static func string(_ el: AXUIElement, for r: NSRange) -> String? {
        var cf = CFRange(location: r.location, length: r.length)
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &v) == .success
        else { return nil }
        return v as? String
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }

    static func setRange(_ el: AXUIElement, _ r: NSRange) -> Bool {
        var cf = CFRange(location: r.location, length: r.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return false }
        return set(el, kAXSelectedTextRangeAttribute, v)
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        return p
    }

    /// Converts an Accessibility rect (top-left origin) to a Cocoa screen rect (bottom-left origin).
    static func toCocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func toAX(_ p: CGPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }
}
