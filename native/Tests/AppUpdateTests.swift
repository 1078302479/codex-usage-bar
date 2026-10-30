import Foundation
@main struct AppUpdateTests {
 static func main() throws {
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
  precondition(AppRelease(tag_name: "v1.0.0", html_url: url, draft: false, prerelease: true).safeURL == nil)
  print("PASS: numeric version comparison, equal/older releases, malformed versions, official URLs and stable releases only")
 }
}
