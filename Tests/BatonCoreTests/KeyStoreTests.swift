import Foundation
import Testing
@testable import BatonCore

/// Uses throwaway service names and removes them afterwards; never touches the real keys.
@Suite(.serialized) struct KeyStoreTests {
    private func service() -> String { "dev.baton.test.keystore.\(UUID().uuidString)" }

    @Test func savesReadsReplacesAndRemoves() throws {
        let s = service()
        defer { try? KeyStore.remove(s) }
        #expect(KeyStore.read(s) == nil)
        #expect(!KeyStore.exists(s))
        try KeyStore.save("  first-value \n", service: s)
        #expect(KeyStore.read(s) == "first-value")
        #expect(KeyStore.exists(s))
        try KeyStore.save("second-value", service: s)
        #expect(KeyStore.read(s) == "second-value")
        try KeyStore.remove(s)
        #expect(KeyStore.read(s) == nil)
        try KeyStore.remove(s)  // removing twice is fine
    }

    /// Anything `isPlain` lets through must come back exactly: `security -i` parses the line itself.
    @Test func punctuationSurvivesTheToolsParser() throws {
        let s = service()
        defer { try? KeyStore.remove(s) }
        for k in ["ab#c;d$e&f|g*h", "-starts-with-dash", "x=y+z/w~v!u%t^s(r)q[p]o{n}m<l>k,j`i?h@g"] where KeyStore.isPlain(k) {
            try KeyStore.save(k, service: s)
            #expect(KeyStore.read(s) == k)
        }
    }

    /// The new key goes in before anything is removed: a save that fails keeps the working key.
    @Test func aFailedSaveKeepsTheOldKey() throws {
        let s = service()
        defer { try? KeyStore.remove(s) }
        try KeyStore.save("working-key", service: s)
        #expect(throws: KeyStore.Failure.notSaved) { try KeyStore.save("new-key", service: s, add: { _ in 1 }) }
        #expect(KeyStore.read(s) == "working-key")
    }

    private func addWithTool(_ s: String, account: String, _ value: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["add-generic-password", "-a", account, "-s", s, "-w", value]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    /// Keys under another account (or a blank one) could be found first: a save replaces them, leaving one item.
    @Test(arguments: ["someone-else", ""])
    func aSaveReplacesKeysUnderOtherAccounts(account: String) throws {
        let s = service()
        defer { try? KeyStore.remove(s) }
        try addWithTool(s, account: account, "tool-value")
        try KeyStore.save("app-value", service: s)
        #expect(KeyStore.read(s) == "app-value")
        #expect(KeyStore.accounts(s).count == 1)
    }

    @Test func rejectsAnEmptyKey() {
        #expect(throws: KeyStore.Failure.empty) { try KeyStore.save("   ", service: service()) }
        #expect(throws: KeyStore.Failure.badCharacters) { try KeyStore.save("two words", service: service()) }
        #expect(KeyStore.isPlain("AIzaSy-abc_123.~+/="))
        #expect(!KeyStore.isPlain("a\"b"))
    }

    /// Keys from the old README were added with the `security` tool; they must keep working.
    @Test func readsAndReplacesAKeyAddedByTheSecurityTool() throws {
        let s = service()
        defer { try? KeyStore.remove(s) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["add-generic-password", "-a", NSUserName(), "-s", s, "-w", "tool-value"]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(KeyStore.exists(s))
        #expect(KeyStore.read(s) == "tool-value")
        try KeyStore.save("app-value", service: s)
        #expect(KeyStore.read(s) == "app-value")
        try KeyStore.remove(s)
        #expect(KeyStore.read(s) == nil)
    }
}
