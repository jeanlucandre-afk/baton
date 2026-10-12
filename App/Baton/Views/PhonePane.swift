import AppKit
import BatonCore
import CoreImage.CIFilterBuiltins
import Defaults
import SwiftUI

/// Settings › Phone: the channel's QR code, a test, and when to ping (from the PH-Settings board).
struct PhonePane: View {
    private var phone = Phone.shared
    @Default(.phoneOn) private var on
    @Default(.phoneTopic) private var topic
    @Default(.phoneServer) private var serverText
    @Default(.phoneHideNames) private var hideNames
    @Default(.phoneAwayMinutes) private var awayMinutes
    @State private var qr: NSImage?
    @State private var copied = false

    private var server: URL? { PhoneChannel.server(serverText) }
    private var subscribe: String? { server.map { PhoneChannel.subscribeURL(server: $0, topic: topic) } }
    private var web: String? { server.map { PhoneChannel.webURL(server: $0, topic: topic) } }

    var body: some View {
        Form {
            Section { hero }
            Section {
                Toggle(isOn: $on) {
                    row("Ping my phone", "Finished, needs you, and stuck runs: the same news as the notch.")
                }
                Picker(selection: $awayMinutes) {
                    Text("Screen locked").tag(0.0)
                    Text("2 minutes idle").tag(2.0)
                    Text("5 minutes idle").tag(5.0)
                    Text("10 minutes idle").tag(10.0)
                } label: {
                    row("Only when I'm away", "A locked or sleeping screen always counts. At the Mac you get the notch.")
                }
                .disabled(!on)
                Toggle(isOn: $hideNames) {
                    row("Hide task names", "Pings say “Codex finished” and nothing more.")
                }
                .disabled(!on)
            } header: {
                Text("When to ping your phone")
            }
            Section {
                TextField("Server", text: $serverText, prompt: Text("ntfy.sh"))
                    .onSubmit { phone.test = .idle }
                if server == nil {
                    Text("Not a server address. Try https://ntfy.example.com.").font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Pings go through ntfy on a channel only you know. Only the line on your phone is sent: never chat text. Several pings close together arrive as one.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { phone.ensureTopic() }
        .task(id: subscribe) { qr = subscribe.flatMap(QRCode.image) }
        .onChange(of: on) { _, isOn in if !isOn { phone.stop() } }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            Group {
                if let qr {
                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                } else {
                    Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(.black.opacity(0.25))
                }
            }
            .padding(12)
            .frame(width: 168, height: 168)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("QR code to subscribe to Baton's channel in ntfy")

            VStack(alignment: .leading, spacing: 10) {
                Text("Pings on your phone").font(.system(size: 20, weight: .bold))
                Text("1. Install **ntfy** on your iPhone or Android. Free, no account.\n2. Scan this code with your camera, or add the channel by hand.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                HStack(spacing: 12) {
                    Text(web ?? "No valid server")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    Button(copied ? "Copied" : "Copy") { copy() }
                        .buttonStyle(.link).disabled(web == nil)
                    Button("New channel") { phone.newChannel() }
                        .buttonStyle(.link).foregroundStyle(.secondary)
                        .help("Makes a new private channel. Scan the new code; the old one stops getting pings.")
                }
                HStack(spacing: 8) {
                    status
                    Spacer(minLength: 8)
                    Button("Send test") { phone.sendTest() }
                        .controlSize(.small)
                        .disabled(phone.test == .sending || server == nil)
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var status: some View {
        switch phone.test {
        case .idle:
            Text("Send a test to check it arrives.").font(.caption).foregroundStyle(.secondary)
        case .sending:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Sending…").font(.caption).foregroundStyle(.secondary) }
        case .sent(let at):
            Label("Sent at \(at.formatted(date: .omitted, time: .shortened)). Check your phone.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let why):
            Label("Couldn't send: \(why)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func row(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(sub).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copy() {
        guard let web else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(web, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// A crisp QR code from Core Image (scaled up without smoothing).
enum QRCode {
    static func image(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let big = out.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(big, from: big.extent) else { return nil }
        return NSImage(cgImage: cg, size: big.extent.size)
    }
}

#if DEBUG
#Preview("Phone settings") {
    PhonePane().frame(width: 620, height: 640)
}
#endif
