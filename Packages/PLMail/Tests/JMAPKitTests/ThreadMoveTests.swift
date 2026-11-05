import Foundation
import Testing

@testable import JMAPKit

@Suite("Thread/set moveTo")
struct ThreadMoveTests {
    private func patchJSON(_ patch: ThreadSet.Patch) throws -> [String: Any] {
        let data = try JSONEncoder().encode(patch)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a move names the target and the view, and nothing else")
    func moveEncodes() throws {
        let json = try patchJSON(.move(to: MailboxID("17"), from: MailboxID("42")))

        #expect(Set(json.keys) == ["moveTo"])

        let move = try #require(json["moveTo"] as? [String: Any])
        #expect(move["mailboxId"] as? String == "17")
        #expect(move["fromMailboxId"] as? String == "42")
    }

    @Test("a list with no mailbox of its own sends an explicit null view")
    func moveFromNowhere() throws {
        let json = try patchJSON(.move(to: MailboxID("17"), from: nil))
        let move = try #require(json["moveTo"] as? [String: Any])

        #expect(move["fromMailboxId"] is NSNull)
    }

    @Test("a move never says anything about the snooze or the New marker")
    func moveLeavesSnoozeAlone() throws {
        let json = try patchJSON(.move(to: MailboxID("17"), from: nil))

        #expect(json["snoozedUntil"] == nil)
        #expect(json["isNew"] == nil)
    }

    @Test("an inbox-tab move sends only the tab key")
    func inboxTabEncodes() throws {
        let json = try patchJSON(.inboxTab("c3"))

        #expect(Set(json.keys) == ["inboxTab"])
        #expect(json["inboxTab"] as? String == "c3")
    }

    @Test("an older server's refusal of moveTo is recognised, and no other refusal is")
    func refusalDetection() {
        let old = JSONValue.object([
            "type": .string("invalidProperties"),
            "properties": .array([.string("moveTo")]),
        ])
        let otherProperty = JSONValue.object([
            "type": .string("invalidProperties"),
            "properties": .array([.string("snoozedUntil")]),
        ])
        let forbidden = JSONValue.object(["type": .string("forbidden")])

        #expect(ThreadSet.refusesMoveTo(old))
        #expect(ThreadSet.refusesMoveTo(otherProperty) == false)
        #expect(ThreadSet.refusesMoveTo(forbidden) == false)
    }

    @Test("a bulk move carries one patch per conversation")
    func bulkMove() throws {
        let call = ThreadSet.move(
            [ThreadID("1"), ThreadID("2")], to: MailboxID("9"), from: MailboxID("3"),
            accountID: AccountID("7"))

        #expect(call.arguments.update.count == 2)
    }
}

@Suite("Move fallback")
struct MoveFallbackTests {
    @Test("the fallback attaches the target and detaches the view in one patch")
    func fallbackPatch() throws {
        var builder = RequestBuilder()
        builder.add(
            EmailSet.moveFallback(
                ids: [EmailID("5")], to: MailboxID("17"), leaving: MailboxID("1"),
                accountID: AccountID("7")))
        let body = String(decoding: try builder.encoded(), as: UTF8.self)

        #expect(body.contains("\"mailboxIds/17\":true"))
        #expect(body.contains("\"mailboxIds/1\":null"))
    }
}

@Suite("Reply identity and attachments")
struct ReplyIdentityTests {
    @Test("replyFrom decodes as a whole identity, and its absence is nil")
    func replyFromDecodes() throws {
        let json = """
            {"id": "42", "replyFrom": {"id": "addr-eW9Ac2hvcC5leGFtcGxl", "name": "John Smith",
             "email": "yo@shop.example", "replyTo": null, "bcc": null, "textSignature": "",
             "htmlSignature": "", "mayDelete": false}}
            """
        let email = try JSONDecoder().decode(Email.self, from: Data(json.utf8))
        let bare = try JSONDecoder().decode(Email.self, from: Data(#"{"id": "43"}"#.utf8))

        #expect(email.replyFrom?.email == "yo@shop.example")
        #expect(bare.replyFrom == nil)
    }

    @Test("the compose fetch asks for replyFrom by name, and the reader's does not")
    func composeAsksForReplyFrom() {
        #expect(EmailGet.composeSourceProperties.contains("replyFrom"))
        #expect(EmailGet.readerProperties.contains("replyFrom") == false)
    }

    @Test("a part marked attachment stays an attachment even with a Content-ID")
    func dispositionDecides() {
        var invoice = BodyPart()
        invoice.disposition = "attachment"
        invoice.cid = "invoice@acct"

        var bare = BodyPart()
        bare.cid = "logo@x"

        var inline = BodyPart()
        inline.disposition = "INLINE"

        #expect(invoice.isInline == false)
        #expect(bare.isInline)
        #expect(inline.isInline)
    }
}
