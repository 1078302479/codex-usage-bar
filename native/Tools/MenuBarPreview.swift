import AppKit

@main struct MenuBarPreview {
    @MainActor static func main() throws {
        let image = MenuBarRenderer.stackedImage(lines: ["7d 88%", "5h 89%"], showIcon: true)
        precondition(image.size.height == 22 && !image.isTemplate)
        let textOnly = MenuBarRenderer.stackedImage(lines: ["7d 88%", "5h 89%"], showIcon: false)
        precondition(textOnly.isTemplate && textOnly.size.width < image.size.width)
        let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        for (name, y, shade) in [(NSAppearance.Name.aqua, CGFloat(120), CGFloat(0.95)), (.darkAqua, CGFloat(0), CGFloat(0.14))] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                NSColor(white: shade, alpha: 1).setFill(); NSRect(x: 0, y: y, width: 600, height: 120).fill()
                image.draw(in: NSRect(x: 30, y: y + 16, width: image.size.width * 4, height: 88))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try canvas.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Provider resource, 22pt layout, color icon and text-only template verified")
    }
}
