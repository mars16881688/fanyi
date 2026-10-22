import Foundation

struct HistoryEntry: Codable, Sendable {
    var timestamp = ISO8601DateFormatter().string(from: Date())
    let mode: String
    let appBundleID: String?
    let appName: String?
    let original: String
    var translation: String? = nil
    var replyZH: String? = nil
    var replyEN: String? = nil

    enum CodingKeys: String, CodingKey {
        case timestamp, mode, original, translation
        case appBundleID = "app_bundle_id", appName = "app_name"
        case replyZH = "reply_zh", replyEN = "reply_en"
    }
}

/// All file operations share this queue, including reads and truncation.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()
    let folderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".suiyi", isDirectory: true)
    var fileURL: URL { folderURL.appendingPathComponent("history.jsonl") }
    private let queue = DispatchQueue(label: "ai.mars.suiyi.history")

    func ensureFolder() throws {
        try queue.sync { try prepareFolder() }
    }

    private func prepareFolder() throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folderURL.path)
    }

    @discardableResult
    func append(_ entry: HistoryEntry) throws -> Bool {
        try queue.sync {
            guard AppSettings.historyEnabled, !AppSettings.isExcluded(bundleID: entry.appBundleID) else { return false }
            try prepareFolder()
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                                      attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(entry)
            data.append(0x0A)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        }
    }

    /// Scan backwards in chunks; do not load an unbounded log into memory.
    func recentEntries(limit: Int) -> [HistoryEntry] {
        queue.sync { readTail(limit: max(0, limit)) }
    }

    private func readTail(limit: Int) -> [HistoryEntry] {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        do {
            var offset = try handle.seekToEnd()
            var pending = Data()
            var entries: [HistoryEntry] = []
            let decoder = JSONDecoder()
            while offset > 0 && entries.count < limit {
                let size = min(offset, 64 * 1024)
                offset -= size
                try handle.seek(toOffset: offset)
                let chunk = try handle.read(upToCount: Int(size)) ?? Data()
                pending.insert(contentsOf: chunk, at: 0)
                var lines = pending.split(separator: 0x0A, omittingEmptySubsequences: false)
                pending = Data(lines.removeFirst())
                for line in lines.reversed() where !line.isEmpty {
                    if let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)) {
                        entries.append(entry)
                        if entries.count == limit { break }
                    }
                }
            }
            if offset == 0, entries.count < limit,
               let entry = try? decoder.decode(HistoryEntry.self, from: pending) { entries.append(entry) }
            return entries
        } catch { return [] }
    }

    var count: Int {
        queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return 0 }
            defer { try? handle.close() }
            var pending = Data()
            var total = 0
            let decoder = JSONDecoder()
            do {
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        if (try? decoder.decode(HistoryEntry.self, from: Data(pending[..<newline]))) != nil { total += 1 }
                        pending.removeSubrange(...newline)
                    }
                }
                if (try? decoder.decode(HistoryEntry.self, from: pending)) != nil { total += 1 }
            } catch { return total }
            return total
        }
    }

    func clear() throws {
        try queue.sync {
            try prepareFolder()
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                                      attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            UserDefaults.standard.set(0, forKey: "profileEntriesSinceUpdate")
        }
    }
}

/// Same-directory rename gives atomic replacement and preserves permissions.
enum LocalFile {
    static func write(_ text: String, to url: URL, permissions: Int = 0o600, preservePermissions: Bool = true) throws {
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let existingMode = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        let mode = preservePermissions ? (existingMode ?? permissions) : permissions
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".suiyi-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: url)
        }
    }
}
