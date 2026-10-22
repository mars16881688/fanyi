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
