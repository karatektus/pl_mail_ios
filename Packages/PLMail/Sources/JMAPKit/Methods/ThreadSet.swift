/// `Thread/set` — a **plMail extension**, not RFC 8621.
///
/// The spec's Thread is read-only, because a thread is derived from its Emails
/// and has no state of its own. plMail's has two pieces. A snooze, which lives
/// on the thread rather than on any message — the web UI already reads and
/// writes it, and a client that kept snooze locally instead would silently
/// disagree with the browser and lose it on reinstall. And the New marker,
/// which is settable only to `false` and records that a conversation has been
/// put in front of the user.
///
/// **Reporting displays is not politeness, it is the feature.** Only a client
/// that draws a row can retire that row's marker, so an app that shows the
/// badge and never reports back leaves the web UI and Android permanently
/// badging mail the user has already seen.
///
/// Only `update`: the server refuses `create` and `destroy` outright, since
/// threads come into being by mail arriving.
public struct ThreadSet: JMAPMethod {
    public static let name = "Thread/set"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Patch objects keyed by thread id. A `nil` value inside one clears
        /// the snooze — the same convention the rest of the API uses for
        /// removal.
        public var update: [ThreadID: Patch]

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case update
        }
    }

    public struct Patch: Encodable, Sendable {
        public var snoozedUntil: UTCDate?

        /// Whether this patch has anything to say about the snooze at all.
        ///
        /// **The distinction that keeps a list from waking every snoozed
        /// conversation it draws.** `snoozedUntil` alone cannot tell "clear the
        /// snooze" from "this patch is not about snoozing": both are nil. The
        /// display-reporting path sends a patch for every row on screen, and
        /// with the two collapsed each of those rows would carry an explicit
        /// `snoozedUntil: null` and pull the conversation back into the Inbox.
        private let mentionsSnooze: Bool

        /// Retires the New marker, and only ever to `false`.
        ///
        /// The server refuses `true` with `invalidProperties`: the column
        /// records *when* a row was displayed, so un-retiring would write null
        /// over a fact and let a client keep its own badges alive forever. Nil
        /// here means the patch says nothing about it.
        public var isNew: Bool?

        /// "Move to": file the conversation at `mailboxId` and take it out of
        /// the list the user was in. **An instruction, not a property** — the
        /// server's `MoveToService` decides what comes off, which differs by
        /// provider (leaving the Inbox for a tag is an archive on plain IMAP,
        /// leaving the bin is a restore). Rebuilding it from `Email/set` files
        /// mail in two places; Android did that for one release.
        public var moveTo: MoveTo?

        /// Moves the conversation into an inbox tab, pinned, as a drag on the
        /// web does. A key the user does not have is refused with
        /// `invalidProperties`.
        public var inboxTab: String?

        /// Hand-rolled so a mentioned-but-nil snooze encodes as an explicit
        /// `null` — which is how the API spells "clear it" — while a patch that
        /// is not about snoozing omits the key entirely. Omitting it means
        /// "change nothing", and the two must not be confused.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            if mentionsSnooze { try container.encode(snoozedUntil, forKey: .snoozedUntil) }
            if let isNew { try container.encode(isNew, forKey: .isNew) }
            if let moveTo { try container.encode(moveTo, forKey: .moveTo) }
            if let inboxTab { try container.encode(inboxTab, forKey: .inboxTab) }
        }

        private enum CodingKeys: String, CodingKey {
            case snoozedUntil
            case isNew
            case moveTo
            case inboxTab
        }

        /// Where a move goes, and which list it leaves.
        public struct MoveTo: Encodable, Hashable, Sendable {
            public var mailboxID: MailboxID
            /// The mailbox the list on screen shows, or nil for a list with
            /// none of its own — a search, Starred, a category tab.
            ///
            /// **Encoded as an explicit `null`** rather than omitted, so the
            /// wire says "no view" in so many words. The two are equivalent to
            /// the server today; a missing key is the one that could change.
            public var fromMailboxID: MailboxID?

            public init(mailboxID: MailboxID, fromMailboxID: MailboxID?) {
                self.mailboxID = mailboxID
                self.fromMailboxID = fromMailboxID
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(mailboxID, forKey: .mailboxID)
                try container.encode(fromMailboxID, forKey: .fromMailboxID)
            }

            private enum CodingKeys: String, CodingKey {
                case mailboxID = "mailboxId"
                case fromMailboxID = "fromMailboxId"
            }
        }

        public init(snoozedUntil: UTCDate?) {
            self.snoozedUntil = snoozedUntil
            mentionsSnooze = true
            isNew = nil
        }

        private init(isNew: Bool?, moveTo: MoveTo? = nil, inboxTab: String? = nil) {
            snoozedUntil = nil
            mentionsSnooze = false
            self.isNew = isNew
            self.moveTo = moveTo
            self.inboxTab = inboxTab
        }

        /// A move to `mailbox`, out of the list showing `from`.
        public static func move(to mailbox: MailboxID, from: MailboxID?) -> Patch {
            Patch(isNew: nil, moveTo: MoveTo(mailboxID: mailbox, fromMailboxID: from))
        }

        /// A move into the inbox tab keyed `key`.
        public static func inboxTab(_ key: String) -> Patch {
            Patch(isNew: nil, inboxTab: key)
        }

        /// Records that this conversation has been put in front of the user.
        ///
        /// Idempotent server-side — `markListed()` carries its own
        /// `listedAt IS NULL` guard — so a repeat does not move the timestamp
        /// and the record keeps saying when the row was *first* shown. The
        /// server guide is explicit that it may safely be sent for every row on
        /// every draw; batching it here is about the home server's uplink, not
        /// about correctness.
        public static let shown = Patch(isNew: false)
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var oldState: StateToken?
        public var newState: StateToken
        public var updated: [ThreadID: JSONValue]?
        public var notUpdated: [ThreadID: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case oldState, newState, updated, notUpdated
        }
    }

    public var arguments: Arguments

    public init(accountID: AccountID, update: [ThreadID: Patch]) {
        arguments = Arguments(accountID: accountID, update: update)
    }

    /// Snoozes or wakes one conversation.
    public static func snooze(
        _ threadID: ThreadID, until: UTCDate?, accountID: AccountID
    ) -> ThreadSet {
        ThreadSet(accountID: accountID, update: [threadID: Patch(snoozedUntil: until)])
    }

    /// Moves conversations to `mailbox`, out of the list showing `from`.
    ///
    /// **Undo is the same call with the two swapped** — exact for a move
    /// between two places, which is the only kind a person makes.
    public static func move(
        _ threadIDs: [ThreadID], to mailbox: MailboxID, from: MailboxID?, accountID: AccountID
    ) -> ThreadSet {
        ThreadSet(
            accountID: accountID,
            update: Dictionary(
                threadIDs.map { ($0, Patch.move(to: mailbox, from: from)) },
                uniquingKeysWith: { a, _ in a }))
    }

    /// Whether a refusal says this server predates `moveTo`.
    ///
    /// The one case where falling back to an `Email/set` patch is right: an
    /// older server answers `invalidProperties` naming the property.
    public static func refusesMoveTo(_ refusal: JSONValue) -> Bool {
        guard let object = refusal.objectValue,
            object["type"]?.stringValue == "invalidProperties"
        else { return false }

        let named = object["properties"]?.arrayValue?.compactMap(\.stringValue) ?? []

        return named.contains("moveTo")
    }

    /// Retires the New marker on a page of conversations.
    ///
    /// **At most ``maxObjects`` ids.** The server answers `requestTooLarge` for
    /// a longer call and refuses the whole batch, so a caller that has drawn
    /// more than that has to chunk rather than discover it on the wire.
    public static func shown(_ threadIDs: [ThreadID], accountID: AccountID) -> ThreadSet {
        ThreadSet(
            accountID: accountID,
            update: Dictionary(threadIDs.map { ($0, Patch.shown) }, uniquingKeysWith: { a, _ in a })
        )
    }

    /// `ThreadSetMethod::MAX_OBJECTS`. Stated here so a caller can chunk before
    /// sending rather than have a whole page of retirements refused at once.
    public static let maxObjects = 500
}
