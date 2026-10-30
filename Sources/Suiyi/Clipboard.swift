import AppKit
import CoreGraphics
import Carbon
import UniformTypeIdentifiers

/// Pasteboard snapshot/restore plus synthetic ⌘C / ⌘V.
@MainActor
enum Clipboard {
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static let copyKey: CGKeyCode = 8    // kVK_ANSI_C
    private static let pasteKey: CGKeyCode = 9   // kVK_ANSI_V
    private static let commandKey: CGKeyCode = 55  // kVK_Command
    /// Convention honoured by most clipboard managers: "don't record this".
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// 0.2.1.k.12: a copy of the clipboard that can be put back, or nil when it cannot be copied
    /// cheaply (images, media, PDFs, file promises, or more than a few MB). Reading such data would
    /// make the source app render every format it promised, just to write it back.
    static func snapshot(of pasteboard: NSPasteboard = .general) -> Snapshot? {
        let items = pasteboard.pasteboardItems ?? []
        var total = 0
        var result: Snapshot = []
        for item in items {
            var entries: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard isRestorable(type.rawValue) else { return nil }
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if data.count > 1_000_000 || total > 4_000_000 { return nil }
                entries.append((type, data))
            }
            result.append(entries)
        }
        return result
    }

    /// Text, links, file references and small private types; not images, audio/video, PDFs or promises.
    nonisolated static func isRestorable(_ type: String) -> Bool {
        let lowered = type.lowercased()
        if lowered.contains("promise") { return false }
        if let ut = UTType(type) {
            for heavy in [UTType.image, .audiovisualContent, .pdf, .archive] where ut.conforms(to: heavy) { return false }
        }
        return true
    }

    static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard = .general) {
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

    /// ⌘ down, key down, key up, ⌘ up: what a keyboard sends. 0.2.1.k.09: the key alone with the ⌘
    /// flag made tools that track modifier keys think ⌘ was still held; Try Omarchy then kept Super
    /// pressed in its Linux VM, turning every later keystroke there into a shortcut.
    static func shortcutSequence(_ key: CGKeyCode) -> [(key: CGKeyCode, down: Bool, flags: CGEventFlags)] {
        [(commandKey, true, .maskCommand), (key, true, .maskCommand), (key, false, .maskCommand), (commandKey, false, [])]
    }

    /// 0.2.1.k.12: waits (up to 0.4 s) until the user has let go of ⌘ ⌥ ⌃ ⇧, so the synthetic
    /// "⌘ up" is not sent while ⌘ is physically down (the hot key is ⌥⌘T) and the key is not read
    /// as ⌥⌘C by the app.
    static func waitForModifiersUp() async {
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline, !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Tags Suiyi's own key events, so a ⌘C the user types can be told apart from ours.
    nonisolated static let syntheticMarker: Int64 = 0x5375_6979   // "Suiy"

    static func postShortcut(_ key: CGKeyCode) async {
        await waitForModifiersUp()
        let source = CGEventSource(stateID: .combinedSessionState)
        let events = shortcutSequence(key).compactMap { step -> CGEvent? in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: step.key, keyDown: step.down) else { return nil }
            event.flags = step.flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            return event
        }
        guard events.count == 4 else { return }   // all or nothing: never leave ⌘ down
        for event in events { event.post(tap: .cghidEventTap) }
    }

    /// Sends ⌘C to the frontmost app, waits up to 1 s for the pasteboard to
    /// change, reads the string and puts the user's original clipboard back.
    /// 0.2.7: put back only if nothing wrote to the clipboard after our copy. A user who selects
    /// and presses ⌘C at once used to get their copy overwritten by the older clipboard
    /// (fanyi-site#14: "pasting brings in a lot of other text").
    static func copySelection(on pasteboard: NSPasteboard = .general,
                              settle: UInt64 = 30_000_000,
                              copy: () async -> Void = { await postShortcut(copyKey) }) async -> String? {
        // 0.2.1.k.01: the clipboard holds something a password manager copied (and may be about
        // to auto-clear): leave it alone rather than copy over it and write it back.
        if SensitiveGuard.isSensitivePasteboard(types: (pasteboard.types ?? []).map(\.rawValue)) { return nil }
        let saved = snapshot(of: pasteboard)
        let watch = UserCopyWatch()
        defer { watch.stop() }
        let before = pasteboard.changeCount
        await copy()

        // Slow apps get up to 1 s, so a late copy is still restored rather than left behind.
        let deadline = Date().addingTimeInterval(1.0)
        var changed = false
        while Date() < deadline {
            if pasteboard.changeCount != before {
                changed = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard changed else { return nil }
        let ours = pasteboard.changeCount
        // Give the source app a moment to finish writing all representations.
        try? await Task.sleep(nanoseconds: settle)
        // 0.2.1.k.01: a password manager marked this copy as concealed/transient: do not use it.
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let text = SensitiveGuard.isSensitivePasteboard(types: types) ? nil : pasteboard.string(forType: .string)
        if let saved, shouldRestore(ours: ours, now: pasteboard.changeCount, userPressedCopy: watch.userPressedCopy) {
            restore(saved, to: pasteboard)
        }
        return text
    }

    /// An uncopyable clipboard (an image, a file promise) is left as the app's ⌘C made it. So is a
    /// clipboard written after our copy, or one the user copied to themselves while we waited: that
    /// is the user's own ⌘C and must not be replaced by the older contents.
    nonisolated static func shouldRestore(ours: Int, now: Int, userPressedCopy: Bool) -> Bool {
        now == ours && !userPressedCopy
    }

    /// 0.2.1.k.06: a real ⌘C for the user (right-click on the button). The app's own copy stays on
    /// the clipboard, with its formatting and full length. False when the clipboard did not change.
    static func copyForUser() async -> Bool {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        await postShortcut(copyKey)
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != before { return true }
        }
        return false
    }

    /// Puts `text` on the pasteboard, sends ⌘V to `pid`, then restores the clipboard. 0.2.1.k.12:
    /// refuses when the clipboard holds a password manager's item, when the app in front is not the
    /// one the text came from, or during secure input; the clipboard is this-Mac-only; it is put back
    /// after 1 s and only if nobody wrote to it meanwhile. False when nothing was pasted.
    static func paste(_ text: String, into pid: pid_t) async -> Bool {
        let pasteboard = NSPasteboard.general
        if SensitiveGuard.isSensitivePasteboard(types: (pasteboard.types ?? []).map(\.rawValue)) { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !IsSecureEventInputEnabled() else { return false }
        let saved = snapshot()
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount
        await waitForModifiersUp()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !IsSecureEventInputEnabled() else {
            if let saved { restore(saved) }
            return false
        }
        await postShortcut(pasteKey)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let saved, pasteboard.changeCount == ours { restore(saved) }
        return true
    }
}

/// Notices a ⌘C typed by the user while Suiyi waits for its own ⌘C to land.
@MainActor
private final class UserCopyWatch {
    private(set) var userPressedCopy = false
    private var monitor: Any?

    init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 8, event.modifierFlags.contains(.command),
                  event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Clipboard.syntheticMarker else { return }
            MainActor.assumeIsolated { self?.userPressedCopy = true }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
