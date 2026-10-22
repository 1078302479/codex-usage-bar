import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    let state: AppState
    private(set) var statusItem: NSStatusItem!
    let popover = NSPopover()
    private(set) var settingsWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var menuImageKey: MenuImageKey?

    private struct MenuImageKey: Equatable {
        let stacked: Bool
        let lines: [String]
        let showIcon: Bool
        let appearance: AppAppearance
        let colors: [[String?]]
    }

    init(state: AppState = AppState()) {
        self.state = state
        super.init()
    }

    func configurePresentation() {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        popover.behavior = .transient
        popover.delegate = self
        state.onPanelResize = { [weak self] height in self?.resizePopover(requestedHeight: height) }
        state.onDisplayChange = { [weak self] in self?.updatePresentation() }
        updatePresentation()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        configurePresentation()
        state.start()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state.pause() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state.resume() }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showPopover() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        state.reminders.refreshPermission()
        state.panelOpened()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.showPopover() }
    }

    private func updatePresentation() {
        guard let button = statusItem?.button else { return }
        let lines = QuotaPresentation.stackedLines(snapshot: state.snapshot, preferences: state.preferences, verified: state.verified, now: state.now)
        let colors = MenuBarRenderer.stackedColors(snapshot: state.snapshot, preferences: state.preferences, verified: state.verified, now: state.now)
        let imageKey = MenuImageKey(stacked: state.preferences.isStacked,
                                   lines: state.preferences.isStacked ? lines : [],
                                   showIcon: state.preferences.showIcon, appearance: state.preferences.appearance, colors: colors)
        if state.preferences.isStacked {
            button.title = ""
            if menuImageKey != imageKey {
                button.image = MenuBarRenderer.stackedImage(lines: lines, showIcon: state.preferences.showIcon, colors: colors)
            }
            button.imagePosition = .imageOnly
        } else {
            button.title = state.menuTitle
            button.attributedTitle = MenuBarRenderer.title(snapshot: state.snapshot, preferences: state.preferences, verified: state.verified, now: state.now)
            if state.preferences.showIcon {
                if menuImageKey != imageKey { button.image = ProviderIcon.codex() }
                button.imagePosition = .imageLeading
            } else { button.image = nil }
        }
        menuImageKey = imageKey
        button.toolTip = ["CodexUsageBar", state.snapshot?.accountLabel ?? "账号待核验", state.updateStatus.title,
                          state.statusDetail, state.timestampLabel, state.watchDescription].joined(separator: "\n")
        button.setAccessibilityLabel("CodexUsageBar " + (state.preferences.isStacked ? lines.joined(separator: "，") : state.menuTitle))
        let appearance: NSAppearance?
        switch state.preferences.appearance {
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .light: appearance = NSAppearance(named: .aqua)
        case .system: appearance = nil
        }
        // AppKit owns appearance for both native hosts. A SwiftUI preferredColorScheme
        // can retain the previous forced scheme when changed back to nil.
        popover.appearance = appearance
        popover.contentViewController?.view.appearance = appearance
        settingsWindow?.appearance = appearance
        settingsWindow?.contentView?.appearance = appearance
    }

    @objc private func statusClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let button = statusItem.button {
            let menu = NSMenu()
            let refresh = NSMenuItem(title: "核验额度", action: #selector(refreshQuota), keyEquivalent: "r"); refresh.target = self; menu.addItem(refresh)
            let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出 CodexUsageBar", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: QuotaPanelView(state: state, openSettings: { [weak self] in self?.openSettings() }))
        }
        state.now = Date()
        updatePresentation()
        resizePopover(requestedHeight: nil)
        state.panelOpened(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func popoverDidClose(_ notification: Notification) {
        // Detach the SwiftUI observer tree so background quota/timer publications
        // cannot recompute or redraw a hidden panel. Business state stays alive.
        guard !popover.isShown else { return }
        popover.contentViewController = nil
        state.panelDragStart = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        window.delegate = nil
        window.contentViewController = nil
        settingsWindow = nil
    }
    private func resizePopover(requestedHeight: CGFloat?) {
        guard let button = statusItem?.button else { return }
        let available = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let maximum = max(160, available - 24)
        if let requestedHeight { state.panelPreferredHeight = requestedHeight }
        // Header, footer and resize grip remain outside the scrollable content.
        let desired = state.panelPreferredHeight ?? (state.panelContentHeight > 0 ? state.panelContentHeight + 94 : 820)
        let height = min(maximum, max(240, desired))
        guard abs(state.panelHeight - height) > 0.5 || popover.contentSize.height != height else { return }
        state.panelHeight = height
        let size = NSSize(width: 390, height: height)
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
    }
    @objc private func refreshQuota() { state.refresh() }
    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: UsageSettingsView(state: state))
            let window = NSWindow(contentViewController: host)
            window.title = "CodexUsageBar 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.delegate = self
            window.isReleasedWhenClosed = false; window.center()
            settingsWindow = window; updatePresentation()
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await state.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

#if !STABILITY_TEST
@main
struct CodexUsageBarApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        if let id = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            running.activate(options: []); return
        }
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
