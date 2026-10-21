import AppKit
@main struct ExportBrandMark {
    @MainActor static func main() throws {
        let side = 256
        let image = ProviderIcon.codex(size: CGFloat(side))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        image.draw(in:NSRect(x:0,y:0,width:side,height:side))
        NSGraphicsContext.restoreGraphicsState()
        precondition(bitmap.colorAt(x:0,y:0)!.alphaComponent==0)
        var visible=0
        for y in 0..<side { for x in 0..<side {
            let c=bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            if c.alphaComponent > 0.99 { precondition(c.redComponent > 0.99 && c.greenComponent > 0.99 && c.blueComponent > 0.99); visible += 1 }
        } }
        precondition(visible > 1000)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("Transparent single-color brand mark verified")
    }
}
