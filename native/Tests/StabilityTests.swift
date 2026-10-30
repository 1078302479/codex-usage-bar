import AppKit
import Foundation

@main struct StabilityTests {
    @MainActor static func main() throws {
        try recentLogs()
        if CommandLine.arguments.contains("--ui") { presentationLifecycle() }
        if CommandLine.arguments.contains("--window") { fallbackWindowLifecycle() }
        if CommandLine.arguments.contains("--exclusive") { exclusivePresentation() }
        if CommandLine.arguments.contains("--menu") { menuVisibility() }
    }

    static func recentLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-stability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Deliberately create out of modification-date order, across directories.
        for i in (0..<1000).map({ ($0 * 137) % 1000 }) {
            try autoreleasepool {
                let folder = root.appendingPathComponent(String(i % 7))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("\(i).jsonl")
                try Data().write(to: url)
                try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(Double(i))], ofItemAtPath: url.path)
            }
        }
        try Data().write(to: root.appendingPathComponent("newer.txt"))
        let hidden = root.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data().write(to: hidden.appendingPathComponent("hidden.jsonl"))
        let result = ClientLogMonitor.recentFiles(in: root)
        precondition(result.count == 24)
        precondition(result.map { Int($0.deletingPathExtension().lastPathComponent)! } == Array((976..<1000).reversed()))
        precondition(ClientLogMonitor.recentFiles(in: root, limit: 0).isEmpty)
        precondition(ClientLogMonitor.recentFiles(in: root, limit: 1).first == result.first)
        precondition(ClientLogMonitor.recentFiles(in: root, limit: 2000).count == 1000)
        let missing = root.appendingPathComponent("missing")
        precondition(ClientLogMonitor.recentFiles(in: missing).isEmpty)
        print("PASS: 1,000 nested logs select the newest 24, ignore non-logs/hidden files, and handle custom limits")
    }

    @MainActor static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    @MainActor static func menuVisibility() {
        _ = NSApplication.shared
        let suite = "usagebar-menu-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.isRefreshing = true
        let delegate = AppDelegate(state: state)
        delegate.configurePresentation()
        let item = delegate.statusItem!
        let button = item.button!
        for _ in 0..<10 {
            state.preferences.isStacked = true
            state.preferences.showIcon = false
            precondition(button.imagePosition == .imageOnly && button.image != nil)
            state.preferences.isStacked = false
            settle()
            precondition(button.imagePosition == .noImage && button.image == nil)
            precondition(!button.attributedTitle.string.isEmpty, "Text-only mode must retain a visible entry")
            precondition(item.isVisible && button.frame.width > 0, "Menu entry must remain present after layout changes")
            let title = button.attributedTitle
            for _ in 0..<20 { state.onDisplayChange?() }
            precondition(button.attributedTitle.isEqual(to: title) && item.isVisible)
            state.preferences.showIcon = true
            precondition(button.imagePosition == .imageLeading && button.image != nil)
        }
        print("PASS: menu remains visible across stacked/text/icon transitions and repeated refreshes")
    }

    @MainActor static func fallbackWindowLifecycle() {
        _ = NSApplication.shared
        let suite = "usagebar-window-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.isRefreshing = true
        let delegate = AppDelegate(state: state)
        delegate.configurePresentation()
        let original = state.preferences
        for _ in 0..<3 {
            weak var oldHost: NSViewController?
            autoreleasepool {
                delegate.showPanelWindow()
                let window = delegate.panelWindow!
                oldHost = window.contentViewController
                precondition(window.isVisible && oldHost != nil)
                delegate.showPanelWindow()
                precondition(delegate.panelWindow === window, "Reuse one fallback window")
                state.preferences.appearance = .dark
                precondition(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                window.close()
                precondition(delegate.panelWindow == nil && window.contentViewController == nil)
                state.preferences = original
            }
            settle()
            precondition(oldHost == nil, "Closing fallback releases SwiftUI host")
            precondition(state.preferences == original, "Fallback preserves user settings")
        }
        print("PASS: fallback window visibility, reuse, appearance sync, close/release and preserved preferences")
    }

    @MainActor static func exclusivePresentation() {
        _ = NSApplication.shared
        let suite = "usagebar-exclusive-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.isRefreshing = true // No live account/network queries in this test.
        let delegate = AppDelegate(state: state)
        delegate.configurePresentation()
        delegate.popover.animates = false
        for _ in 0..<5 {
            delegate.openSettings()
            precondition(delegate.settingsWindow?.isVisible == true)
            delegate.showPopover()
            settle()
            precondition(delegate.settingsWindow == nil, "Opening the menu panel must close settings")
            precondition(delegate.popover.isShown || delegate.panelWindow?.isVisible == true)
            precondition(state.panelVisible)
            delegate.openSettings()
            settle()
            precondition(!delegate.popover.isShown && delegate.panelWindow == nil, "Settings must close both quota hosts")
            precondition(!state.panelVisible && delegate.settingsWindow?.isVisible == true)
            delegate.showPanelWindow()
            precondition(delegate.settingsWindow == nil && delegate.panelWindow?.isVisible == true)
            delegate.openSettings()
            precondition(delegate.panelWindow == nil && delegate.settingsWindow?.isVisible == true)
        }
        delegate.settingsWindow?.close()
        precondition(delegate.settingsWindow == nil && !state.panelVisible)
        print("PASS: settings, status popover and fallback window are mutually exclusive across repeated transitions")
    }

    @MainActor static func presentationLifecycle() {
        let app = NSApplication.shared
        let suite = "usagebar-stability-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        // Exercise views without starting a watcher or any authenticated requests.
        state.isRefreshing = true
        let delegate = AppDelegate(state: state)
        app.delegate = delegate
        delegate.configurePresentation()
        delegate.popover.animates = false
        precondition(delegate.popover.contentViewController == nil)

        for _ in 0..<30 {
            weak var oldSettings: NSViewController?
            weak var oldWindow: NSWindow?
            autoreleasepool {
                delegate.openSettings()
                let window = delegate.settingsWindow!
                oldWindow = window
                oldSettings = window.contentViewController
                precondition(oldSettings != nil)
                delegate.openSettings()
                precondition(delegate.settingsWindow === window)
                window.close()
                precondition(delegate.settingsWindow == nil)
                precondition(window.contentViewController == nil)
            }
            settle()
            precondition(oldSettings == nil, "Closed settings must release their SwiftUI host")
            precondition(oldWindow == nil, "Closed settings window must be released")
        }
        state.panelPreferredHeight = 500
        for _ in 0..<100 {
            weak var oldPanel: NSViewController?
            autoreleasepool {
                delegate.showPopover()
                precondition(delegate.popover.isShown)
                oldPanel = delegate.popover.contentViewController
                precondition(oldPanel != nil)
                delegate.popover.performClose(nil)
            }
            settle()
            precondition(delegate.popover.contentViewController == nil)
            precondition(oldPanel == nil, "Hidden panel must release its SwiftUI host")
            precondition(state.panelPreferredHeight == 500)
        }
        state.preferences.isStacked = true
        let image = delegate.statusItem.button!.image
        state.now = Date().addingTimeInterval(30)
        state.onDisplayChange?()
        precondition(delegate.statusItem.button!.image === image, "Unchanged menu artwork must be reused")
        state.preferences.showIcon.toggle()
        precondition(delegate.statusItem.button!.image !== image, "Changed menu preferences must update artwork")
        precondition(delegate.popover.contentViewController == nil)
        print("PASS: 30 settings and 100 panel cycles release view hosts, preserve panel size, and reuse unchanged menu artwork")
    }
}
