import AppKit
let output = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:720,pixelsHigh:460,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
let scale = NSAffineTransform(); scale.scale(by:1); scale.concat()
NSColor(srgbRed:0.965,green:0.976,blue:0.992,alpha:1).setFill(); NSRect(x:0,y:0,width:720,height:460).fill()
func text(_ value:String, x:CGFloat,y:CGFloat,size:CGFloat,weight:NSFont.Weight,color:NSColor) {
 (value as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color])
}
let ink = NSColor(srgbRed:0.12,green:0.19,blue:0.30,alpha:1)
text("把 CodexUsageBar 拖到应用程序",x:48,y:376,size:24,weight:.semibold,color:ink)
text("安装后，从“应用程序”打开 CodexUsageBar",x:49,y:346,size:13,weight:.regular,color:ink.withAlphaComponent(0.62))
let arrow = NSBezierPath(); arrow.move(to:NSPoint(x:333,y:240)); arrow.line(to:NSPoint(x:386,y:240))
arrow.move(to:NSPoint(x:372,y:254)); arrow.line(to:NSPoint(x:386,y:240)); arrow.line(to:NSPoint(x:372,y:226))
arrow.lineWidth=4; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
NSColor(srgbRed:0.27,green:0.48,blue:0.77,alpha:1).setStroke(); arrow.stroke()
NSColor(srgbRed:0.85,green:0.89,blue:0.94,alpha:1).setFill(); NSRect(x:48,y:95,width:624,height:1).fill()
text("拖动完成后，可以推出此安装磁盘。",x:48,y:65,size:12,weight:.regular,color:ink.withAlphaComponent(0.65))
text("CodexUsageBar 0.1.6    ·    Apple Silicon    ·    macOS 14 或更高版本",x:48,y:35,size:10,weight:.regular,color:ink.withAlphaComponent(0.45))
NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using:.png,properties:[:])!
try png.write(to:URL(fileURLWithPath:output))
