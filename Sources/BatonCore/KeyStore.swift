import Foundation
import LocalAuthentication
import Security

/// API keys in the login Keychain, as generic passwords under a service name ("jev-api-key",
/// "gemini-api-key"), the same items the old README's `security add-generic-password` made.
///
/// Every item lives with `/usr/bin/security` on its access list, and secrets only ever go through that
/// tool: it reads and writes those items without a Keychain prompt, while reading or changing them
/// through the Security framework from Baton (not on the list) blocks on one. So the Security framework
/// is used only to ask whether a key is there (attributes, no secret, never any UI), and the secret is
/// handed to the tool on stdin, never on its command line.
public enum KeyStore {
    public static let jev = "jev-api-key"
    public static let gemini = "gemini-api-key"

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case empty
        case badCharacters
        case notSaved
        case notRemoved
        public var description: String {
            switch self {
            case .empty: "The key is empty."
            case .badCharacters: "That doesn't look like an API key: no spaces or quotes."
            case .notSaved: "The Keychain didn't take the key."
            case .notRemoved: "The Keychain didn't remove the key."
            }
        }
    }

    /// Whether a key is saved under `service`. Reads attributes only, and never shows any UI.
    public static func exists(_ service: String) -> Bool {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecUseAuthenticationContext as String: ctx]
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        return s == errSecSuccess || s == errSecInteractionNotAllowed || s == errSecAuthFailed
    }

    /// The key saved under `service`, or nil.
    public static func read(_ service: String) -> String? {
        let r = run(["find-generic-password", "-s", service, "-w"])
        guard r.status == 0 else { return nil }
        let k = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    /// Saves the key under `service`, replacing any key already there. The new key goes in first (updated
    /// in place); only once it reads back are other items under `service` removed. A save that fails
    /// leaves the key that was there.
    public static func save(_ key: String, service: String) throws {
        // `security -i` reads commands from stdin, so the key never shows up in the process list.
        try save(key, service: service, add: { run(["-i"], stdin: $0).status })
    }

    /// `add` runs one `security -i` command line (tests make it fail).
    static func save(_ key: String, service: String, add: (String) -> Int32) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { throw Failure.empty }
        guard isPlain(k), isPlain(service) else { throw Failure.badCharacters }
        let account = isPlain(NSUserName()) ? NSUserName() : "baton"
        _ = add("add-generic-password -U -a \(account) -s \(service) -l \(service) -w \(k)\n")
        guard read(service, account: account) == k else { throw Failure.notSaved }
        // Items under other accounts (one added by hand, say) could be found first and shadow it.
        for a in accounts(service) where a != account {
            if a.isEmpty {
                // A blank account can't be named to the tool, so this removes the first match: if that was the new
                // key, it goes straight back in.
                _ = run(["delete-generic-password", "-s", service])
                if read(service, account: account) != k { _ = add("add-generic-password -U -a \(account) -s \(service) -l \(service) -w \(k)\n") }
            } else {
                _ = run(["delete-generic-password", "-s", service, "-a", a])
            }
        }
        guard read(service) == k else { throw Failure.notSaved }
    }

    /// The key saved under `service` for `account` only.
    static func read(_ service: String, account: String) -> String? {
        let r = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard r.status == 0 else { return nil }
        let k = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    /// The accounts of every item under `service`. Attributes only: no secret, never any UI.
    static func accounts(_ service: String) -> [String] {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecUseAuthenticationContext as String: ctx]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.map { $0[kSecAttrAccount as String] as? String ?? "" }
    }

    /// Removes every key under `service`. Removing a key that isn't there is fine.
    public static func remove(_ service: String) throws {
        for _ in 0..<5 where read(service) != nil || exists(service) {
            guard run(["delete-generic-password", "-s", service]).status == 0 else { throw Failure.notRemoved }
        }
    }

    /// Safe to pass through `security -i`'s command parser unquoted.
    static func isPlain(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 && !"\"'\\".unicodeScalars.contains($0) }
    }

    private static func run(_ args: [String], stdin: String? = nil) -> (status: Int32, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let input = stdin.map { _ in Pipe() }
        if let input { p.standardInput = input }
        do { try p.run() } catch { return (-1, Data()) }
        if let input, let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }
}
