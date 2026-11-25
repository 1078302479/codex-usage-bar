import AppKit

@MainActor
enum TideAppIcon {
    static let menuGlyph: NSImage = {
        guard let url = Bundle.main.url(forResource: "TideMenuGlyph", withExtension: "png"),
              let glyph = NSImage(contentsOf: url) else {
            return ProviderIcon.codex()
        }
        glyph.size = NSSize(width: 17, height: 17)
        glyph.isTemplate = true
        return glyph
    }()
}
