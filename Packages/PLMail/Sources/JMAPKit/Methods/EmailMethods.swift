/// `Email/query` — select and order ids. Returns ids only; nothing is
/// hydrated, which is why it pairs with ``EmailGet`` through a back-reference.
public struct EmailQuery: JMAPMethod {
    public static let name = "Email/query"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var filter: EmailFilter?
        public var sort: [EmailComparator]?
        public var collapseThreads: Bool?

        /// **Always 0 in this client.** `EmailQueryRunner` has no SQL `LIMIT`:
        /// it materialises every matching row in PHP and slices, so
        /// `position: 5000` costs exactly what `position: 0` costs — the whole
        /// mailbox, on someone's NAS. And `position` is unstable under
        /// concurrent insertion, which produces duplicates and gaps across
        /// pages. Page with ``EmailFilter/before(_:)`` instead.
        public var position: Int?

        /// Capped at 500 server-side; null or larger becomes 500.
        public var limit: Int?

        public var calculateTotal: Bool?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case filter, sort, collapseThreads, position, limit, calculateTotal
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var queryState: StateToken
        /// Always false — plMail implements no `Email/queryChanges`, so a list
        /// is refreshed by re-running the query.
        public var canCalculateChanges: Bool
        public var position: Int
        public var ids: [EmailID]
        /// `Email/query` always returns this, unlike `Mailbox/query`.
        public var total: Int?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case queryState, canCalculateChanges, position, ids, total
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID,
        filter: EmailFilter? = nil,
        sort: [EmailComparator]? = [.newestFirst],
        collapseThreads: Bool? = nil,
        limit: Int? = nil,
        calculateTotal: Bool? = nil
    ) {
        arguments = Arguments(
            accountID: accountID,
            filter: filter,
            sort: sort,
            collapseThreads: collapseThreads,
            position: 0,
            limit: limit,
            calculateTotal: calculateTotal
        )
    }
}

/// `Email/get`.
///
/// `ids` is required — an account's mail is unbounded, so a null means
/// `requestTooLarge` rather than "everything". Reach Emails through
/// ``EmailQuery``.
public struct EmailGet: JMAPMethod {
    public static let name = "Email/get"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var ids: Argument<[EmailID]>
        public var properties: [String]?
        public var bodyProperties: [String]?
        public var fetchTextBodyValues: Bool?
        public var fetchHTMLBodyValues: Bool?
        public var fetchAllBodyValues: Bool?
        public var maxBodyValueBytes: Int?

        /// Written out by hand because ``ids`` may encode as `ids` or as
        /// `#ids`, and the synthesised encoder cannot vary a key.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: JMAPCodingKey.self)
            try container.encode(accountID, forKey: JMAPCodingKey("accountId"))
            try ids.encode(into: &container, as: "ids")
            try container.encodeIfPresent(properties, forKey: JMAPCodingKey("properties"))
            try container.encodeIfPresent(bodyProperties, forKey: JMAPCodingKey("bodyProperties"))
            try container.encodeIfPresent(
                fetchTextBodyValues, forKey: JMAPCodingKey("fetchTextBodyValues"))
            // Capitalised exactly as RFC 8621 spells it. `fetchHtmlBodyValues`
            // is simply an unrecognised argument: bodies come back empty with
            // no error at all.
            try container.encodeIfPresent(
                fetchHTMLBodyValues, forKey: JMAPCodingKey("fetchHTMLBodyValues"))
            try container.encodeIfPresent(
                fetchAllBodyValues, forKey: JMAPCodingKey("fetchAllBodyValues"))
            try container.encodeIfPresent(
                maxBodyValueBytes, forKey: JMAPCodingKey("maxBodyValueBytes"))
        }
    }

    public typealias Result = GetResult<Email>

    public var arguments: Arguments

    public init(
        accountID: AccountID,
        ids: Argument<[EmailID]>,
        properties: [String]? = nil,
        bodyProperties: [String]? = nil,
        fetchTextBodyValues: Bool? = nil,
        fetchHTMLBodyValues: Bool? = nil,
        maxBodyValueBytes: Int? = nil
    ) {
        arguments = Arguments(
            accountID: accountID,
            ids: ids,
            properties: properties,
            bodyProperties: bodyProperties,
            fetchTextBodyValues: fetchTextBodyValues,
            fetchHTMLBodyValues: fetchHTMLBodyValues,
            fetchAllBodyValues: nil,
            maxBodyValueBytes: maxBodyValueBytes
        )
    }
}

extension EmailGet {
    /// Enough to draw a list row, and no more — bodies are fetched only when a
    /// thread is opened, so that list sync never faults a 400KB HTML string
    /// into memory.
    public static let listRowProperties = [
        "id", "threadId", "mailboxIds", "keywords", "receivedAt", "sentAt",
        "subject", "from", "to", "preview", "hasAttachment", "size",
    ]

    /// Everything needed to render one message in a thread.
    public static let readerProperties = [
        "id", "blobId", "threadId", "mailboxIds", "keywords", "receivedAt", "sentAt",
        "subject", "from", "to", "cc", "bcc", "messageId", "inReplyTo", "references",
        "hasAttachment", "size", "textBody", "htmlBody", "attachments", "bodyValues",
    ]

    /// The reader's set plus who answers it, for the one fetch a reply, a
    /// forward or a reopened draft is built from. `replyFrom` is never in a
    /// get without `properties`, and asking on every list row would carry a
    /// signature per message for nothing.
    public static let composeSourceProperties = readerProperties + ["replyTo", "replyFrom"]
}

/// `Email/changes` — the object-level delta.
public struct EmailChanges: JMAPMethod {
    public static let name = "Email/changes"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var sinceState: StateToken
        /// Both the default and the ceiling are 256; a value below 1 is
        /// silently treated as 256.
        public var maxChanges: Int?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case sinceState, maxChanges
        }
    }

    public typealias Result = ChangesResult<EmailID>

    public var arguments: Arguments

    public init(accountID: AccountID, sinceState: StateToken, maxChanges: Int? = nil) {
        arguments = Arguments(
            accountID: accountID, sinceState: sinceState, maxChanges: maxChanges)
    }
}

/// `Email/set`, restricted to the one write this client makes.
///
/// v1 is otherwise read-only, but reading a thread has to mark it read: a
/// client that silently disagreed with the web UI about read state on every
/// device would be worse than one that writes. The patch goes through the same
/// propagator the web UI uses, so it reaches Gmail/IMAP/Graph identically.
///
/// The remaining `Email/set` surface — mailbox changes, `destroy` (which is a
/// move to Trash, never a row delete) — arrives with the write phase.
public struct EmailSetKeywords: JMAPMethod {
    public static let name = "Email/set"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Patch objects keyed by email id, e.g. `{"7": {"keywords/$seen": true}}`.
        public var update: [EmailID: [String: Bool]]
        /// Conflict detection on batch mutations; honoured by the server.
        public var ifInState: StateToken?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case update, ifInState
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var oldState: StateToken?
        public var newState: StateToken
        public var updated: [EmailID: JSONValue]?
        public var notUpdated: [EmailID: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case oldState, newState, updated, notUpdated
        }
    }

    public var arguments: Arguments

    /// Marks emails read or unread.
    public init(accountID: AccountID, ids: [EmailID], isSeen: Bool, ifInState: StateToken? = nil) {
        let patch = ["keywords/\(Keyword.seen.rawValue)": isSeen]

        arguments = Arguments(
            accountID: accountID,
            update: Dictionary(uniqueKeysWithValues: ids.map { ($0, patch) }),
            ifInState: ifInState
        )
    }
}
