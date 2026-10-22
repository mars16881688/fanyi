import CryptoKit
import Foundation
import Security

/// Downloads a release, checks it twice and swaps it in place of the running app:
/// 1. the archive's SHA-256 must equal the one published in latest.json;
/// 2. the new app must satisfy the current app's designated requirement, i.e. be
///    signed with the same certificate and carry the same bundle identifier.
/// Settings, the Keychain item and Accessibility permission all survive, because
/// the identity of the app does not change.
enum UpdateInstaller {
    enum Failure: LocalizedError, Equatable {
        case untrustedSource
        case checksumMismatch
        case appNotFound
        case wrongVersion(String)
        case signatureMismatch
        case notWritable(String)
        case unzipFailed

        var errorDescription: String? {
            switch self {
            case .untrustedSource:
                return L("更新地址不是随译的官方发布地址，已停止。", "The download is not from Suiyi's official releases; stopped.",
                         "Suiyi の公式リリース以外からのダウンロードのため中止しました。", "Suiyi 공식 릴리스가 아닌 곳의 다운로드라 중단했습니다.")
            case .checksumMismatch:
                return L("下载的文件校验失败，可能已损坏或被篡改，未安装。", "The download failed its checksum (damaged or altered); nothing was installed.",
                         "ダウンロードしたファイルの検証に失敗しました（破損または改ざんの可能性）。インストールしていません。",
                         "다운로드한 파일 검증에 실패했습니다(손상되었거나 변조됨). 설치하지 않았습니다.")
            case .appNotFound:
                return L("安装包里没有找到 Suiyi.app。", "Suiyi.app was not found in the download.",
                         "ダウンロードに Suiyi.app が見つかりません。", "다운로드에서 Suiyi.app을 찾지 못했습니다.")
            case .wrongVersion(let version):
                return L("安装包版本（\(version)）与预期不符，未安装。", "The download has an unexpected version (\(version)); nothing was installed.",
                         "ダウンロードのバージョン（\(version)）が想定と異なるため、インストールしていません。",
                         "다운로드 버전(\(version))이 예상과 달라 설치하지 않았습니다.")
            case .signatureMismatch:
                return L("新版本的签名与当前版本不一致，未安装。", "The new version is not signed like this one; nothing was installed.",
                         "新しいバージョンの署名が現在のものと一致しないため、インストールしていません。",
                         "새 버전의 서명이 현재 버전과 일치하지 않아 설치하지 않았습니다.")
            case .notWritable(let path):
                return L("没有权限替换 \(path)，请手动下载安装。", "No permission to replace \(path); please download and install it manually.",
                         "\(path) を置き換える権限がありません。手動でダウンロードしてインストールしてください。",
                         "\(path)을(를) 바꿀 권한이 없습니다. 직접 다운로드해 설치하세요.")
            case .unzipFailed:
                return L("安装包解压失败。", "Couldn't unpack the download.", "ダウンロードを展開できませんでした。", "다운로드 압축을 풀지 못했습니다.")
            }
        }
    }

    /// Only the release assets of the official site repository are accepted.
    static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/mars16881688/fanyi-site/releases/download/")
            && url.pathExtension == "zip"
    }

    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The first Suiyi.app inside an unpacked archive (it sits in a versioned folder).
    static func findApp(in folder: URL) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == "Suiyi.app" { return url }
        return nil
    }

    static func version(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// True when `candidate` is validly signed and meets `installed`'s designated requirement.
    static func isSignedLike(_ candidate: URL, installed: URL) -> Bool {
        var installedCode: SecStaticCode?
        var requirement: SecRequirement?
        var candidateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode) == errSecSuccess, let installedCode,
              SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess, let candidateCode
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess
    }

    static func unzip(_ archive: URL, to folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.unzipFailed }
    }

    /// Verifies a downloaded archive and replaces `installed` with the app inside it.
    static func install(archive: URL, expectedSHA256: String, expectedVersion: String, replacing installed: URL) throws {
        guard try sha256Hex(of: archive) == expectedSHA256.lowercased() else { throw Failure.checksumMismatch }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("suiyi-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try unzip(archive, to: work)

        guard let app = findApp(in: work) else { throw Failure.appNotFound }
        let found = version(of: app) ?? "?"
        guard found == expectedVersion else { throw Failure.wrongVersion(found) }
        guard isSignedLike(app, installed: installed) else { throw Failure.signatureMismatch }

        let parent = installed.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw Failure.notWritable(parent.path) }
        // Stage next to the target so the final swap stays on one volume and is atomic.
        let staged = parent.appendingPathComponent(".Suiyi-update-\(UUID().uuidString).app")
        try fm.moveItem(at: app, to: staged)
        do {
            _ = try fm.replaceItemAt(installed, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// Downloads `url` and installs it over the running app.
    static func downloadAndInstall(from url: URL, expectedSHA256: String, expectedVersion: String) async throws {
        guard isTrustedDownload(url) else { throw Failure.untrustedSource }
        let (temp, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try install(archive: temp, expectedSHA256: expectedSHA256, expectedVersion: expectedVersion,
                    replacing: Bundle.main.bundleURL)
    }

    /// Opens the freshly installed app once this process has quit.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "relaunch", path]
        try? process.run()
    }
}
