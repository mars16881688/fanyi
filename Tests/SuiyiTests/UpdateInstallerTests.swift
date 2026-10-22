import Foundation
import Testing
@testable import Suiyi

@Suite("Update feed and installer")
struct UpdateInstallerTests {
    private static let sha = String(repeating: "ab", count: 32)

    @Test("Only release assets of the official site repo are trusted", arguments: [
        ("https://github.com/mars16881688/fanyi-site/releases/download/v0.2.5/Suiyi.zip", true),
        ("http://github.com/mars16881688/fanyi-site/releases/download/v0.2.5/Suiyi.zip", false),
        ("https://github.com/someone/fanyi-site/releases/download/v0.2.5/Suiyi.zip", false),
        ("https://evil.example/mars16881688/fanyi-site/releases/download/v0.2.5/Suiyi.zip", false),
        ("https://github.com/mars16881688/fanyi-site/releases/download/v0.2.5/Suiyi.dmg", false),
        ("https://github.com/mars16881688/fanyi-site/archive/main.zip", false),
    ])
    func trusted(url: String, expected: Bool) throws {
        #expect(UpdateInstaller.isTrustedDownload(try #require(URL(string: url))) == expected)
    }

    @Test("A feed entry is installable only with a trusted asset and a well-formed SHA-256")
    func installable() throws {
        func info(_ download: String?, _ sha256: String?) throws -> ReleaseInfo {
            var json: [String: Any] = ["version": "0.2.5", "url": "https://github.com/mars16881688/fanyi-site/releases/latest"]
            json["download"] = download
            json["sha256"] = sha256
            return try JSONDecoder().decode(ReleaseInfo.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let asset = "https://github.com/mars16881688/fanyi-site/releases/download/v0.2.5/Suiyi.zip"
        #expect(try info(asset, Self.sha).installable?.sha256 == Self.sha)
        #expect(try info(asset, nil).installable == nil)
        #expect(try info(asset, "xyz").installable == nil)
        #expect(try info(nil, Self.sha).installable == nil)
        #expect(try info("https://evil.example/Suiyi.zip", Self.sha).installable == nil)
    }

    @Test("Automatic checks run once a day and only when enabled")
    func autoCheckDue() {
        let now = Date()
        #expect(UpdateChecker.isAutoCheckDue(enabled: true, last: nil, now: now))
        #expect(!UpdateChecker.isAutoCheckDue(enabled: true, last: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateChecker.isAutoCheckDue(enabled: true, last: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(UpdateChecker.isAutoCheckDue(enabled: true, last: now.addingTimeInterval(3600), now: now))
        #expect(!UpdateChecker.isAutoCheckDue(enabled: false, last: nil, now: now))
    }

    @Test("SHA-256 of a file")
    func sha256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("suiyi-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateInstaller.sha256Hex(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Finds Suiyi.app inside the versioned folder of an archive")
    func findsApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("suiyi-find-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Suiyi-0.2.5/Suiyi.app/Contents", isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(UpdateInstaller.findApp(in: root)?.lastPathComponent == "Suiyi.app")
        #expect(UpdateInstaller.findApp(in: fm.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")) == nil)
    }
}

/// End to end with the real, locally signed build: needs build/Suiyi.app and the matching
/// dist/Suiyi-<version>.zip from scripts/package.sh, so it is skipped where those are absent (CI).
@Suite("Update installer end to end")
struct UpdateInstallerEndToEndTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let builtApp = root.appendingPathComponent("build/Suiyi.app")
    private static var version: String? { UpdateInstaller.version(of: builtApp) }
    private static var archive: URL? {
        version.map { root.appendingPathComponent("dist/Suiyi-\($0).zip") }
    }
    private static var available: Bool {
        guard let archive else { return false }
        return FileManager.default.fileExists(atPath: archive.path)
    }

    private func sandbox() throws -> (dir: URL, installed: URL) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("suiyi-e2e-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let installed = dir.appendingPathComponent("Suiyi.app")
        try fm.copyItem(at: Self.builtApp, to: installed)
        return (dir, installed)
    }

    @Test("Installs a genuine release over the installed app", .enabled(if: available))
    func installsGenuine() throws {
        let (dir, installed) = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try #require(Self.archive), version = try #require(Self.version)
        let before = try FileManager.default.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? Int
        try UpdateInstaller.install(archive: archive, expectedSHA256: try UpdateInstaller.sha256Hex(of: archive),
                                    expectedVersion: version, replacing: installed)
        let after = try FileManager.default.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? Int
        #expect(before != after)
        #expect(UpdateInstaller.version(of: installed) == version)
        #expect(UpdateInstaller.isSignedLike(installed, installed: Self.builtApp))
    }

    @Test("Refuses a wrong checksum or version", .enabled(if: available))
    func refusesWrongMetadata() throws {
        let (dir, installed) = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try #require(Self.archive), version = try #require(Self.version)
        #expect(throws: UpdateInstaller.Failure.checksumMismatch) {
            try UpdateInstaller.install(archive: archive, expectedSHA256: String(repeating: "0", count: 64),
                                        expectedVersion: version, replacing: installed)
        }
        #expect(throws: UpdateInstaller.Failure.wrongVersion(version)) {
            try UpdateInstaller.install(archive: archive, expectedSHA256: try UpdateInstaller.sha256Hex(of: archive),
                                        expectedVersion: "9.9.9", replacing: installed)
        }
    }

    @Test("Refuses an app whose signed contents were altered", .enabled(if: available))
    func refusesTampered() throws {
        let fm = FileManager.default
        let (dir, installed) = try sandbox()
        defer { try? fm.removeItem(at: dir) }
        let archive = try #require(Self.archive), version = try #require(Self.version)

        let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
        try UpdateInstaller.unzip(archive, to: unpacked)
        let app = try #require(UpdateInstaller.findApp(in: unpacked))
        let resource = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        let handle = try FileHandle(forWritingTo: resource)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()

        let tampered = dir.appendingPathComponent("tampered.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", app.deletingLastPathComponent().path, tampered.path]
        try zip.run()
        zip.waitUntilExit()

        #expect(throws: UpdateInstaller.Failure.signatureMismatch) {
            try UpdateInstaller.install(archive: tampered, expectedSHA256: try UpdateInstaller.sha256Hex(of: tampered),
                                        expectedVersion: version, replacing: installed)
        }
        #expect(UpdateInstaller.isSignedLike(installed, installed: Self.builtApp))
    }
}
