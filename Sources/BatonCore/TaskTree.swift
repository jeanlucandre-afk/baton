import Foundation

/// Big tasks: a task can sit under a big task (`parentID`); a big task (`isGroup`) has no chat or
/// windows of its own. Pure functions over the task list, so the app and the tests share them.
public enum TaskTree {
    /// Puts `id` under the same big task as `target`. A task on its own becomes a big task first, named
    /// after it, holding both. Moving a big task merges its subtasks into the target's.
    public static func group(_ tasks: inout [BatonTask], _ id: UUID, with target: UUID) {
        guard id != target, let ti = tasks.firstIndex(where: { $0.id == target }),
              tasks.contains(where: { $0.id == id }) else { return }
        let groupID: UUID
        if tasks[ti].isGroup {
            groupID = target
        } else if let p = tasks[ti].parentID, tasks.contains(where: { $0.id == p }) {
            groupID = p
        } else {
            var g = BatonTask(title: tasks[ti].title, windows: [])
            g.isGroup = true
            g.createdAt = tasks[ti].createdAt
            tasks.insert(g, at: ti)
            tasks[ti + 1].parentID = g.id
            groupID = g.id
        }
        guard id != groupID else { return }
        if tasks.first(where: { $0.id == id })?.isGroup == true {
            for i in tasks.indices where tasks[i].parentID == id { tasks[i].parentID = groupID }
            tasks.removeAll { $0.id == id }
        } else if let i = tasks.firstIndex(where: { $0.id == id }) {
            let old = tasks[i].parentID
            tasks[i].parentID = groupID
            removeEmptyGroup(&tasks, old)
        }
    }

    /// Takes a subtask out of its big task; a big task left empty goes away.
    public static func ungroup(_ tasks: inout [BatonTask], _ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), let old = tasks[i].parentID else { return }
        tasks[i].parentID = nil
        removeEmptyGroup(&tasks, old)
    }

    /// Turns a task on its own into a big task holding just it, named after it, in its place.
    /// Returns the big task's id: the new one, or the one the task already sits in (or is).
    @discardableResult
    public static func makeGroup(_ tasks: inout [BatonTask], from id: UUID) -> UUID? {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        if tasks[i].isGroup { return id }
        if let p = tasks[i].parentID, tasks.contains(where: { $0.id == p && $0.isGroup }) { return p }
        var g = BatonTask(title: tasks[i].title, windows: [])
        g.isGroup = true
        g.createdAt = tasks[i].createdAt
        tasks.insert(g, at: i)
        tasks[i + 1].parentID = g.id
        return g.id
    }

    /// Puts a task under a big task (from "Move to"); the big task it left goes away if that left it empty.
    /// Big tasks and missing targets are left alone: to merge big tasks, use `group`.
    public static func move(_ tasks: inout [BatonTask], _ id: UUID, under groupID: UUID) {
        guard id != groupID, tasks.contains(where: { $0.id == groupID && $0.isGroup }),
              let i = tasks.firstIndex(where: { $0.id == id }), !tasks[i].isGroup,
              tasks[i].parentID != groupID else { return }
        let old = tasks[i].parentID
        tasks[i].parentID = groupID
        removeEmptyGroup(&tasks, old)
    }

    /// Adds a new task to the list, under `groupID` when that's a big task, else on its own.
    public static func add(_ tasks: inout [BatonTask], _ task: BatonTask, under groupID: UUID?) {
        var t = task
        t.parentID = groupID.flatMap { g in tasks.contains(where: { $0.id == g && $0.isGroup }) ? g : nil }
        tasks.append(t)
    }

    /// Takes every task out of a big task and lets the big task go; the tasks stay, on their own.
    public static func ungroupAll(_ tasks: inout [BatonTask], _ groupID: UUID) {
        guard tasks.contains(where: { $0.id == groupID && $0.isGroup }) else { return }
        for i in tasks.indices where tasks[i].parentID == groupID { tasks[i].parentID = nil }
        tasks.removeAll { $0.id == groupID }
    }

    public static func removeEmptyGroup(_ tasks: inout [BatonTask], _ id: UUID?) {
        guard let id, tasks.contains(where: { $0.id == id && $0.isGroup }),
              !tasks.contains(where: { $0.parentID == id }) else { return }
        tasks.removeAll { $0.id == id }
    }
}
