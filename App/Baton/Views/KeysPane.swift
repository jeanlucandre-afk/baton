import BatonCore
import SwiftUI

/// One API key Baton can use: what it does, how much it matters, where to get it and what changes without it.
struct APIKey: Identifiable {
    let service: String
    let name: String
    /// "Recommended" or "Optional", shown beside the name.
    let need: String
    let does: String
    let without: String
    let url: URL
    var id: String { service }

    static let jev = APIKey(service: KeyStore.jev, name: "Jev", need: "Recommended",
                            does: "Tells when a chat is finished or needs you. From typesafe.ai.",
                            without: "Without it Baton lists your chats but can't tell when one is done.",
                            url: URL(string: "https://typesafe.ai")!)
    static let gemini = APIKey(service: KeyStore.gemini, name: "Gemini", need: "Optional",
                               does: "Writes the one-line pings, task names and steps, and repairs sidebars. From Google AI Studio.",
                               without: "Without it Apple's on-device model writes them, or Baton uses plain text.",
                               url: URL(string: "https://aistudio.google.com/apikey")!)
    static let all = [jev, gemini]

    /// Tries a key; nil when it works, else a short reason.
    func test(_ key: String) async -> String? {
        if service == KeyStore.gemini { return await Smart.check(key: key) }
        let state: [String: any Sendable] = [
            "app": "ChatGPT", "window_title": "Test", "stop_button_visible": false, "text_still_changing": false,
            "seconds_without_change": 6, "latest_text": "Done. I rewrote the pricing page headline and saved the file."
        ]
        do {
            _ = try await Jev(key: key).classify(state: state)
            return nil
        } catch JevError.http(let code, let body) {
            return "HTTP \(code)" + (body.isEmpty ? "" : ": " + String(body.prefix(100)))
        } catch {
            return "\(error)"
        }
    }
}

/// A key's secure field with Save, Remove and Test. Used by Settings › Keys and onboarding.
struct KeyRow: View {
    let key: APIKey
    var compact = false
    @State private var text = ""
    @State private var saved = false
    @State private var result: Result?
    /// What's running ("Saving…", "Removing…", "Testing…"): Keychain work runs `security` off the main thread.
    @State private var busy: String?

    enum Result: Equatable { case ok, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(key.name).font(.headline)
                Text(key.need)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Label(saved ? "Saved" : "Not set", systemImage: saved ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(saved ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            Text(key.does).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // Onboarding has no room for the result line's fallback, so it says it up here.
            if compact { Text(key.without).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                SecureField(saved ? "Paste a new key to replace it" : "Paste your \(key.name) key", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save).disabled(busy != nil || text.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Test") { Task { await test() } }.disabled(busy != nil || (!saved && text.isEmpty))
                if saved { Button("Remove", role: .destructive, action: remove).disabled(busy != nil) }
            }
            HStack(spacing: 6) {
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                } else if let result {
                    switch result {
                    case .ok: Label("Works", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let why): Label(why, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
                    }
                } else if !compact {
                    Text(key.without).foregroundStyle(.secondary)
                }
                Spacer()
                if compact {
                    Link(destination: key.url) { Label("Get a key", systemImage: "arrow.up.right") }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Link("Get a key", destination: key.url)
                }
            }
            .font(.caption)
        }
        .onAppear { saved = KeyStore.exists(key.service) }
    }

    private func save() {
        let k = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, busy == nil else { return }
        run("Saving…") { [service = key.service] in try KeyStore.save(k, service: service) } then: {
            text = ""
            saved = true
        }
    }

    private func remove() {
        guard busy == nil else { return }
        run("Removing…") { [service = key.service] in try KeyStore.remove(service) } then: { saved = false }
    }

    /// Runs Keychain work off the main thread (each step is a `security` process), then picks up the change.
    private func run(_ label: String, _ work: @escaping @Sendable () throws -> Void, then done: @escaping () -> Void) {
        busy = label
        result = nil
        Task {
            let failure: (any Error)? = await Task.detached(priority: .userInitiated) {
                do { try work(); return nil } catch { return error }
            }.value
            if let failure {
                result = .failed("\(failure)")
            } else {
                done()
                await AppModel.shared.reloadKeys()
            }
            busy = nil
        }
    }

    /// Tests what's typed, or else the saved key.
    private func test() async {
        guard busy == nil else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = "Testing…"
        defer { busy = nil }
        let service = key.service
        let stored = typed.isEmpty ? await Task.detached { KeyStore.read(service) }.value : nil
        guard let k = typed.isEmpty ? stored : typed else { return }
        let why = await key.test(k)
        result = why.map(Result.failed) ?? .ok
    }
}

struct KeysPane: View {
    var body: some View {
        Form {
            ForEach(APIKey.all) { k in
                Section { KeyRow(key: k) }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Both are optional. Keys stay in your login Keychain. Window text is read on your Mac; only the end of attached windows is sent to Jev, with emails, keys and phone numbers removed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
