import AppKit
import CoreGraphics

/// Pasteboard snapshot/restore plus synthetic ⌘C / ⌘V.
@MainActor
enum Clipboard {
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static let copyKey: CGKeyCode = 8    // kVK_ANSI_C
    private static let pasteKey: CGKeyCode = 9   // kVK_ANSI_V
    /// Convention honoured by most clipboard managers: "don't record this".
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func snapshot() -> Snapshot {
        let items = NSPasteboard.general.pasteboardItems ?? []
        return items.map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    static func restore(_ snapshot: Snapshot) {
        let pasteboard = NSPasteboard.general
        // 0.2.1.k.01: put the user's clipboard back on this Mac only (no Universal Clipboard hand-off).
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        var items: [NSPasteboardItem] = []
        for entries in snapshot where !entries.isEmpty {
            let item = NSPasteboardItem()
            for (type, data) in entries {
                item.setData(data, forType: type)
            }
            items.append(item)
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    static func postShortcut(_ key: CGKeyCode, flags: CGEventFlags = .maskCommand) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Sends ⌘C to the frontmost app, waits up to 1 s for the pasteboard to
    /// change, reads the string and puts the user's original clipboard back.
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        // 0.2.1.k.01: the clipboard holds something a password manager copied (and may be about
        // to auto-clear): leave it alone rather than copy over it and write it back.
        if SensitiveGuard.isSensitivePasteboard(types: (pasteboard.types ?? []).map(\.rawValue)) { return nil }
        let saved = snapshot()
        let before = pasteboard.changeCount
        postShortcut(copyKey)

        // Slow apps get up to 1 s, so a late copy is still restored rather than left behind.
        let deadline = Date().addingTimeInterval(1.0)
        var changed = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != before {
                changed = true
                break
            }
        }
        guard changed else { return nil }
        // Give the source app a moment to finish writing all representations.
        try? await Task.sleep(nanoseconds: 30_000_000)
        // 0.2.1.k.01: a password manager marked this copy as concealed/transient: do not use it.
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let text = SensitiveGuard.isSensitivePasteboard(types: types) ? nil : pasteboard.string(forType: .string)
        restore(saved)
        return text
    }

    /// Puts `text` on the pasteboard, sends ⌘V, then restores the clipboard.
    static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = snapshot()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        pasteboard.writeObjects([item])
        postShortcut(pasteKey)
        try? await Task.sleep(nanoseconds: 450_000_000)
        restore(saved)
    }
}
