/// An RFC 8621 `Email`, as plMail publishes it.
///
/// Every property is optional because `Email/get` honours a `properties`
/// filter and returns only what was asked for — a partial Email is the normal
/// case, not an error. `id` is the exception: the server returns it regardless
/// of the requested property set.
public struct Email: Hashable, Sendable, Codable {
    public var id: EmailID
    public var blobID: BlobID?
    public var threadID: ThreadID?

    /// Which mailboxes this message is in, in the **Mailbox (binding)** id
    /// space — the same ids `inMailbox` and `Email/set` take.
    ///
    /// Derived from the per-message label join, not the thread-level union:
    /// the latter would report a mailbox for every message in the thread.
    public var mailboxIDs: JMAPIDSet<MailboxID>?

    public var keywords: KeywordSet?
    public var size: Int?

    /// When the message arrived. The server falls back through
    /// `receivedAt ?? sentAt ?? createdAt`, so in practice it is always
    /// present — but it is typed nullable, and any sort must order nils last
    /// rather than assume.
    public var receivedAt: UTCDate?
    public var sentAt: UTCDate?

    /// Header ids with the angle brackets already stripped.
    public var messageID: [String]?
    public var inReplyTo: [String]?
    public var references: [String]?

    public var subject: String?

    /// Address lists are `null` rather than `[]` when empty — the mapper
    /// returns nil for an empty list, so an absent `to` is normal.
    public var from: [EmailAddress]?
    public var sender: [EmailAddress]?
    public var to: [EmailAddress]?
    public var cc: [EmailAddress]?
    public var bcc: [EmailAddress]?
    public var replyTo: [EmailAddress]?

    public var hasAttachment: Bool?

    /// Plain text, whitespace-collapsed, capped at 256 characters.
    public var preview: String?

    public var textBody: [BodyPart]?
    public var htmlBody: [BodyPart]?
    public var attachments: [BodyPart]?

    /// Keyed by `partId`. Only populated when the request asked for it.
    public var bodyValues: [String: BodyValue]?

    /// Which identity answers this message — a **plMail extension**, and only
    /// returned when asked for by name, because it carries a signature.
    ///
    /// The address the mail was sent to: an alias's identity, or one for an
    /// address at a catch-all domain that `Identity/get` never lists. On a
    /// draft, the identity it is written from. Nil, or absent on an older
    /// server, means "open on the primary identity".
    public var replyFrom: Identity?

    public init(id: EmailID) {
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case blobID = "blobId"
        case threadID = "threadId"
        case mailboxIDs = "mailboxIds"
        case keywords, size, receivedAt, sentAt
        case messageID = "messageId"
        case inReplyTo, references, subject
        case from, sender, to, cc, bcc, replyTo
        case hasAttachment, preview, textBody, htmlBody, attachments, bodyValues
        case replyFrom
    }
}

extension Email {
    /// The `partId` of the two synthetic body parts plMail publishes.
    ///
    /// plMail stores a flattened body (`bodyText` / `bodyHtmlSafe`) rather than
    /// a MIME tree, so every Email has at most these two parts and they are
    /// stable per message. The spec still says to treat `partId` as opaque, so
    /// these are for reading `bodyValues` after a fetch, not for constructing
    /// requests.
    public enum SyntheticPart {
        public static let text = "text"
        public static let html = "html"
    }

    /// The HTML body, if it was fetched.
    ///
    /// Always the server's sanitised version — the raw column is never
    /// published. Render it on a permanently light background regardless of
    /// the app's theme: mail is authored for white, and a dark surface gives
    /// black text on black.
    public var htmlBodyValue: String? {
        bodyValues?[SyntheticPart.html]?.value
    }

    public var textBodyValue: String? {
        bodyValues?[SyntheticPart.text]?.value
    }
}

/// An RFC 8621 `EmailBodyPart`.
public struct BodyPart: Hashable, Sendable, Codable {
    public var partID: String?
    public var blobID: BlobID?
    public var size: Int?
    public var type: String?
    public var charset: String?
    public var disposition: String?
    public var cid: String?
    public var name: String?

    public init() {}

    /// Inline parts have no filename and are referenced from the HTML body by
    /// `cid:`. They must be served into the renderer from a local cache rather
    /// than by handing the download URL to a web view.
    ///
    /// **The disposition decides when there is one.** A part marked
    /// `attachment` that also carries a Content-ID — an invoice PDF from an
    /// accounting package, a forwarded file — is an attachment; counting it as
    /// inline hid every attachment such a message had. Only a part with no
    /// disposition falls back to the `cid`.
    public var isInline: Bool {
        if let disposition { return disposition.lowercased() == "inline" }

        return cid != nil
    }

    private enum CodingKeys: String, CodingKey {
        case partID = "partId"
        case blobID = "blobId"
        case size, type, charset, disposition, cid, name
    }
}

/// An RFC 8621 `EmailBodyValue`.
public struct BodyValue: Hashable, Sendable, Codable {
    public var value: String
    public var isEncodingProblem: Bool?
    public var isTruncated: Bool?

    public init(value: String, isEncodingProblem: Bool? = nil, isTruncated: Bool? = nil) {
        self.value = value
        self.isEncodingProblem = isEncodingProblem
        self.isTruncated = isTruncated
    }
}
