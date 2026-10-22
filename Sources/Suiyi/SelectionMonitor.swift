import AppKit

enum GestureKind {
    case drag
    case multiClick
}

struct SelectionGesture {
    let kind: GestureKind
    let down: NSPoint
    let up: NSPoint
}

/// Watches global left-mouse events and reports gestures that probably
/// selected text: a drag of more than 6 pt, or a double/triple click.
@MainActor
final class SelectionMonitor {
    var onMouseDown: (@MainActor (NSPoint) -> Void)?
    var onSelection: (@MainActor (SelectionGesture) -> Void)?

    private var monitor: Any?
    private var downPoint = NSPoint.zero
    private var maxDistance: CGFloat = 0
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
            onMouseDown?(location)
        case .leftMouseDragged:
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
            let gesture = SelectionGesture(kind: kind, down: downPoint, up: location)
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
