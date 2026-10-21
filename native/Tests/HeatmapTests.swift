import AppKit

@main struct HeatmapTests {
    @MainActor static func main() {
        let view = ActivityHeatmapView(frame: NSRect(x: 0, y: 0, width: 350, height: 138))
        view.update(days: TokenActivity.heatmapDays(), values: [:])
        precondition(view.index(at: NSPoint(x: 23, y: 23)) == 0)
        precondition(view.index(at: NSPoint(x: 23, y: 36)) == 1)
        precondition(view.index(at: NSPoint(x: 36, y: 23)) == 7)
        precondition(view.index(at: NSPoint(x: 343, y: 102)) == 181)
        precondition(view.index(at: NSPoint(x: 20, y: 23)) == nil)
        precondition(view.index(at: NSPoint(x: 23, y: 33)) == nil)
        precondition(view.index(at: NSPoint(x: 351, y: 23)) == nil)
        precondition(view.index(at: NSPoint(x: 23, y: 115)) == nil)
        view.setFrameSize(NSSize(width: 300, height: 138))
        precondition(view.index(at: NSPoint(x: 297, y: 102)) == 181)
        print("9 heatmap hit-region checks passed")
    }
}
