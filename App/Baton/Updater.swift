import Combine
import Sparkle
import SwiftUI

/// Auto-updates through Sparkle. The feed is `appcast.xml` on the download page (see Info.plist
/// `SUFeedURL`); every update is checked against our EdDSA key (`SUPublicEDKey`) before it's installed,
/// so it works without Apple notarization. Sparkle downloads the update itself, so a Gatekeeper
/// "Open Anyway" is only ever needed for the very first install.
@MainActor final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false
    private var watch: AnyCancellable?

    private init() {
        // Starts the scheduled checks (daily, on by default via Info.plist) right away.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        watch = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }
    }

    var updater: SPUUpdater { controller.updater }

    func checkNow() { controller.checkForUpdates(nil) }
}

/// "Check for Updates…", greyed out while a check is already running.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Button("Check for Updates…") { updater.checkNow() }.disabled(!updater.canCheck)
    }
}

/// Settings › General: whether Baton looks for updates and installs them on its own.
struct UpdateSettingsSection: View {
    private let updater = Updater.shared.updater
    @State private var check = true
    @State private var install = true

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $check)
                .onChange(of: check) { _, on in updater.automaticallyChecksForUpdates = on }
            Toggle("Install updates automatically", isOn: $install)
                .onChange(of: install) { _, on in updater.automaticallyDownloadsUpdates = on }
                .disabled(!check)
            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .foregroundStyle(.secondary)
                Spacer()
                CheckForUpdatesButton()
            }
        } footer: {
            Text("Updates are checked once a day and installed in the background; the new version starts the next time Baton opens.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            check = updater.automaticallyChecksForUpdates
            install = updater.automaticallyDownloadsUpdates
        }
    }
}
