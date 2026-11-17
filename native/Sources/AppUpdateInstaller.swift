import Foundation
import CryptoKit

struct AppReleaseAsset: Decodable, Sendable {
    let name: String
    let browser_download_url: URL
    let size: Int
    var digest: String? = nil
}

enum UpdateFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

enum AppUpdateInstaller {
    static let bundleID = "com.guoyuming.UsageBar"
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static func archive(for release: AppRelease, architecture: String = architecture) -> AppReleaseAsset? {
        guard AppRelease.version(release.tag_name) != nil else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        for arch in [architecture, "universal"] {
            let name = "CodexUsageBar-\(version)-mac-\(arch).zip"
            if let asset = release.assets?.first(where: { $0.name == name && validAsset($0, tag: release.tag_name) }) { return asset }
        }
        return nil
    }
    static func validAsset(_ asset: AppReleaseAsset, tag: String) -> Bool {
        let url = asset.browser_download_url
        return asset.size > 0 && asset.size <= 150_000_000 && !asset.name.contains("/")
            && url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && url.path == "/1078302479/codex-usage-bar/releases/download/\(tag)/\(asset.name)"
    }
    static func checksum(_ text: String, filename: String) throws -> String {
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*")) == filename else { return nil }
            return String(fields[0]).lowercased()
        }
        guard matches.count == 1, let value = matches.first, value.count == 64,
              value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw UpdateFailure.invalid("校验文件缺失或格式不正确，已停止更新。") }
        return value
    }
    static func verify(_ file: URL, expected: String) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateFailure.invalid("安装包 SHA-256 校验失败，已停止更新。") }
    }
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure.invalid("无法验证或解压安装包，原版本未改动。") }
        return String(decoding: output, as: UTF8.self)
    }
    static func validateArchivePaths(_ listing: String) throws {
        let paths = listing.split(whereSeparator: \.isNewline)
        guard !paths.isEmpty, paths.count < 50_000 else { throw UpdateFailure.invalid("安装包目录无效。") }
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), !path.contains("\\"),
                  path.hasPrefix("CodexUsageBar.app/") || path.hasPrefix("__MACOSX/") else { throw UpdateFailure.invalid("安装包含有不安全路径。") }
        }
    }
    static func validateArchiveAttributes(_ listing: String) throws {
        var count = 0
        var total: Int64 = 0
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            // unzip -Z -l entries start with ten Unix mode characters.
            guard let mode = fields.first, mode.count == 10 else { continue }
            guard let kind = mode.first, kind == "-" || kind == "d",
                  fields.count >= 10, let size = Int64(fields[3]), size >= 0, size <= 250_000_000 else {
                throw UpdateFailure.invalid("安装包含有链接、特殊文件或无效大小。")
            }
            count += 1; total += size
            guard count <= 10_000, total <= 500_000_000 else { throw UpdateFailure.invalid("安装包解压大小超出限制。") }
        }
        guard count > 0 else { throw UpdateFailure.invalid("安装包文件清单无效。") }
    }
    static func unpackAndValidate(archive: URL, directory: URL, version: String) throws -> URL {
        let listing = try run("/usr/bin/unzip", ["-Z", "-1", archive.path])
        try validateArchivePaths(listing)
        let attributes = try run("/usr/bin/unzip", ["-Z", "-l", archive.path])
        try validateArchiveAttributes(attributes)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        let app = directory.appendingPathComponent("CodexUsageBar.app")
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID,
              let found = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              AppRelease.version(found) == AppRelease.version(version), let executable = bundle.executableURL else {
            throw UpdateFailure.invalid("应用身份或版本不匹配，已停止更新。")
        }
        for name in ["AppIcon.icns", "LICENSE", "NOTICE"] {
            let resource = app.appendingPathComponent("Contents/Resources/" + name)
            guard (try resource.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0 else {
                throw UpdateFailure.invalid("更新应用缺少必要资源。")
            }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/bin/lipo", ["-verify_arch", architecture, executable.path])
        return app
    }
    // Arguments, rather than interpolated shell strings, preserve spaces and metacharacters.
    static let helperScript = #"""
#!/bin/sh
set -eu
old_pid="$1"
target="$2"
staged="$3"
backup="$4"
log="$5"
result="$6"
exec >>"$log" 2>&1
fail() { printf '%s\n' "$1" > "$result"; exit 1; }
count=0
while kill -0 "$old_pid" 2>/dev/null; do
  count=$((count + 1))
  if [ "$count" -gt 150 ]; then
    rm -rf "$staged"
    fail '客户端未能退出，更新已取消，原版本保留。'
  fi
  sleep 0.2
done
/usr/bin/codesign --verify --deep --strict "$staged" || fail '安装文件签名验证失败，原版本保留。'
if ! mv "$target" "$backup"; then fail '无法替换应用，原版本保留，请检查安装目录权限。'; fi
if ! mv "$staged" "$target"; then
  mv "$backup" "$target" || true
  /usr/bin/open "$target" || true
  fail '安装失败，已尝试恢复旧版本。'
fi
if ! /usr/bin/open "$target"; then
  mv "$target" "$staged" || true
  mv "$backup" "$target" || true
  printf '%s\n' '重启失败，已尝试恢复旧版本。' > "$result"
  /usr/bin/open "$target" || true
  exit 1
fi
printf '%s\n' '更新已安装，旧版本备份已保留。' > "$result"
"""#
    static func prepareInstall(app: URL, target: URL, workDirectory: URL, pid: Int32) throws -> Process {
        let fm = FileManager.default
        guard target.pathExtension == "app", fm.isWritableFile(atPath: target.deletingLastPathComponent().path),
              Bundle(url: target)?.bundleIdentifier == bundleID else { throw UpdateFailure.invalid("应用目录不可写，请将应用移至可写的固定目录后重试。") }
        let token = UUID().uuidString
        let staged = target.deletingLastPathComponent().appendingPathComponent(".CodexUsageBar-update-" + token + ".app")
        let backup = target.deletingLastPathComponent().appendingPathComponent(".CodexUsageBar-backup-" + token + ".app")
        do { try run("/usr/bin/ditto", [app.path, staged.path]) }
        catch { try? fm.removeItem(at: staged); throw error }
        let helper = workDirectory.appendingPathComponent("install.sh")
        try helperScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexUsageBar/updates")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, String(pid), target.path, staged.path, backup.path, support.appendingPathComponent("install.log").path, support.appendingPathComponent("result.txt").path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        return process
    }
}
