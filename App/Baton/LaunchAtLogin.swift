import ServiceManagement
import SwiftUI

/// "Open Baton at login", through the system's login items (SMAppService). The system keeps the setting,
/// so it's read back each time instead of stored here. Used by onboarding and Settings › General.
struct OpenAtLoginToggle: View {
    var label = "Open Baton at login"
    @State private var on = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(label, isOn: Binding(get: { on }, set: set))
            if let note {
                HStack(spacing: 6) {
                    Text(note).foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        let status = SMAppService.mainApp.status
        on = status == .enabled
        note = status == .requiresApproval ? "Allow Baton in System Settings › General › Login Items." : nil
    }

    private func set(_ want: Bool) {
        do {
            if want { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            refresh()
            note = want ? "Couldn't add Baton to your login items." : "Couldn't remove Baton from your login items."
        }
    }
}
