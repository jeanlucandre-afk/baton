import Foundation

/// What Baton keeps in Application Support outlives the build that wrote it: a newer or older format, a
/// file cut short by a crash or a full disk. One that doesn't read starts over empty, and the next save
/// would write over it, so it's moved aside first, never lost without a trace.
public enum SavedFile {
    /// Reads and decodes `url`. Missing: nil. There but unreadable: moved to `<name>.bad-<time>`, then nil.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        if let v = try? JSONDecoder().decode(T.self, from: d) { return v }
        setAside(url)
        return nil
    }

    /// Moves a file that doesn't read out of the way (moved, not copied: the next launch then starts clean
    /// instead of making another copy).
    public static func setAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let bad = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).bad-\(stamp)")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
    }
}

/// Decodes an array element by element, dropping the ones that don't read instead of failing the whole
/// array (one record from a newer build mustn't cost every other).
struct LenientArray<T: Decodable>: Decodable {
    let items: [T]
    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if (try? c.decodeNil()) == true { continue }
            if let v = try? c.decode(T.self) { out.append(v); continue }
            // A failed decode doesn't move on: step past it, and stop rather than spin if even that fails.
            guard (try? c.decode(Skip.self)) != nil else { break }
        }
        items = out
    }

    /// Consumes one element of any shape.
    private struct Skip: Decodable { init(from decoder: any Decoder) throws {} }
}
