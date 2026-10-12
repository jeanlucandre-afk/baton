import Foundation

/// Chats continued with /handoff: the new chat is named after its project and part ("Baton · Part 6 —
/// screen test"), one part after the chat it continues. Its task moves on to the new chat.
public enum Handoff {
    /// "Baton · Part 6 — screen test" → ("baton", 6). Nil for chats not named that way.
    public static func parse(_ name: String) -> (project: String, part: Int)? {
        guard let r = name.range(of: #"^(.+?)\s+·\s+Part\s+(\d+)\b"#, options: .regularExpression) else { return nil }
        let head = name[r]
        guard let dot = head.range(of: "·", options: .backwards),
              let part = Int(head[dot.upperBound...].replacingOccurrences(of: "Part", with: "").trimmingCharacters(in: .whitespaces))
        else { return nil }
        let project = head[..<dot.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
        return project.isEmpty ? nil : (project, part)
    }

    /// When `chat` continues a chat a task follows (same app and project, an earlier part, the latest
    /// such), that task moves on to it:
    /// - its chat becomes the new one, and a title that was just the old chat's name becomes the new name;
    /// - if a task already follows the new chat, that task takes the old one's place (its big task) and
    ///   the old task goes.
    /// Returns the old chat's name when something changed.
    @discardableResult
    public static func follow(_ tasks: inout [BatonTask], newChat chat: ChatRecord) -> String? {
        guard let (project, part) = parse(chat.name) else { return nil }
        let older = tasks.indices.compactMap { i -> (Int, Int)? in
            guard !tasks[i].isGroup, let c = tasks[i].chat, c.bundleID == chat.bundleID,
                  let p = parse(c.name), p.project == project, p.part < part else { return nil }
            return (i, p.part)
        }
        guard let oi = older.max(by: { $0.1 < $1.1 })?.0, let oldName = tasks[oi].chat?.name else { return nil }

        if let ni = tasks.firstIndex(where: { !$0.isGroup && $0.chat?.bundleID == chat.bundleID && $0.chat?.name == chat.name }) {
            if tasks[ni].parentID == nil { tasks[ni].parentID = tasks[oi].parentID }
            tasks.remove(at: oi)
        } else {
            let wasNamedAfterChat = tasks[oi].title.lowercased() == oldName.lowercased()
            tasks[oi].chat = ChatRecord(bundleID: chat.bundleID, appName: chat.appName, name: chat.name,
                                        section: chat.section ?? tasks[oi].chat?.section)
            if wasNamedAfterChat { tasks[oi].title = chat.name }
            tasks[oi].steps = []
            tasks[oi].next = nil
        }
        return oldName
    }
}
