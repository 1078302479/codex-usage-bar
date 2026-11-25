import SwiftUI
import AppKit

/// Layout and visual tokens shared by the quota panel and settings window.
enum OrbitLayout {
    static let panelWidth: CGFloat = 372
    static let defaultPanelHeight: CGFloat = 820
    static let settingsSize = CGSize(width: 860, height: 650)

    static func settingsFrame(in visibleFrame: CGRect) -> CGRect {
        let horizontalInset = min(16, visibleFrame.width / 16)
        let verticalInset = min(16, visibleFrame.height / 16)
        let available = visibleFrame.insetBy(dx: horizontalInset, dy: verticalInset)
        let width = min(settingsSize.width, available.width)
        let height = min(settingsSize.height, available.height)
        return CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
                      width: width, height: height)
    }
}

struct OrbitPreviewKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var orbitPreview: Bool {
        get { self[OrbitPreviewKey.self] }
        set { self[OrbitPreviewKey.self] = newValue }
    }
}

extension View {
    func orbitCard(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return background {
            shape.fill(PanelPalette.background)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
        .overlay { shape.strokeBorder(PanelPalette.border).allowsHitTesting(false) }
    }
}

struct OrbitActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(prominent ? PanelPalette.background : PanelPalette.primary)
            .background(prominent ? PanelPalette.primary : PanelPalette.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? Color.clear : PanelPalette.border, lineWidth: 1) }
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

@MainActor
struct OrbitMark: View {
    var size: CGFloat = 26
    private static let appIcon: NSImage? = {
        let bundle = Bundle.main
        guard let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else { return nil }
        let file = (name as NSString).pathExtension.isEmpty ? name + ".icns" : name
        return bundle.url(forResource: file, withExtension: nil).flatMap { NSImage(contentsOf: $0) }
    }()

    var body: some View {
        Group {
            if let appIcon = Self.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                HStack(spacing: 0) {
                    Text("›").font(.system(size: size * 0.8, weight: .medium))
                    Text("_").font(.system(size: size * 0.52, weight: .medium)).foregroundStyle(PanelPalette.shortRing)
                }
                .foregroundStyle(PanelPalette.background).frame(width: size, height: size)
                .background(PanelPalette.primary, in: RoundedRectangle(cornerRadius: size * 0.3))
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
struct OrbitSwitchButton: View {
    @ObservedObject var owner: AppState
    @ObservedObject var account: AppState
    @ObservedObject var controller: DualClientController
    let profileID: String
    var expanded = false
    var subtle = false
    var title = "切换账号"
    @Environment(\.orbitPreview) private var preview
    private var enabled: Bool {
        owner.canSwitchAccount(profileID)
    }
    var body: some View {
        Button { owner.pendingSwitchConfirmation = profileID } label: {
            HStack(spacing: 5) {
                if controller.isSwitching && controller.targetProfileID == profileID { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.left.arrow.right") }
                Text(controller.isSwitching && controller.targetProfileID == profileID ? "切换中…" : title)
            }.frame(maxWidth: expanded ? .infinity : nil)
        }.buttonStyle(OrbitAccountSwitchStyle(subtle: subtle)).disabled(!enabled).opacity(enabled ? 1 : 0.45)
            .help("切换至此账号并重启客户端，请先保存任务")
            .accessibilityLabel("切换至 \(account.snapshot?.accountLabel ?? "此账号") 并重启客户端")
            .alert("切换账号并重启客户端？", isPresented: Binding(get: { owner.pendingSwitchConfirmation == profileID }, set: { if !$0 { owner.pendingSwitchConfirmation = nil } })) {
                Button("取消", role: .cancel) { }
                Button(preview ? "模拟切换" : "切换并重启") {
                    if preview, let scope = account.snapshot?.accountScope {
                        _ = controller.confirmProfile(scope: scope)
                        owner.selectedAccountID = profileID
                    } else { controller.switchToProfile(profileID, cliPath: owner.preferences.cliPath) }
                }
            } message: {
                Text("将切换至 \(account.snapshot?.accountLabel ?? "此账号")。客户端会重启，请先保存正在进行的任务。现有项目和聊天继续共用。" + (preview ? "\n当前为演示预览，不会重启客户端。" : ""))
            }
    }
}

struct OrbitAccountSwitchStyle: ButtonStyle {
    var subtle: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 30)
            .foregroundStyle(subtle ? PanelPalette.primary : PanelPalette.background)
            .background(subtle ? PanelPalette.background : PanelPalette.primary, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(subtle ? PanelPalette.primary.opacity(0.25) : Color.clear) }
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
