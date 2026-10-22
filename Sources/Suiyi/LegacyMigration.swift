import Foundation

/// One-time migration from the pre-rename Fanyi app (bundle id ai.mars.fanyi).
/// Old data is never deleted: settings and the Keychain item are copied, and
/// ~/.fanyi is moved to ~/.suiyi with a symlink left behind so existing
/// references (for example `@~/.fanyi/profile.md`) keep working.
@MainActor
enum LegacyMigration {
    nonisolated static let legacyDomain = "ai.mars.fanyi"
    private static let doneKey = "legacyFanyiMigrated"

    /// Call before AppSettings.registerDefaults(), so "not set" can be told apart from a default.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        migrateDefaults(into: defaults)
        migrateAPIKey()
        migrateDataFolder()
        // 0.2.1.k.01: agent files (~/.claude/CLAUDE.md, ~/.codex/AGENTS.md) are never rewritten
        // automatically; an old Fanyi block is left for the user to remove in Settings.
        defaults.set(true, forKey: doneKey)
    }

    static func migrateDefaults(into defaults: UserDefaults, from domain: String = legacyDomain) {
        guard let old = defaults.persistentDomain(forName: domain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    private static func migrateAPIKey() {
        guard Keychain.apiKey() == nil, let key = Keychain.legacyAPIKey() else { return }
        let status = Keychain.setAPIKey(key)
        if status != errSecSuccess {
            NSLog("Suiyi: copying legacy API key failed: %d", status)
        }
    }

    static func migrateDataFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let fm = FileManager.default
        let old = home.appendingPathComponent(".fanyi", isDirectory: true)
        let new = home.appendingPathComponent(".suiyi", isDirectory: true)
        let oldIsLink = (try? fm.destinationOfSymbolicLink(atPath: old.path)) != nil
        guard !oldIsLink, !fm.fileExists(atPath: new.path) else { return }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        do {
            try fm.moveItem(at: old, to: new)
            try fm.createSymbolicLink(atPath: old.path, withDestinationPath: new.path)
        } catch {
            NSLog("Suiyi: migrating ~/.fanyi failed: %@", error.localizedDescription)
        }
    }
}
