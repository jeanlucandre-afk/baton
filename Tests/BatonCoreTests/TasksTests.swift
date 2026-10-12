import Foundation
import Testing
@testable import BatonCore

@Suite struct TaskFileTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-tasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savesAndLoads() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = TaskFile(directory: dir)
        file.save([BatonTask(title: "One", windows: []), BatonTask(title: "Two", windows: [])])
        #expect(file.load().map(\.title) == ["One", "Two"])
    }

    @Test func oneBadTaskKeepsTheRestAndTheFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = TaskFile(directory: dir)
        // The middle task has no title, which every task needs.
        let json = """
        [{"title": "Keep me", "windows": []},
         {"windows": []},
         {"title": "Me too", "chat": {"bundleID": "com.openai.chat", "appName": "ChatGPT", "name": "Plan"}}]
        """
        try Data(json.utf8).write(to: file.url)
        let tasks = file.load()
        #expect(tasks.map(\.title) == ["Keep me", "Me too"])
        #expect(tasks[1].chat?.name == "Plan")
        let copies = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("tasks.json.bad-") }
        #expect(copies.count == 1)
        let copy = try Data(contentsOf: dir.appendingPathComponent(copies[0]))
        #expect(copy == Data(json.utf8))
    }

    @Test func goodFileLeavesNoCopy() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = TaskFile(directory: dir)
        file.save([BatonTask(title: "Fine", windows: [])])
        _ = file.load()
        let copies = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("tasks.json.bad-") }
        #expect(copies.isEmpty)
    }
}
