import AppKit
import Foundation
import Testing
@testable import Suiyi

@Suite("LegacyMigration")
@MainActor
struct LegacyMigrationTests {
    private let fm = FileManager.default

    private func makeHome() throws -> URL {
        let home = fm.temporaryDirectory.appendingPathComponent("suiyi-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test("Moves ~/.fanyi to ~/.suiyi and leaves a symlink")
    func movesFolder() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let old = home.appendingPathComponent(".fanyi"), new = home.appendingPathComponent(".suiyi")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try "p".write(to: old.appendingPathComponent("profile.md"), atomically: true, encoding: .utf8)

        LegacyMigration.migrateDataFolder(home: home)

        #expect(fm.fileExists(atPath: new.appendingPathComponent("profile.md").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: old.path) == new.path)
        #expect(try String(contentsOf: old.appendingPathComponent("profile.md"), encoding: .utf8) == "p")

        LegacyMigration.migrateDataFolder(home: home)   // idempotent
        #expect(fm.fileExists(atPath: new.appendingPathComponent("profile.md").path))
    }

    @Test("Leaves both folders alone when ~/.suiyi already exists")
    func keepsExisting() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home.appendingPathComponent(".fanyi"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".suiyi"), withIntermediateDirectories: true)
        LegacyMigration.migrateDataFolder(home: home)
        #expect((try? fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".fanyi").path)) == nil)
    }

    @Test("Does nothing without an old folder")
    func noOldFolder() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        LegacyMigration.migrateDataFolder(home: home)
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".suiyi").path))
    }

    @Test("Copies old settings without overwriting new ones")
    func copiesDefaults() throws {
        let source = "ai.mars.suiyi-tests-src-\(UUID().uuidString)"
        let target = "ai.mars.suiyi-tests-dst-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: target))
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: target)
        }
        defaults.setPersistentDomain(["model": "kept"], forName: target)
        defaults.setPersistentDomain(["model": "old", "historyEnabled": true], forName: source)

        LegacyMigration.migrateDefaults(into: defaults, from: source)

        #expect(defaults.bool(forKey: "historyEnabled"))
        #expect(defaults.string(forKey: "model") == "kept")
    }
}

@Suite("GlassButton")
@MainActor
struct GlassButtonTests {
    @Test("Icon-only buttons are square")
    func iconOnly() {
        let button = GlassButton(title: "", symbol: "xmark", style: .plain, size: .small, target: nil, action: nil)
        #expect(button.intrinsicContentSize == NSSize(width: 24, height: 24))
        #expect(button.cell is GlassButtonCell)
        #expect(!button.allowsVibrancy)
        #expect(button.acceptsFirstMouse(for: nil))
    }

    @Test("Width follows the title, height follows the size")
    func sizing() {
        let short = GlassButton(title: "复制", symbol: "doc.on.doc", target: nil, action: nil)
        let long = GlassButton(title: "复制译文到剪贴板", symbol: "doc.on.doc", target: nil, action: nil)
        #expect(short.intrinsicContentSize.height == 30)
        #expect(long.intrinsicContentSize.width > short.intrinsicContentSize.width)
        let before = short.intrinsicContentSize.width
        short.title = "已复制一段很长的文字"
        #expect(short.intrinsicContentSize.width > before)
    }

    @Test("Draws without crashing in both appearances")
    func draws() {
        let button = GlassButton(title: "翻译", symbol: "character.book.closed", target: nil, action: nil)
        button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: name)
            let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)
            #expect(rep != nil)
            if let rep { button.cacheDisplay(in: button.bounds, to: rep) }
        }
    }
}

@Suite("App icon assets")
struct AppIconTests {
    private static let iconset = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/AppIcon.iconset")

    @Test("Every size is present and rendered at its native pixel size", arguments: [16, 32, 128, 256, 512])
    func sizes(base: Int) throws {
        for (suffix, pixels) in [("", base), ("@2x", base * 2)] {
            let url = Self.iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
            let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)), "\(url.lastPathComponent)")
            #expect(rep.pixelsWide == pixels && rep.pixelsHigh == pixels)
            #expect(rep.hasAlpha)
        }
    }
}

@Suite("Button secondary click")
@MainActor
struct SecondaryClickTests {
    final class Counter: NSObject {
        var primary = 0
        @objc func clicked(_ sender: Any?) { primary += 1 }
    }

    private func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test("Right-click and Control-click copy (0.2.1.k.06) without triggering the primary action")
    func secondaryClick() {
        let counter = Counter()
        let button = GlassButton(title: "", symbol: "character.bubble", style: .plain,
                                 target: counter, action: #selector(Counter.clicked(_:)))
        var copies = 0
        button.onSecondaryClick = { copies += 1 }
        button.rightMouseDown(with: event(.rightMouseDown))
        button.mouseDown(with: event(.leftMouseDown, .control))
        #expect(copies == 2)
        #expect(counter.primary == 0)
    }
}

@Suite("Try Omarchy exclusion")
struct TryOmarchyExclusionTests {
    @Test("Excluded by default; added once to a saved list, keeping what is there")
    func excludedList() {
        let id = AppSettings.tryOmarchyBundleID
        #expect(AppSettings.parseExcluded(AppSettings.defaultExcluded).contains(id))
        #expect(AppSettings.adding(id, toExcluded: "com.a.one") == "com.a.one,dev.tryomarchy.native")
        #expect(AppSettings.adding(id, toExcluded: " com.a.one，com.b.two\n") == "com.a.one，com.b.two,dev.tryomarchy.native")
        #expect(AppSettings.adding(id, toExcluded: "  ") == "dev.tryomarchy.native")
        #expect(AppSettings.adding(id, toExcluded: "com.a.one, DEV.TryOmarchy.native") == "com.a.one, DEV.TryOmarchy.native")
    }

    @Test("The menu toggle takes an app off the list without touching the others")
    func removing() {
        #expect(AppSettings.removing("dev.tryomarchy.native", fromExcluded: "com.a.one， DEV.tryomarchy.native\ncom.b.two") == "com.a.one,com.b.two")
        #expect(AppSettings.removing("dev.tryomarchy.native", fromExcluded: "com.a.one") == "com.a.one")
        #expect(AppSettings.removing("dev.tryomarchy.native", fromExcluded: "dev.tryomarchy.native").isEmpty)
    }

    @Test("Synthetic ⌘C presses and releases ⌘ around the key")
    @MainActor
    func shortcutSequence() {
        let steps = Clipboard.shortcutSequence(8).map { "\($0.key) \($0.down ? "down" : "up") \($0.flags.contains(.maskCommand) ? "⌘" : "-")" }
        #expect(steps == ["55 down ⌘", "8 down ⌘", "8 up ⌘", "55 up -"])
        #expect(Clipboard.shortcutSequence(8).last?.flags.isEmpty == true)
    }
}

@Suite("Read on click")
struct ReadOnClickTests {
    private func window(_ number: CGWindowID, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 800, _ h: CGFloat = 600) -> WindowProbe.Snapshot {
        WindowProbe.Snapshot(number: number, bounds: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test("A moved or resized window is not a text selection")
    func windowMoved() {
        #expect(WindowProbe.moved(window(7, 100, 100), window(7, 140, 120)))
        #expect(WindowProbe.moved(window(7, 100, 100), window(7, 100, 100, 900, 600)))
        #expect(!WindowProbe.moved(window(7, 100, 100), window(7, 100, 100)))
        #expect(!WindowProbe.moved(window(7, 100, 100), window(7, 100.3, 100)))
        #expect(!WindowProbe.moved(window(7, 100, 100), window(8, 300, 300)))
        #expect(!WindowProbe.moved(nil, window(7, 100, 100)))
        #expect(!WindowProbe.moved(window(7, 100, 100), nil))
    }

    @Test("Scroll bars, sliders and dividers are not text")
    @MainActor
    func nonTextRoles() {
        for role in ["AXScrollBar", "AXValueIndicator", "AXSlider", "AXSplitter"] {
            #expect(SelectionReader.nonTextRoles.contains(role))
        }
        for role in ["AXStaticText", "AXTextArea", "AXGroup", "AXWebArea", "AXUnknown"] {
            #expect(!SelectionReader.nonTextRoles.contains(role))
        }
    }
}
