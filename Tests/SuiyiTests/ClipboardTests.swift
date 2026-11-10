import AppKit
import Testing
@testable import Suiyi

/// The ⌘C read path, on a private pasteboard with the app's copy and the user's ⌘C simulated.
@Suite("Clipboard read")
@MainActor
struct ClipboardTests {
    private func pasteboard(holding text: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("suiyi-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard
    }

    @Test("The user's clipboard comes back after Suiyi reads the selection")
    func restoresOriginal() async {
        let pasteboard = pasteboard(holding: "a long article copied earlier")
        defer { pasteboard.releaseGlobally() }
        let text = await Clipboard.copySelection(on: pasteboard, settle: 10_000_000) {
            pasteboard.clearContents()
            pasteboard.setString("selected words", forType: .string)
        }
        #expect(text == "selected words")
        #expect(pasteboard.string(forType: .string) == "a long article copied earlier")
    }

    @Test("A ⌘C the user presses while Suiyi reads is kept, not overwritten by the older clipboard")
    func keepsUsersOwnCopy() async {
        let pasteboard = pasteboard(holding: "a long article copied earlier")
        defer { pasteboard.releaseGlobally() }
        // The user's copy lands 50 ms in; a 1 s settle leaves room for slow CI runners.
        let text = await Clipboard.copySelection(on: pasteboard, settle: 1_000_000_000) {
            pasteboard.clearContents()
            pasteboard.setString("selected words", forType: .string)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                pasteboard.clearContents()
                pasteboard.setString("selected words", forType: .string)
            }
        }
        #expect(text == "selected words")
        #expect(pasteboard.string(forType: .string) == "selected words")
    }

    @Test("Nothing is read or restored when the app does not copy")
    func noCopy() async {
        let pasteboard = pasteboard(holding: "unchanged")
        defer { pasteboard.releaseGlobally() }
        let text = await Clipboard.copySelection(on: pasteboard, settle: 10_000_000) {}
        #expect(text == nil)
        #expect(pasteboard.string(forType: .string) == "unchanged")
    }
}

@Suite("Clipboard restore rule")
struct ClipboardRestoreRuleTests {
    @Test("Restore only when nothing wrote after our copy and the user did not press ⌘C", arguments: [
        (5, 5, false, true),
        (5, 6, false, false),
        (5, 5, true, false),
        (5, 6, true, false),
    ])
    func rule(ours: Int, now: Int, userPressedCopy: Bool, expected: Bool) {
        #expect(Clipboard.shouldRestore(ours: ours, now: now, userPressedCopy: userPressedCopy) == expected)
    }
}
