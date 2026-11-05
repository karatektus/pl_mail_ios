import Foundation

/// The JMAP Session object (RFC 8620 §2).
///
/// **Everything else is discovered from here.** `apiUrl`, `uploadUrl`,
/// `downloadUrl` and `eventSourceUrl` must be read out of this object on every
/// connection and never reconstructed from the server address — plMail is
/// self-hosted and may live behind a reverse proxy on any path.
public struct Session: Hashable, Sendable, Decodable {
    public var capabilities: Capabilities

    /// One JMAP account per **connected mail account**, keyed by account id.
    ///
    /// A user with a work Gmail, a personal IMAP and an Outlook account sees
    /// three accounts under one login. There is no server-side cross-account
    /// query, so a unified inbox is a client-side merge of one query per
    /// account, ordered by `receivedAt`.
    public var accounts: [AccountID: SessionAccount]

    public var primaryAccounts: [String: AccountID]
    public var username: String
    public var apiURL: URL
    public var downloadURL: URLTemplate
    public var uploadURL: URLTemplate
    public var eventSourceURL: URLTemplate
    public var state: StateToken

    private enum CodingKeys: String, CodingKey {
        case capabilities, accounts, primaryAccounts, username
        case apiURL = "apiUrl"
        case downloadURL = "downloadUrl"
        case uploadURL = "uploadUrl"
        case eventSourceURL = "eventSourceUrl"
        case state
    }

    /// The account to open on first launch, when the user has not chosen.
    public var primaryMailAccountID: AccountID? {
        primaryAccounts[Capability.mail.rawValue]
    }

    /// The one account that answers calendar methods, or nil on an instance
    /// without the extension.
    ///
    /// Read from `primaryAccounts` first because that is what the server
    /// nominates, then fall back to the single account advertising the
    /// capability. Nil is a supported state, not a failure.
    public var calendarAccountID: AccountID? {
        if let nominated = primaryAccounts[Capability.calendars.rawValue] {
            return nominated
        }
        return accounts.first { $0.value.accountCapabilities.calendars != nil }?.key
    }

    /// What one account will accept for a scheduled send.
    ///
    /// Per account rather than per server because JMAP puts it there, and
    /// because a client that read one account's ceiling and applied it to
    /// another would bound the picker with a number that account never
    /// published. Nil for an unknown account id or a server that publishes no
    /// submission object.
    public func submissionCapabilities(
        for accountID: AccountID
    ) -> SessionAccount.SubmissionAccountCapabilities? {
        accounts[accountID]?.accountCapabilities.submission
    }

    /// Accounts in a stable order, since the wire form is a dictionary.
    public var orderedAccounts: [(id: AccountID, account: SessionAccount)] {
        accounts
            .map { (id: $0.key, account: $0.value) }
            .sorted {
                $0.account.name.localizedStandardCompare($1.account.name) == .orderedAscending
            }
    }
}

extension Session {
    public struct Capabilities: Hashable, Sendable, Decodable {
        public var core: CoreCapabilities
        /// A plMail extension carrying the VAPID key. Advertised here, but
        /// **never declarable in `using`** — see ``Capability``.
        public var push: PushCapabilities?
        /// Present only on a server that can send APNs pushes. Absent is the
        /// normal case today and must stay unremarkable — a self-hosted
        /// server has no Apple developer account of its own.
        public var apns: APNsCapabilities?
        /// Present only on a server carrying the calendar extension. Absent is
        /// an ordinary, supported instance — not an error, and nothing may
        /// treat it as one. The session-level object is empty; the limits live
        /// per account, because calendars are user-scoped while JMAP accounts
        /// are per connected mailbox.
        public var calendars: CalendarsCapabilities?
        /// Present only on a server carrying the appearance extension. Absent
        /// is an ordinary, supported instance — the client keeps its local
        /// default palette and never offers the theme picker rather than
        /// reporting a failure nobody can act on.
        public var appearance: AppearanceCapabilities?

        private enum CodingKeys: String, CodingKey {
            case core = "urn:ietf:params:jmap:core"
            case push = "urn:plmail:params:jmap:push"
            case apns = "urn:plmail:params:jmap:apns"
            case calendars = "urn:plmail:params:jmap:calendars"
            case appearance = "urn:plmail:params:jmap:appearance"
        }
    }

    public struct CoreCapabilities: Hashable, Sendable, Decodable {
        public var maxSizeUpload: Int
        public var maxConcurrentUpload: Int
        public var maxSizeRequestObject: Int
        public var maxConcurrentRequests: Int
        public var maxCallsInRequest: Int
        public var maxObjectsInGet: Int
        public var maxObjectsInSet: Int
        public var collationAlgorithms: [String]
    }

    public struct PushCapabilities: Hashable, Sendable, Decodable {
        /// An empty key means Web Push is unconfigured on this instance —
        /// don't offer it.
        public var vapidPublicKey: String

        public var isConfigured: Bool { vapidPublicKey.isEmpty == false }
    }

    public struct APNsCapabilities: Hashable, Sendable, Decodable {
        /// Which APNs environment the server's key is for. A token minted by
        /// a debug build is a sandbox token, and sending it to production
        /// APNs fails in a way that does not say so.
        public var environment: String?
        /// The topic the server pushes to — normally the app's bundle id.
        /// Advertised so a mismatch can be spotted rather than debugged.
        public var topic: String?
    }

    /// What the server will accept for an Appearance, published at discovery
    /// time so a client never learns a vocabulary by being refused.
    ///
    /// Every list here is decoded permissively — an absent key becomes an
    /// empty array rather than a decoding failure — because this object grows
    /// server-side and a client that refuses to parse a Session carrying one
    /// unknown extra field is a client that stops logging in after a server
    /// upgrade.
    public struct AppearanceCapabilities: Hashable, Sendable, Decodable {
        /// The compact `{theme, layout, accent, density}` read, enough to
        /// paint the chrome on the first frame instead of flashing the wrong
        /// palette.
        ///
        /// **A hint, never truth.** The Session's `state` is a hash of the
        /// user's account ids and does not move when a theme changes, so a
        /// cached Session holds a stale theme until `Appearance/get` corrects
        /// it. Nothing committed outside the app — an alternate app icon, a
        /// widget tint — may be driven from here, because a correction to that
        /// is visible churn on somebody's home screen rather than one repainted
        /// frame.
        public var appearance: CompactAppearance?
        /// 39 values and growing. Published so a picker can be drawn from the
        /// server's list; an unknown value is still rendered as the default
        /// rather than refused, because this array is what a client holding a
        /// stale build has *not* got.
        public var themes: [String]
        /// Read-only colourways for the product mark. Carried for completeness
        /// — iOS ships no alternate app icons, so nothing consumes it yet.
        public var logoStyles: [String]
        public var layouts: [String]
        public var densities: [String]
        public var backgroundKinds: [String]
        public var backgroundPresets: [String]
        public var unreadEmphases: [String]
        public var fontFamilies: [String]
        /// The knob preset each layout seeds, keyed by layout value, so a
        /// client's sliders sit where the web pane's do after a layout change.
        /// Without it a client would show the old layout's numbers under the
        /// new layout's name.
        public var layoutDefaults: [String: LayoutDefaults]
        /// The server's own clamp constants, keyed by property name.
        ///
        /// **Stated rather than discovered, because out-of-range is clamped
        /// and not refused.** A client that does not read these sends 1.4,
        /// gets 1.0 stored, and is never told unless it also applies the
        /// `updated` map from `Appearance/set`.
        public var ranges: [String: NumericRange]

        private enum CodingKeys: String, CodingKey {
            case appearance, themes, logoStyles, layouts, densities
            case backgroundKinds, backgroundPresets, unreadEmphases, fontFamilies
            case layoutDefaults, ranges
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            appearance = try container.decodeIfPresent(
                CompactAppearance.self, forKey: .appearance)
            themes = try container.decodeIfPresent([String].self, forKey: .themes) ?? []
            logoStyles = try container.decodeIfPresent([String].self, forKey: .logoStyles) ?? []
            layouts = try container.decodeIfPresent([String].self, forKey: .layouts) ?? []
            densities = try container.decodeIfPresent([String].self, forKey: .densities) ?? []
            backgroundKinds =
                try container.decodeIfPresent([String].self, forKey: .backgroundKinds) ?? []
            backgroundPresets =
                try container.decodeIfPresent([String].self, forKey: .backgroundPresets) ?? []
            unreadEmphases =
                try container.decodeIfPresent([String].self, forKey: .unreadEmphases) ?? []
            fontFamilies =
                try container.decodeIfPresent([String].self, forKey: .fontFamilies) ?? []
            layoutDefaults =
                try container.decodeIfPresent(
                    [String: LayoutDefaults].self, forKey: .layoutDefaults)
                ?? [:]
            ranges =
                try container.decodeIfPresent([String: NumericRange].self, forKey: .ranges) ?? [:]
        }

        /// The clamp for a numeric property, or nil on a server that did not
        /// publish one. Nil means "send it and apply what comes back" — the
        /// clamp still happens, it is just not knowable in advance.
        public func range(for property: String) -> NumericRange? { ranges[property] }
    }

    /// The four properties the Session repeats inline. Strings rather than
    /// enums on purpose: the theme vocabulary grows server-side, and a client
    /// that fails to decode a Session because it has not heard of `ocean` is a
    /// client that cannot log in after a server upgrade.
    public struct CompactAppearance: Hashable, Sendable, Decodable {
        public var theme: String?
        public var layout: String?
        /// A six-digit hex colour like `#7d6b4f`.
        public var accent: String?
        public var density: String?

        public init(
            theme: String? = nil, layout: String? = nil, accent: String? = nil,
            density: String? = nil
        ) {
            self.theme = theme
            self.layout = layout
            self.accent = accent
            self.density = density
        }
    }

    /// A layout's seeded knob values.
    ///
    /// `density` is a string here for the same reason the compact read's is:
    /// this is data about the server's vocabulary, and typing it would make an
    /// added value a decoding failure rather than a value to ignore.
    public struct LayoutDefaults: Hashable, Sendable, Decodable {
        public var radius: Double?
        public var paneBlur: Double?
        public var paneAlpha: Double?
        public var density: String?
    }

    /// An inclusive clamp, exactly as `Appearance`'s setters apply it.
    public struct NumericRange: Hashable, Sendable, Decodable {
        public var min: Double
        public var max: Double

        public init(min: Double, max: Double) {
            self.min = min
            self.max = max
        }

        /// The value this range would store, which is what the server reports
        /// back in `Appearance/set`'s `updated` map.
        ///
        /// Clamping rather than refusing is the server's decision and this
        /// mirrors it: an out-of-range slider is a client being sloppy about a
        /// continuum, not a value to put in front of the user as an error.
        public func clamping(_ value: Double) -> Double {
            Swift.min(max, Swift.max(min, value))
        }
    }

    /// Deliberately empty: the server advertises `{}` at session level and puts
    /// every limit on the account. Kept as a type rather than a `Bool` so that
    /// adding a session-level field later is not a source-breaking change.
    public struct CalendarsCapabilities: Hashable, Sendable, Decodable {
        public init() {}
    }
}

/// One connected mail account.
public struct SessionAccount: Hashable, Sendable, Decodable {
    /// Whether a draft save may name its `identityId`. False on any server
    /// that did not say so, which is the safe answer: see
    /// ``MailCapabilities/draftIdentity``.
    public var keepsDraftIdentity: Bool {
        accountCapabilities.mail?.draftIdentity == true
    }

    /// The mail address. Shown to the user wherever accounts are listed.
    public var name: String
    public var isPersonal: Bool
    public var isReadOnly: Bool
    public var accountCapabilities: AccountCapabilities

    public struct AccountCapabilities: Hashable, Sendable, Decodable {
        public var mail: MailCapabilities?
        /// What this account will accept when mail is sent, and how far ahead
        /// it may be scheduled. Optional because an older server published no
        /// submission object at all, and a client that refuses to decode a
        /// Session without one stops logging in against it.
        public var submission: SubmissionAccountCapabilities?
        /// Carried by **one** account at most. Calendars are user-scoped in
        /// plMail while JMAP accounts are per connected mailbox, so every other
        /// account answers `accountNotSupportedByMethod`.
        public var calendars: CalendarAccountCapabilities?

        private enum CodingKeys: String, CodingKey {
            case mail = "urn:ietf:params:jmap:mail"
            case submission = "urn:ietf:params:jmap:submission"
            case calendars = "urn:plmail:params:jmap:calendars"
        }
    }

    /// The scheduling ceiling, published so a picker can bound itself.
    ///
    /// **Reading this does not replace discovering the limit from a refusal.**
    /// `SubmissionEnvelope` enforces the same constant it advertises, and a
    /// send that names a later time is refused by name — which is the stricter
    /// check and the one that stays correct if the server is reconfigured
    /// between a cached Session and a send. What this buys is the half a
    /// refusal cannot: a date picker that will not *offer* a time the server is
    /// going to reject, so the user learns it while choosing rather than from
    /// a failed row in the Outbox an hour later.
    public struct SubmissionAccountCapabilities: Hashable, Sendable, Decodable {
        /// The longest hold this server accepts, in seconds — 30 days today.
        ///
        /// **Zero is meaningful and is not "unknown"**: it is how RFC 8621 §7
        /// says *"this server does not do delayed send"*, and a client that
        /// treated it as absent would offer scheduling that cannot work.
        /// Absent (nil) is the genuinely unknown case — an older server — where
        /// the honest answer is to let the send be attempted and report what
        /// comes back.
        public var maxDelayedSend: Int?

        /// The SMTP extensions the server will honour, keyed by extension name
        /// with the parameters it takes — `["FUTURERELEASE": ["HOLDFOR",
        /// "HOLDUNTIL"]]` on plMail.
        ///
        /// Kept as raw strings rather than an enum: this is the server's
        /// vocabulary, it grows, and an added extension must be a value to
        /// ignore rather than a Session that fails to decode.
        public var submissionExtensions: [String: [String]]?

        public init(
            maxDelayedSend: Int? = nil, submissionExtensions: [String: [String]]? = nil
        ) {
            self.maxDelayedSend = maxDelayedSend
            self.submissionExtensions = submissionExtensions
        }

        /// The latest release time this account will accept for a send made
        /// now, or nil when the server published no ceiling.
        ///
        /// - Parameter now: The moment the hold is measured from. The server
        ///   measures `HOLDUNTIL` against its own clock at the moment the
        ///   submission arrives, so a picker built on this should keep a little
        ///   back from the boundary rather than offering the exact second.
        /// - Returns: The latest acceptable release time, or nil when the
        ///   server published no ceiling or published zero — in which case
        ///   there is no bound to draw rather than a bound of *now*.
        public func latestHold(from now: Date = .now) -> Date? {
            guard let maxDelayedSend, maxDelayedSend > 0 else { return nil }

            return now.addingTimeInterval(TimeInterval(maxDelayedSend))
        }

        /// Whether this account can hold a message at all.
        ///
        /// False on an explicit zero, which is the server saying so; true when
        /// nothing was published, because an older server that has not heard of
        /// the capability may still honour the envelope, and refusing to offer
        /// scheduling on that basis would remove a working feature.
        public var allowsDelayedSend: Bool {
            guard let maxDelayedSend else { return true }

            return maxDelayedSend > 0
        }
    }

    public struct CalendarAccountCapabilities: Hashable, Sendable, Decodable {
        /// The cap on `CalendarEvent/get`, which is **not** core's
        /// `maxObjectsInGet`. Asking for more is refused outright, so a pager
        /// that reads the wrong ceiling fails on the first full page.
        public var maxEventsInGet: Int?
        public var maxEventsInSet: Int?
        /// False on every account today. Creating a calendar is not exposed.
        public var mayCreateCalendar: Bool?
        public var materialisedHorizon: MaterialisedHorizon?
    }

    /// How far either side of today the server has materialised occurrences.
    ///
    /// **The values are opaque.** They are PHP relative-date expressions such as
    /// `"-1 year"` and `"+2 years"`; nothing in this client may parse them.
    /// Quote them at the user or ignore them — a window past the horizon is
    /// refused whole with `cannotCalculateOccurrences`, so the defence is to
    /// clamp the request, not to interpret this string.
    public struct MaterialisedHorizon: Hashable, Sendable, Decodable {
        public var past: String?
        public var future: String?
    }

    public struct MailCapabilities: Hashable, Sendable, Decodable {
        public var maxMailboxesPerEmail: Int?
        public var maxMailboxDepth: Int?
        public var maxSizeMailboxName: Int?
        public var maxSizeAttachmentsPerEmail: Int?
        public var emailQuerySortOptions: [String]?
        public var mayCreateTopLevelMailbox: Bool?
        /// plMail: the server stores `identityId` on a draft. **Check before
        /// sending it** — an older server refuses a whole update patch naming
        /// a property it cannot change, which would lose the text beside it.
        public var draftIdentity: Bool?
    }
}

/// A URI template from the Session object, e.g.
/// `…/jmap/download/{accountId}/{blobId}/{name}?accept={type}`.
///
/// Deliberately not a `URL`: the raw form is not a valid URL until its
/// variables are filled in, and keeping it as a distinct type stops it being
/// passed to something that expects a usable address.
public struct URLTemplate: Hashable, Sendable, Decodable, CustomStringConvertible {
    public let template: String

    public init(_ template: String) {
        self.template = template
    }

    public init(from decoder: any Decoder) throws {
        template = try decoder.singleValueContainer().decode(String.self)
    }

    public var description: String { template }

    /// Substitutes `{name}` variables, percent-encoding each value.
    ///
    /// Unfilled variables are left in place rather than removed, so a missing
    /// one shows up as an obviously broken URL instead of a subtly wrong one.
    public func expanded(_ variables: [String: String]) -> URL? {
        var result = template

        for (name, value) in variables {
            let encoded =
                value.addingPercentEncoding(withAllowedCharacters: .jmapTemplateValue) ?? value
            result = result.replacingOccurrences(of: "{\(name)}", with: encoded)
        }

        return URL(string: result)
    }
}

extension CharacterSet {
    /// Path-segment-safe: `/` must be encoded, or a blob id or filename
    /// containing one would silently change the request path.
    fileprivate static let jmapTemplateValue: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
