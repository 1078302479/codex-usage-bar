import SwiftUI

/// Compatibility entry point for callers of the previous multi-account panel.
@MainActor
struct DualAccountPanelView: View {
    @ObservedObject var primary: AppState
    @ObservedObject var controller: DualClientController
    let openSettings: () -> Void
    var body: some View {
        OrbitPanelContent(owner: primary, controller: controller, openSettings: openSettings)
    }
}
