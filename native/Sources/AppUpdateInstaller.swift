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
    // Both entry points run under the same lock so pruning cannot interrupt a rollback.
    static let helperScript = #"""
#!/bin/sh
set -eu
prune_backups() {
  directory="$1"
  pinned="${2:-}"
  keep="$pinned"
  retention_seconds=259200
  cutoff=$(( $(/bin/date +%s) - retention_seconds ))
  newest="$cutoff"
  set --
  for candidate in "$directory"/.CodexUsageBar-backup-????????-????-????-????-????????????.app; do
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null) || continue
    [ "$identifier" = com.guoyuming.UsageBar ] || continue
    modified=$(/usr/bin/stat -f %m "$candidate") || return 1
    set -- "$@" "$candidate"
    if [ -z "$pinned" ] && [ "$modified" -gt "$newest" ]; then
      keep="$candidate"
      newest="$modified"
    fi
  done
  failed=0
  for candidate do
    [ "$candidate" = "$keep" ] || /bin/rm -rf "$candidate" || failed=1
  done
  [ "$failed" -eq 0 ] || return 1
  if [ -n "$keep" ]; then
    modified=$(/usr/bin/stat -f %m "$keep") || return 1
    printf '%s\n' "$((modified + retention_seconds))"
  fi
}
if [ "$1" = --prune-backups ]; then
  prune_backups "$2"
  exit
fi
old_pid="$1"
target="$2"
staged="$3"
backup="$4"
log="$5"
result="$6"
original_inode="$7"
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
if [ "$(/usr/bin/stat -f %i "$target")" != "$original_inode" ]; then
  rm -rf "$staged"
  fail '应用已被替换，本次更新已取消。'
fi
if ! /usr/bin/codesign --verify --deep --strict "$staged"; then
  rm -rf "$staged"
  fail '安装文件签名验证失败，原版本保留。'
fi
if ! mv "$target" "$backup"; then
  rm -rf "$staged"
  fail '无法替换应用，原版本保留，请检查安装目录权限。'
fi
if ! /usr/bin/touch "$backup" || ! mv "$staged" "$target"; then
  if mv "$backup" "$target"; then rm -rf "$staged"; fi
  /usr/bin/open "$target" || true
  fail '安装失败，已尝试恢复旧版本。'
fi
if ! /usr/bin/open "$target"; then
  if mv "$target" "$staged" && mv "$backup" "$target"; then rm -rf "$staged"; fi
  printf '%s\n' '重启失败，已尝试恢复旧版本。' > "$result"
  /usr/bin/open "$target" || true
  exit 1
fi
if prune_backups "${target%/*}" "$backup" >/dev/null; then
  printf '%s\n' '更新已安装，上一版本备份保留 3 天。' > "$result"
else
  printf '%s\n' '更新已安装，部分旧备份暂未清理。' > "$result"
fi
"""#
    private static func lockedShellArguments(in directory: URL) -> [String] {
        ["-k", directory.appendingPathComponent(".CodexUsageBar-update.lock").path, "/bin/sh"]
    }
    static func pruneBackups(for target: URL) throws -> Date? {
        let directory = target.deletingLastPathComponent()
        guard !target.lastPathComponent.hasPrefix(".CodexUsageBar-backup-"),
              Bundle(url: target)?.bundleIdentifier == bundleID,
              FileManager.default.isWritableFile(atPath: directory.path) else { return nil }
        let output = try run("/usr/bin/lockf", lockedShellArguments(in: directory) +
            ["-c", helperScript, "CodexUsageBar", "--prune-backups", directory.path])
        return TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)).map(Date.init(timeIntervalSince1970:))
    }
    static func prepareInstall(app: URL, target: URL, workDirectory: URL, pid: Int32) throws -> Process {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        guard target.pathExtension == "app", fm.isWritableFile(atPath: directory.path),
              Bundle(url: target)?.bundleIdentifier == bundleID,
              let inode = try fm.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber else {
            throw UpdateFailure.invalid("应用目录不可写，请将应用移至可写的固定目录后重试。")
        }
        let token = UUID().uuidString
        let staged = directory.appendingPathComponent(".CodexUsageBar-update-" + token + ".app")
        let backup = directory.appendingPathComponent(".CodexUsageBar-backup-" + token + ".app")
        let helper = workDirectory.appendingPathComponent("install.sh")
        try helperScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexUsageBar/updates")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        do { try run("/usr/bin/ditto", [app.path, staged.path]) }
        catch { try? fm.removeItem(at: staged); throw error }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = lockedShellArguments(in: directory) +
            [helper.path, String(pid), target.path, staged.path, backup.path, support.appendingPathComponent("install.log").path, support.appendingPathComponent("result.txt").path, inode.stringValue]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        return process
    }
}
