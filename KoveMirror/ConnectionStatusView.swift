import SwiftUI

/// The two maps are the home screen. No dashboard or app picker.
struct ConnectionStatusView: View {
    @StateObject private var bleController: BleController
    init(bleController: BleController? = nil) {
        _bleController = StateObject(wrappedValue: bleController ?? BleController(
            isPreview: ProcessInfo.processInfo.arguments.contains("--ui-screenshots")))
    }
    var body: some View { WebCockpitView(bleController: bleController) }
}
