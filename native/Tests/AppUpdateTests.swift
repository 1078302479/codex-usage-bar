import Foundation
@main struct AppUpdateTests {
 @MainActor static func main() throws {
  precondition(AppRelease.newer("v0.1.10", than: "0.1.9"))
  precondition(!AppRelease.newer("v0.1.6", than: "0.1.6"))
  precondition(!AppRelease.newer("v0.1.5", than: "0.1.6"))
  precondition(!AppRelease.newer("0.1.6.0", than: "0.1.6"))
  precondition(!AppRelease.newer("v0.2.0-beta", than: "0.1.6"))
  precondition(AppRelease.version("0..2") == nil)
  for bad in ["http://github.com/1078302479/codex-usage-bar/releases/tag/v1", "https://evil.com/1078302479/codex-usage-bar/releases/tag/v1", "https://github.com/other/repo/releases/tag/v1"] {
   precondition(AppRelease(tag_name: "v1.0.0", html_url: URL(string: bad)!, draft: false, prerelease: false).safeURL == nil)
  }
  let url = URL(string: "https://github.com/1078302479/codex-usage-bar/releases/tag/v1.0.0")!
  precondition(AppRelease(tag_name: "v1.0.0", html_url: url, draft: false, prerelease: false).safeURL == url)
  precondition(AppRelease(tag_name: "v1.0.0", html_url: url, draft: false, prerelease: true).safeURL == url)
  try updatePipelineChecks()
  try installerRollbackChecks()
  print("PASS: version selection, release channels, assets, checksums, archive paths, install and rollback")
 }
 @MainActor static func updatePipelineChecks() throws {
  let base = "https://github.com/1078302479/codex-usage-bar/releases/"
  let stable = AppRelease(tag_name: "v0.1.8", html_url: URL(string: base + "tag/v0.1.8")!, draft: false, prerelease: false)
  var preview = AppRelease(tag_name: "v0.1.9", html_url: URL(string: base + "tag/v0.1.9")!, draft: false, prerelease: true)
  let windows = AppRelease(tag_name: "windows-v9.0.0", html_url: URL(string: base + "tag/windows-v9.0.0")!, draft: false, prerelease: true)
  precondition(AppUpdateController.select([windows, preview, stable], current: "0.1.7", includePrereleases: false)?.tag_name == stable.tag_name)
  precondition(AppUpdateController.select([stable, windows, preview], current: "0.1.7", includePrereleases: true)?.tag_name == preview.tag_name)
  let name = "CodexUsageBar-0.1.9-mac-arm64.zip"
  let asset = AppReleaseAsset(name: name, browser_download_url: URL(string: base + "download/v0.1.9/" + name)!, size: 10)
  preview.assets = [asset]
  precondition(AppUpdateInstaller.archive(for: preview, architecture: "arm64")?.name == name)
  precondition(AppUpdateInstaller.archive(for: preview, architecture: "x86_64") == nil)
  precondition(!AppUpdateInstaller.validAsset(asset, tag: "v0.1.8"))
  let bad = AppReleaseAsset(name: name, browser_download_url: URL(string: "https://evil.example/" + name)!, size: 10)
  precondition(!AppUpdateInstaller.validAsset(bad, tag: "v0.1.9"))
  let digest = String(repeating: "a", count: 64)
  let parsed = try AppUpdateInstaller.checksum(digest + "  " + name + "\n", filename: name)
  precondition(parsed == digest)
  for text in ["bad  " + name, digest + " other.zip", digest + "  " + name + "\n" + digest + "  " + name] {
   do { _ = try AppUpdateInstaller.checksum(text, filename: name); fatalError("Invalid checksum accepted") } catch {}
  }
  for path in ["/tmp/escape", "CodexUsageBar.app/../escape", "other.app/Contents/MacOS/test"] {
   do { try AppUpdateInstaller.validateArchivePaths(path); fatalError("Unsafe archive path accepted") } catch {}
  }
  try AppUpdateInstaller.validateArchivePaths("CodexUsageBar.app/Contents/MacOS/CodexUsageBar\n__MACOSX/CodexUsageBar.app/._Contents")
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("abc".utf8).write(to: file)
  try AppUpdateInstaller.verify(file, expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  do { try AppUpdateInstaller.verify(file, expected: digest); fatalError("Corrupt archive accepted") } catch {}
  let suite = "update-test-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(true, forKey: "updates.accepts-prereleases.v1")
  let controller = AppUpdateController(version: "0.1.7", defaults: defaults)
  precondition(controller.acceptsPrereleases)
  controller.stop()
 }
 static func installerRollbackChecks() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("Update tests ' $ space-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  for launchSuccess in [true, false] {
   let folder = root.appendingPathComponent(launchSuccess ? "success" : "rollback")
   let target = folder.appendingPathComponent("CodexUsageBar.app"), staged = folder.appendingPathComponent("new.app"), backup = folder.appendingPathComponent("old.app")
   for dir in [target, staged] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
   try Data("old".utf8).write(to: target.appendingPathComponent("version"))
   try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
   let script = folder.appendingPathComponent("install.sh")
   let source = AppUpdateInstaller.helperScript.replacingOccurrences(of: "/usr/bin/open", with: launchSuccess ? "/usr/bin/true" : "/usr/bin/false")
   try source.write(to: script, atomically: true, encoding: .utf8)
   let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
   process.arguments = [script.path, "99999999", target.path, staged.path, backup.path, folder.appendingPathComponent("log").path, folder.appendingPathComponent("result").path]
   try process.run(); process.waitUntilExit()
   precondition(process.terminationStatus == (launchSuccess ? 0 : 1))
   let data = try Data(contentsOf: target.appendingPathComponent("version"))
   precondition(data == Data((launchSuccess ? "new" : "old").utf8))
   if launchSuccess {
    let old = try Data(contentsOf: backup.appendingPathComponent("version"))
    precondition(old == Data("old".utf8))
   }
  }
 }

}
