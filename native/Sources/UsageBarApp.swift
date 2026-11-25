import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    let state: AppState
    private(set) var statusItem: NSStatusItem!
    let popover = NSPopover()
    private(set) var settingsWindow: NSWindow?
    private(set) var panelWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var menuImageKey: MenuImageKey?
    private var signalTimer: Timer?
    private var signalDimmed = false

    private struct MenuImageKey: Equatable {
        let stacked: Bool
        let picture: TideMenuPicture?
        let lines: [String]
        let showIcon: Bool
        let appearance: AppAppearance
        let colors: [[NSColor]]
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
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(identifier: LowQuotaReminder.forecastCategory, actions: [
                UNNotificationAction(identifier: LowQuotaReminder.showRecommendation, title: "查看备用账号", options: .foreground),
                UNNotificationAction(identifier: LowQuotaReminder.later, title: "稍后")
            ], intentIdentifiers: [])
        ])
        configurePresentation()
        state.start()
        state.appUpdates.start()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state.pause() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state.resume(); self?.state.appUpdates.checkIfDue() }
        })
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleURL?.path == DualClientController.desktopPath else { return }
                Task { @MainActor in
                    guard let self, !self.state.paused else { return }
                    self.state.dualClient.desktopProcessChanged()
                }
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showPopover() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        state.reminders.refreshPermission()
        Task { await state.lowQuotaReminders.refreshPermission() }
        state.panelOpened()
        if settingsWindow == nil && panelWindow == nil && !popover.isShown { showPopover() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let profile = response.notification.request.content.userInfo["recommendedProfileID"] as? String
        guard action != LowQuotaReminder.later else { return }
        await MainActor.run {
            self.showPopover()
            if action == LowQuotaReminder.showRecommendation, let profile, self.state.canSwitchAccount(profile) {
                self.state.selectedAccountID = profile
                self.state.accountPickerPresented = true
            }
        }
    }

    private func updatePresentation() {
        guard let button = statusItem?.button else { return }
        let displayed = state.menuBarAccount
        let lines = QuotaPresentation.stackedLines(snapshot: displayed.snapshot, preferences: state.preferences, verified: displayed.verified, now: displayed.now)
        let colors = MenuBarRenderer.stackedColors(snapshot: displayed.snapshot, preferences: state.preferences, verified: displayed.verified, now: displayed.now)
        let style = state.preferences.menuStyle
        let stacked = style == .stack
        let picture = style == .stack || style == .legacy ? nil : TideMenuPicture.make(account: displayed, preferences: state.preferences)
        let imageKey = MenuImageKey(stacked: stacked, picture: picture,
                                   lines: stacked ? lines : [],
                                   showIcon: state.preferences.showIcon, appearance: state.preferences.appearance,
                                   colors: colors)
        updateSignalTimer(for: picture)
        if let picture {
            if menuImageKey != imageKey { button.image = picture.image(dimmedSignal: signalDimmed) }
            button.imagePosition = .imageOnly
            if !button.title.isEmpty { button.title = "" }
        } else if stacked {
            if menuImageKey != imageKey {
                button.image = MenuBarRenderer.stackedImage(lines: lines, showIcon: state.preferences.showIcon, colors: colors)
            }
            button.imagePosition = .imageOnly
            // Install the replacement artwork before removing the old title.
            // An empty variable-length item can otherwise collapse during layout.
            if !button.title.isEmpty { button.title = "" }
        } else {
            let title = MenuBarRenderer.title(snapshot: displayed.snapshot, preferences: state.preferences, verified: displayed.verified, now: displayed.now)
            if !button.attributedTitle.isEqual(to: title) { button.attributedTitle = title }
            if state.preferences.showIcon {
                if menuImageKey != imageKey { button.image = TideAppIcon.menuGlyph }
                button.imagePosition = .imageLeading
            } else {
                // Restore text rendering when leaving the stacked image layout.
                button.imagePosition = .noImage
                button.image = nil
            }
        }
        menuImageKey = imageKey
        button.toolTip = [state.secondAccount == nil ? "CodexUsageBar" : ("CodexUsageBar · " + state.accountRole(state.dualClient.activeProfileID ?? "primary")), displayed.snapshot?.accountLabel ?? "账号待核验", displayed.updateStatus.title,
                          displayed.statusDetail, displayed.timestampLabel, displayed.watchDescription].joined(separator: "\n")
        button.setAccessibilityLabel("CodexUsageBar " + (picture?.imageDescription ?? (stacked ? lines.joined(separator: "，") : displayed.menuTitle)))
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
        panelWindow?.appearance = appearance
        panelWindow?.contentView?.appearance = appearance
    }

    private func updateSignalTimer(for picture: TideMenuPicture?) {
        let pulse = picture?.shouldPulse == true && !state.paused && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard pulse else {
            signalTimer?.invalidate()
            if signalDimmed, let picture { statusItem.button?.image = picture.image() }
            signalTimer = nil
            signalDimmed = false
            return
        }
        guard signalTimer == nil else { return }
        signalTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let picture = self.menuImageKey?.picture, picture.shouldPulse else { return }
                self.signalDimmed.toggle()
                self.statusItem.button?.image = picture.image(dimmedSignal: self.signalDimmed)
            }
        }
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
        settingsWindow?.close()
        NSApp.activate(ignoringOtherApps: true)
        if let panelWindow {
            state.setPanelVisible(true)
            panelWindow.makeKeyAndOrderFront(nil)
            return
        }
        guard let button = statusItem.button else { return }
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: QuotaPanelView(state: state, openSettings: { [weak self] in self?.openSettings() }))
        }
        state.now = Date()
        updatePresentation()
        resizePopover(requestedHeight: nil)
        state.panelOpened(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        state.setPanelVisible(popover.isShown)
        popover.contentViewController?.view.window?.makeKey()
        if !popover.isShown { showPanelWindow() }
    }

    func showPanelWindow() {
        settingsWindow?.close()
        closePopoverImmediately()
        if let panelWindow { panelWindow.makeKeyAndOrderFront(nil); return }
        popover.contentViewController = nil
        let host = NSHostingController(rootView: QuotaPanelView(state: state, openSettings: { [weak self] in self?.openSettings() }))
        let window = NSWindow(contentViewController: host)
        window.title = "CodexUsageBar"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        panelWindow = window
        state.setPanelVisible(true)
        updatePresentation()
        window.makeKeyAndOrderFront(nil)
    }
    func popoverDidClose(_ notification: Notification) {
        // Detach the SwiftUI observer tree so background quota/timer publications
        // cannot recompute or redraw a hidden panel. Business state stays alive.
        guard !popover.isShown else { return }
        if panelWindow == nil { state.setPanelVisible(false) }
        popover.contentViewController = nil
        state.panelDragStart = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panelWindow {
            window.delegate = nil
            window.contentViewController = nil
            panelWindow = nil
            state.setPanelVisible(false)
            return
        }
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        window.delegate = nil
        window.contentViewController = nil
        settingsWindow = nil
    }
    func windowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panelWindow { state.setPanelVisible(false) }
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panelWindow {
            state.setPanelVisible(true); state.panelOpened()
        }
    }

    private func resizePopover(requestedHeight: CGFloat?) {
        guard let button = statusItem?.button else { return }
        let available = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let maximum = max(160, available - 24)
        if let requestedHeight { state.panelPreferredHeight = requestedHeight }
        // Header, footer and resize grip remain outside the scrollable content.
        let automatic = state.preferences.panelFitsScreen == true ? min(maximum, OrbitLayout.defaultPanelHeight) : (state.panelContentHeight > 0 ? min(OrbitLayout.defaultPanelHeight, state.panelContentHeight + (state.accountPickerPresented ? 66 : 108)) : OrbitLayout.defaultPanelHeight)
        let desired = state.panelPreferredHeight ?? automatic
        let height = min(maximum, max(240, desired))
        let width = OrbitLayout.panelWidth
        guard abs(state.panelHeight - height) > 0.5 || popover.contentSize.height != height || popover.contentSize.width != width else { return }
        state.panelHeight = height
        let size = NSSize(width: width, height: height)
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
    }
    @objc private func refreshQuota() { state.refreshAllAccounts() }
    private func closePopoverImmediately() {
        let animates = popover.animates
        popover.animates = false
        popover.performClose(nil)
        popover.animates = animates
    }

    @objc func openSettings() {
        let sourceScreen = popover.contentViewController?.view.window?.screen ?? panelWindow?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? statusItem?.button?.window?.screen ?? NSScreen.main
        closePopoverImmediately()
        panelWindow?.close()
        if settingsWindow == nil {
            let screenFrame = sourceScreen?.visibleFrame ?? CGRect(origin: .zero, size: OrbitLayout.settingsSize)
            let frame = OrbitLayout.settingsFrame(in: screenFrame)
            let host = NSHostingController(rootView: UsageSettingsView(state: state, size: frame.size))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "CodexUsageBar 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.setFrame(frame, display: false)
            settingsWindow = window; updatePresentation()
        }
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await state.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        signalTimer?.invalidate()
        state.appUpdates.stop()
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
