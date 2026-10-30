import AppKit

enum GestureKind {
    case drag
    case multiClick
}

struct SelectionGesture {
    let kind: GestureKind
    let down: NSPoint
    let up: NSPoint
    /// 0.2.1.k.10: the window under the pointer when the drag began, to tell a moved or resized
    /// window from a text selection.
    var startWindow: WindowProbe.Snapshot? = nil
}

/// Watches global left-mouse events and reports gestures that probably
/// selected text: a drag of more than 6 pt, or a double/triple click.
@MainActor
final class SelectionMonitor {
    var onMouseDown: (@MainActor (NSPoint) -> Void)?
    var onSelection: (@MainActor (SelectionGesture) -> Void)?
    /// 0.2.1.k.11: whether the window snapshot can be used at all (not paused, button on, …);
    /// false skips the window-server query.
    var wantsWindowSnapshot: (@MainActor () -> Bool)?

    private var monitor: Any?
    private var downPoint = NSPoint.zero
    private var maxDistance: CGFloat = 0
    private var dragging = false
    private var startWindow: WindowProbe.Snapshot?
    private var pending: Task<Void, Never>?

    private static let dragThreshold: CGFloat = 6
    private static let settleDelay: UInt64 = 120_000_000

    init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        ) { [weak self] event in
            // Global monitors are delivered on the main thread.
            MainActor.assumeIsolated {
                guard let monitor = self else { return }
                monitor.handle(event)
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pending?.cancel()
    }

    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func handle(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            pending?.cancel()
            downPoint = location
            maxDistance = 0
            dragging = false
            startWindow = nil
            onMouseDown?(location)
        case .leftMouseDragged:
            if !dragging {
                dragging = true
                if wantsWindowSnapshot?() ?? true { startWindow = WindowProbe.window(at: downPoint) }
            }
            maxDistance = max(maxDistance, distance(location, downPoint))
        case .leftMouseUp:
            let travelled = max(maxDistance, distance(location, downPoint))
            let kind: GestureKind
            if travelled > Self.dragThreshold {
                kind = .drag
            } else if event.clickCount >= 2 {
                kind = .multiClick
            } else {
                return
            }
            let gesture = SelectionGesture(kind: kind, down: downPoint, up: location,
                                           startWindow: kind == .drag ? startWindow : nil)
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: SelectionMonitor.settleDelay)
                guard !Task.isCancelled, let self else { return }
                self.onSelection?(gesture)
            }
        default:
            break
        }
    }
}

/// Window-server bounds of on-screen windows (reading bounds needs no extra permission).
@MainActor
enum WindowProbe {
    struct Snapshot: Equatable {
        let number: CGWindowID
        let bounds: CGRect
    }

    /// The ordinary window (layer 0, not Suiyi's) under a Cocoa screen point. 0.2.1.k.11: asks the
    /// window server for that one window instead of listing every window on screen.
    static func window(at point: NSPoint) -> Snapshot? {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]])?.first,
              info[kCGWindowLayer as String] as? Int == 0,
              info[kCGWindowOwnerPID as String] as? pid_t != ProcessInfo.processInfo.processIdentifier else { return nil }
        return snapshot(info)
    }

    static func current(_ window: Snapshot) -> Snapshot? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.number) as? [[String: Any]]
        else { return nil }
        return list.first.flatMap(snapshot)
    }

    /// A text selection neither moves nor resizes its window.
    nonisolated static func moved(_ before: Snapshot?, _ after: Snapshot?) -> Bool {
        guard let before, let after, before.number == after.number else { return false }
        let a = before.bounds, b = after.bounds
        return max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height)) > 0.5
    }

    private static func snapshot(_ info: [String: Any]) -> Snapshot? {
        guard let number = info[kCGWindowNumber as String] as? CGWindowID,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
        return Snapshot(number: number, bounds: bounds)
    }
}
