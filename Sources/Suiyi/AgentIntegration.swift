import Foundation

enum AgentIntegration {
    static let begin = "<!-- suiyi:begin (由随译自动添加，可在随译设置里移除) -->"
    static let end = "<!-- suiyi:end -->"
    // Blocks written before the rename to 随译; still recognised so they can be replaced or removed.
    static let legacyBegin = "<!-- fanyi:begin (由 Fanyi 自动添加，可在 Fanyi 设置里移除) -->"
    static let legacyEnd = "<!-- fanyi:end -->"
    // Resolve relative CODEX_HOME against the user's home, never the process cwd.
    private static var codexHome: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmed ?? ""
        guard !configured.isEmpty else { return home.appendingPathComponent(".codex", isDirectory: true) }
        let candidate: URL
        if configured == "~" {
            candidate = home
        } else if configured.hasPrefix("~/") {
            candidate = home.appendingPathComponent(String(configured.dropFirst(2)), isDirectory: true)
        } else if configured.hasPrefix("/") {
            candidate = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            candidate = home.appendingPathComponent(configured, isDirectory: true)
        }
        return candidate
    }

    // Reject symlink escapes, another user's home, and any checkout (including worktrees).
    static func validateUserFile(_ url: URL) throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(home.path + "/") else {
            throw NSError(domain: "Suiyi.AgentIntegration", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("接入文件必须位于当前用户的主目录内。请检查 CODEX_HOME 和符号链接。", "The file must be inside your home folder. Check CODEX_HOME and symlinks.", "ファイルはホームフォルダ内にある必要があります。CODEX_HOME とシンボリックリンクを確認してください。", "파일은 홈 폴더 안에 있어야 합니다. CODEX_HOME과 심볼릭 링크를 확인하세요.")])
        }
        var directory = resolved.deletingLastPathComponent()
        while directory.path != "/" {
            if fm.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                throw NSError(domain: "Suiyi.AgentIntegration", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: L("接入文件不能位于 Git 仓库内。请使用个人配置目录。", "The file must not be inside a Git repository. Use your personal config folder.", "ファイルは Git リポジトリ内に置けません。個人の設定フォルダを使ってください。", "파일은 Git 저장소 안에 둘 수 없습니다. 개인 설정 폴더를 사용하세요.")])
            }
            directory.deleteLastPathComponent()
        }
    }

    static var files: [(name: String, url: URL, content: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ("Codex", codexHome.appendingPathComponent("AGENTS.md"),
             "## 我的个人风格（来自随译）\n\nWhen writing English or Chinese text on my behalf (messages, emails, PR descriptions, docs), first read `~/.suiyi/profile.md` if it exists and match my tone, length and wording habits described there. Do not quote it verbatim."),
            ("Claude Code", home.appendingPathComponent(".claude/CLAUDE.md"),
             "## 我的个人风格（来自随译）\n\n请参考以下随译用户画像，在代我写作时匹配我的个人风格。\n\n@~/.suiyi/profile.md")
        ]
    }

    private static func range(in text: String) -> Range<String.Index>? {
        range(in: text, begin: begin, end: end) ?? range(in: text, begin: legacyBegin, end: legacyEnd)
    }

    private static func range(in text: String, begin: String, end: String) -> Range<String.Index>? {
        guard let start = text.range(of: begin),
              let finish = text.range(of: end, range: start.upperBound..<text.endIndex) else { return nil }
        return start.lowerBound..<finish.upperBound
    }

    static func strippingBlock(_ text: String) -> String {
        var result = text
        while let range = range(in: result) { result.removeSubrange(range) }
        return result
    }

    static func status() -> [Bool] {
        files.map { file in
            guard (try? validateUserFile(file.url)) != nil,
                  let text = try? String(contentsOf: file.url, encoding: .utf8) else { return false }
            return range(in: text) != nil
        }
    }

    static func install() throws {
        for file in files { try validateUserFile(file.url) }
        for file in files {
            let fm = FileManager.default
            try fm.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let old = fm.fileExists(atPath: file.url.path) ? try String(contentsOf: file.url, encoding: .utf8) : ""
            let block = begin + "\n" + file.content + "\n" + end
            var updated = old
            if let range = range(in: old) { updated.replaceSubrange(range, with: block) }
            else { updated += (old.isEmpty ? "" : "\n\n") + block }
            if updated != old { try LocalFile.write(updated, to: file.url) }
        }
    }

    /// Rewrites pre-rename Fanyi blocks in place. Files without one are left untouched.
    static func migrateLegacyBlocks() throws {
        for file in files {
            guard FileManager.default.fileExists(atPath: file.url.path) else { continue }
            try validateUserFile(file.url)
            let old = try String(contentsOf: file.url, encoding: .utf8)
            guard let legacy = range(in: old, begin: legacyBegin, end: legacyEnd) else { continue }
            var updated = old
            updated.replaceSubrange(legacy, with: begin + "\n" + file.content + "\n" + end)
            try LocalFile.write(updated, to: file.url)
        }
    }

    static func remove() throws {
        for file in files { try validateUserFile(file.url) }
        for file in files {
            guard FileManager.default.fileExists(atPath: file.url.path) else { continue }
            let old = try String(contentsOf: file.url, encoding: .utf8)
            var updated = old
            while let block = range(in: updated) {
                var start = block.lowerBound
                // Appended blocks own exactly the two preceding LF characters.
                if block.upperBound == updated.endIndex, updated[..<start].hasSuffix("\n\n") {
                    start = updated.index(start, offsetBy: -2)
                }
                updated.removeSubrange(start..<block.upperBound)
            }
            if updated != old { try LocalFile.write(updated, to: file.url) }
        }
    }
}
