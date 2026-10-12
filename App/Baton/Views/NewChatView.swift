import BatonCore
import SwiftUI

/// "New ChatGPT chat · Pricing copy": add it to the task Baton thinks it belongs to, start a new task, or ignore.
struct NewChatView: View {
    private var model = AppModel.shared

    var body: some View {
        if let s = model.chatSuggestion {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AppIcon(bundleID: s.chat.bundleID, size: 40).modifier(Halo(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NEW \(s.chat.appName.uppercased()) CHAT")
                            .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(Palette.ready)
                        Text(s.chat.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(s.targetTitle.map { "Looks like part of \"\($0)\"" } ?? "Looks like something new")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    if let t = s.target, let title = s.targetTitle {
                        Button("Add to \(title)") { model.acceptSuggestion(into: t) }
                            .buttonStyle(PillButton(fill: Palette.ready, text: .black))
                            .lineLimit(1)
                        Button("New task") { model.acceptSuggestion(into: nil) }
                            .buttonStyle(PillButton(fill: .white.opacity(0.1), text: .white))
                    } else {
                        Button("New task") { model.acceptSuggestion(into: nil) }
                            .buttonStyle(PillButton(fill: Palette.ready, text: .black))
                    }
                    let others = model.topRows.filter { $0.id != s.target }
                    if !others.isEmpty {
                        Menu("Add to…") {
                            ForEach(others) { t in Button(t.title) { model.acceptSuggestion(into: t.id) } }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()
                    Button("Ignore") { model.ignoreSuggestion() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
        }
    }
}
