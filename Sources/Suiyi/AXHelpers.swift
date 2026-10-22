import AppKit
import ApplicationServices

/// Small, type-checked wrappers around the Accessibility C API.
@MainActor
enum AX {
    static let timeout: Float = 0.25

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = axValue(element, attribute), AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute), AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute), AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    /// The element of `appElement`'s app under a Cocoa screen point (bottom-left origin).
    static func element(at point: NSPoint, in appElement: AXUIElement) -> AXUIElement? {
        let primaryHeight = ScreenGeometry.primaryScreenHeight
        guard primaryHeight > 0 else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(primaryHeight - point.y), &hit) == .success
        else { return nil }
        return hit
    }

    /// 0.2.1.k.02: the selection of a WebKit / Chromium web area through text markers
    /// (AXSelectedTextMarkerRange + AXStringForTextMarkerRange), the route screen readers use. It
    /// reads ordinary page text, where kAXSelectedText is often empty, without touching the clipboard.
    static func webSelectedText(_ webArea: AXUIElement) -> String? {
        guard let range = copy(webArea, "AXSelectedTextMarkerRange") else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(webArea, "AXStringForTextMarkerRange" as CFString, range, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    /// Element frame converted to Cocoa screen coordinates (bottom-left origin).
    static func cocoaFrame(of element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute),
              let size = size(element, kAXSizeAttribute),
              size.width > 1, size.height > 1 else { return nil }
        let primaryHeight = ScreenGeometry.primaryScreenHeight
        guard primaryHeight > 0 else { return nil }
        return CGRect(x: origin.x, y: primaryHeight - origin.y - size.height,
                      width: size.width, height: size.height)
    }
}
