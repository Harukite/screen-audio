import SwiftUI
import ScreenAudioCore

/// Single-host root view — never rebuilt. VolumeViewModel.showSettings toggles between
/// Volume / Settings via SwiftUI conditional rendering, no NSHostingView swap → no crash.
struct PanelRootView: View {
    @ObservedObject var volumeVM: VolumeViewModel
    @ObservedObject var settingsVM: SettingsViewModel
    var onQuit: () -> Void

    var body: some View {
        if volumeVM.showSettings {
            SettingsView(model: settingsVM)
        } else {
            VolumePopoverView(model: volumeVM, onQuit: onQuit)
        }
    }
}
