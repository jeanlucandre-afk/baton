import Foundation
import Testing
@testable import BatonCore

@Suite struct ComposerTests {
    @Test func readsContextPercent() {
        #expect(Composer.contextPercent("Usage: Context 552.7k / 1M (55%), 29% of session limit, Resets in 3 hr 54 min") == 55)
        #expect(Composer.contextPercent("Usage: Context 12k / 200k (6%)") == 6)
        #expect(Composer.contextPercent("29% of session limit") == nil)
    }

    @Test func findsTheHandoffFileInAReply() {
        let reply = """
        Saved earlier: docs/handoffs/2026-10-08-0624-baton-chat-tracking-design-pass.md
        Handoff saved to /Users/me/Developer/Baton/docs/handoffs/2026-10-08-1945-continue-in-new-chat.md and added to docs/handoffs/INDEX.md.
        In a new chat say: /handoff resume
        """
        #expect(Composer.handoffName(in: reply) == "2026-10-08-1945-continue-in-new-chat")
        // A link split into pieces, or a file named without its folder.
        #expect(Composer.handoffName(in: "File: docs/handoffs/ 2026-10-08-2301-baton-test-chat.md") == "2026-10-08-2301-baton-test-chat")
        #expect(Composer.handoffName(in: "Ran 3 commands, created 2026-10-08-2301-baton-test-chat.md, used 2 tools") == "2026-10-08-2301-baton-test-chat")
        // Names already in the chat before /handoff ran don't count.
        #expect(Composer.handoffName(in: "only docs/handoffs/2026-10-08-0624-old.md", excluding: ["2026-10-08-0624-old"]) == nil)
        #expect(Composer.handoffName(in: "see docs/handoffs/INDEX.md") == nil)
    }

    @Test func findsBoxSendAndTheChatsNewSessionButton() {
        let root = AXNode(role: "AXWindow", kids: [
            AXNode(role: "AXGroup", kids: [
                AXNode(role: "AXGroup", desc: "baton", kids: [
                    AXNode(role: "AXButton", desc: "New session in baton"),
                    AXNode(role: "AXButton", title: "Running NEW FEATURES")
                ]),
                AXNode(role: "AXGroup", desc: "Other", kids: [
                    AXNode(role: "AXButton", desc: "New session in Other"),
                    AXNode(role: "AXButton", title: "Idle Acme project audit")
                ])
            ]),
            AXNode(role: "AXGroup", kids: [
                AXNode(role: "AXTextArea", desc: "Prompt", value: ""),
                AXNode(role: "AXButton", desc: "Send"),
                AXNode(role: "AXPopUpButton", desc: "Usage: Context 552.7k / 1M (72%), 29% of session limit")
            ])
        ])
        let c = Composer.find(in: root)
        #expect(c?.text == "")
        #expect(c?.send?.desc == "Send")
        #expect(Composer.newChatButton(near: "NEW FEATURES", in: root)?.desc == "New session in baton")
        #expect(Composer.newChatButton(near: "Acme project audit", in: root)?.desc == "New session in Other")
        #expect(Composer.contextPercent(in: root) == 72)
    }
}
