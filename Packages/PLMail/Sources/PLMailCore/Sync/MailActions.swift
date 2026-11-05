import Foundation
import JMAPKit
import OSLog
import Observation

/// Archive, trash, star, mark read — and undo.
///
/// Every one applies to the local store first and is sent afterwards. The
/// server propagates outward asynchronously anyway, so waiting for a round
/// trip before moving a row would make the app feel slower than the web UI for
/// no gain in correctness.
///
/// Every one is also undoable, because the alternative is an app that
/// permanently loses mail to a mis-swipe.
@MainActor
@Observable
public final class MailActions {
    /// What the user just did, and how to take it back.
    public struct Undoable: Identifiable, Sendable {
        public let id = UUID()
        public let message: String
        /// True when this device is right and the server has not been told
        /// yet.
        ///
        /// Android's three sentences are deliberate and this is the middle one:
        /// "Archived" means the server knows, "Archived — waiting for the
        /// server" means it does not yet, and "Couldn't archive" means it
        /// refused. Collapsing the first two tells someone on a train that
        /// their mail has moved on the server when it has not.
        public var isQueued = false
        let undo: @MainActor @Sendable () async -> Void
    }

    /// The most recent action, while it can still be taken back.
    public private(set) var pending: Undoable?

    /// How many changes are waiting for the server.
    ///
    /// Surfaced rather than counted in the drain alone: a user who archived six
    /// conversations offline has to be able to see that they have not left the
    /// device, or the app is quietly claiming work it has not done.
    public private(set) var queuedCount = 0

    /// An action the server refused.
    ///
    /// Surfaced rather than logged: the row was already moved optimistically,
    /// so a rejection the user is not told about is the app and the server
    /// quietly disagreeing about where their mail is.
    public private(set) var failure: String?

    private let client: JMAPClient
    private let store: SyncStore
    /// Where an action goes when the server cannot be reached.
    ///
    /// Nil means the previous behaviour: the optimistic change is rolled back
    /// and the gesture is lost. That is only right in a test with no queue —
    /// the app always has one.
    private let queue: ActionQueue?
    private let logger = Logger(subsystem: "de.plmail", category: "actions")
    private var dismissal: Task<Void, Never>?

    /// How long an undo stays offered. Long enough to notice a mistake, short
    /// enough not to hover over the next thing being read.
    ///
    /// **Settable, and meant to be set.** This is the one control in the app
    /// with a deadline, so a fixed six seconds silently excludes exactly the
    /// people who need longer — the composition root assigns
    /// `UndoWindow.current()`, which asks the system for the user's own
    /// recommended timeout. It lives in the view layer because that is where
    /// the accessibility API is; the value has to be pushed down rather than
    /// read from here.
    public var undoWindow: Duration = .seconds(6)

    /// `queue` defaults to the queue for the server this app is signed into,
    /// which ``MailSyncService`` claims as it is built. Taken from there rather
    /// than passed in because the view that constructs this type is handed a
    /// client and a store and no server id.
    public init(client: JMAPClient, store: SyncStore, queue: ActionQueue? = nil) {
        self.client = client
        self.store = store
        self.queue = queue ?? ActionQueue.current
    }

    /// Re-reads how many changes are waiting.
    ///
    /// Called after a drain as well as after an enqueue: the count is on screen
    /// and the drain that empties it runs somewhere else entirely.
    public func refreshQueuedCount() async {
        queuedCount = await queue?.count() ?? 0
    }

    // MARK: - Actions

    /// Archives a thread: removes it from the Inbox, and nothing else.
    ///
    /// "Archived" here means *carries no Inbox label*. Adding an Archive label
    /// instead would leave it in the inbox as well, which is not what anyone
    /// means by archiving.
    public func archive(_ target: ActionTarget) async {
        guard let inbox = try? await store.mailbox(role: .inbox, accountKey: target.accountKey)
        else { return }

        // Joined in the same patch as leaving the Inbox: a message must belong
        // to at least one mailbox, and most inbox mail belongs to no other.
        let archive = try? await store.mailbox(role: .archive, accountKey: target.accountKey)

        await apply(
            target,
            kind: .archive,
            inverseKind: .moveToInbox,
            localChange: {
                try await $0.removeFromFeeds(target.threadID, accountKey: target.accountKey)
            },
            request: EmailSet.archive(
                ids: target.emailIDs, inbox: inbox, archive: archive,
                accountID: target.accountID),
            undoMessage: "Archived",
            undoneMessage: Self.putBackMessage,
            undoRequest: EmailSet.moveToInbox(
                ids: target.emailIDs, inbox: inbox, leaving: archive,
                accountID: target.accountID)
        )
    }

    /// Moves a thread to Trash.
    ///
    /// Presented as Trash rather than Delete because that is what it is: the
    /// server has no hard-delete path, and the mail is still on the provider.
    public func trash(_ target: ActionTarget) async {
        guard let inbox = try? await store.mailbox(role: .inbox, accountKey: target.accountKey)
        else { return }

        await apply(
            target,
            kind: .trash,
            inverseKind: .moveToInbox,
            localChange: {
                try await $0.removeFromFeeds(target.threadID, accountKey: target.accountKey)
            },
            request: EmailSet.trash(ids: target.emailIDs, accountID: target.accountID),
            undoMessage: "Moved to Trash",
            undoneMessage: Self.putBackMessage,
            // Undoing a trash puts it back in the Inbox: the destroy moved it
            // out of every mailbox it was in, and the inbox is where the user
            // was looking at it.
            undoRequest: EmailSet.moveToInbox(
                ids: target.emailIDs, inbox: inbox, accountID: target.accountID)
        )
    }

    public func setFlagged(_ isFlagged: Bool, _ target: ActionTarget) async {
        await apply(
            target,
            kind: .setFlagged(isFlagged),
            inverseKind: .setFlagged(isFlagged == false),
            localChange: {
                try await $0.setFlagged(
                    isFlagged,
                    emailIDs: target.emailIDs.map(\.rawValue),
                    accountKey: target.accountKey)
                return []
            },
            request: EmailSet.setFlagged(
                isFlagged, ids: target.emailIDs, accountID: target.accountID),
            undoMessage: isFlagged ? "Starred" : "Unstarred",
            undoneMessage: isFlagged ? "Unstarred" : "Starred",
            undoRequest: EmailSet.setFlagged(
                isFlagged == false, ids: target.emailIDs, accountID: target.accountID)
        )
    }

    public func setSeen(_ isSeen: Bool, _ target: ActionTarget) async {
        await apply(
            target,
            kind: .setSeen(isSeen),
            inverseKind: .setSeen(isSeen == false),
            localChange: {
                try await $0.setSeen(
                    isSeen,
                    emailIDs: target.emailIDs.map(\.rawValue),
                    accountKey: target.accountKey)
                return []
            },
            request: EmailSet.setSeen(isSeen, ids: target.emailIDs, accountID: target.accountID),
            undoMessage: isSeen ? "Marked read" : "Marked unread",
            undoneMessage: isSeen ? "Marked unread" : "Marked read",
            undoRequest: EmailSet.setSeen(
                isSeen == false, ids: target.emailIDs, accountID: target.accountID)
        )
    }

    /// Applies or removes a label across every message in a conversation.
    ///
    /// The whole thread, like every other action here: labelling one reply and
    /// not the rest is not something anyone means from a conversation list.
    ///
    /// The label's name is passed in rather than looked up so the undo bar can
    /// say which one — "Labelled Work" tells you what to undo; "Labelled" does
    /// not.
    public func setLabel(
        _ isApplied: Bool, mailbox: MailboxID, named name: String, _ target: ActionTarget
    ) async {
        // Resolved here rather than carried by the caller: the queue may only
        // hold the user-scoped id, and a binding id survives neither a relaunch
        // against a rebuilt label nor a drain against another account.
        let labelID = try? await store.labelID(
            mailboxID: mailbox.rawValue, accountKey: target.accountKey)

        await apply(
            target,
            kind: labelID.map { .setLabel(isApplied: isApplied, labelID: $0) },
            inverseKind: labelID.map { .setLabel(isApplied: isApplied == false, labelID: $0) },
            localChange: {
                try await $0.setMailbox(
                    isApplied,
                    mailboxID: mailbox.rawValue,
                    emailIDs: target.emailIDs.map(\.rawValue),
                    accountKey: target.accountKey)
                return []
            },
            request: EmailSet.setLabel(
                isApplied, mailbox: mailbox, ids: target.emailIDs, accountID: target.accountID),
            undoMessage: isApplied ? "Labelled \(name)" : "Removed \(name)",
            undoneMessage: isApplied ? "Removed \(name)" : "Labelled \(name)",
            undoRequest: EmailSet.setLabel(
                isApplied == false, mailbox: mailbox, ids: target.emailIDs,
                accountID: target.accountID)
        )
    }

    /// Puts a conversation away until a time, or brings it back now.
    ///
    /// Not an Email/set: snooze is thread state, and the server does the label
    /// moves — out of the Inbox now, back into it when the time comes, marked
    /// unread so it is noticed. So this cannot go through `apply`, which is
    /// built around one EmailSet and its inverse.
    ///
    /// The local change is the same one archiving makes — the row leaves the
    /// list — because that is what happens on the server too.
    public func snooze(_ target: ActionTarget, until: Date?) async {
        failure = nil

        // Read **before** the write. A conversation that was already sleeping
        // until Friday and is re-snoozed to tomorrow must go back to Friday if
        // the user undoes it, not wake up — undoing to `nil` loses a time the
        // user chose and cannot get back from anywhere.
        let previous = try? await store.snoozedUntil(
            threadID: target.threadID, accountKey: target.accountKey)

        let removed: [RemovedFeedRow]

        if until == nil {
            // Waking puts it back in the Inbox, which this list may or may not
            // be; a refetch settles it rather than a guessed local insert.
            removed = []
        } else {
            removed =
                (try? await store.removeFromFeeds(
                    target.threadID, accountKey: target.accountKey)) ?? []
        }

        offerSnoozeUndo(
            message: Self.describeSnooze(until),
            applied: until,
            previous: previous ?? nil,
            targets: [target])

        switch await sendSnooze(until, targets: [target]) {
        case .accepted:
            // The server changed which labels the messages carry, so the
            // cached copies are stale in a way only it can settle.
            await refetch(target)

        case .refused:
            dismissUndo()
            try? await store.restoreFeedRows(removed)
            await refetch(target)

        case .unreachable:
            await enqueue(
                .snooze(until: until),
                inverseKind: .snooze(until: previous ?? nil),
                target: target,
                message: Self.describeSnooze(until),
                restoring: removed)
        }
    }

    /// Offers an undo that puts each conversation back to the time it was
    /// sleeping until before, and is itself undoable.
    ///
    /// Grouped by previous time rather than sent as one call: a bulk snooze
    /// over conversations that were asleep until three different days has three
    /// correct answers, and picking one of them would be wrong about the rest.
    private func offerSnoozeUndo(
        message: String,
        applied: Date?,
        previous: Date?,
        targets: [ActionTarget]
    ) {
        offerSnoozeUndo(
            message: message, applied: applied,
            previousByTarget: Dictionary(
                uniqueKeysWithValues: targets.map { ($0.id, previous) }),
            targets: targets)
    }

    private func offerSnoozeUndo(
        message: String,
        applied: Date?,
        previousByTarget: [String: Date?],
        targets: [ActionTarget]
    ) {
        offerUndo(message) { [weak self] in
            guard let self else { return }

            var accepted = true

            for (previous, group) in Self.groupedByPreviousTime(
                targets, previousByTarget: previousByTarget)
            {
                if await sendSnooze(previous, targets: group) != .accepted { accepted = false }
            }

            for target in targets {
                await refetch(target)
            }

            guard accepted else { return }

            // The way back from the way back: re-applying the snooze, with the
            // times the conversations have just been restored to as its own
            // inverse.
            offerSnoozeUndo(
                message: Self.putBackMessage,
                applied: nil,
                previousByTarget: Dictionary(
                    uniqueKeysWithValues: targets.map { ($0.id, applied) }),
                targets: targets)
        }
    }

    /// The selection split into runs that shared a previous snooze time.
    ///
    /// `nil` and a date are different groups: one wakes the conversation and
    /// the other puts it back to sleep.
    static func groupedByPreviousTime(
        _ targets: [ActionTarget],
        previousByTarget: [String: Date?]
    ) -> [(Date?, [ActionTarget])] {
        var groups: [Date?: [ActionTarget]] = [:]

        for target in targets {
            let previous = previousByTarget[target.id] ?? nil
            groups[previous, default: []].append(target)
        }

        // Sorted so the calls go out in a stable order — an unordered
        // dictionary walk makes a failing test tell a different story on every
        // run.
        return
            groups
            .sorted { ($0.key ?? .distantPast) < ($1.key ?? .distantPast) }
            .map { ($0.key, $0.value) }
    }

    /// Snoozes or wakes a group of conversations, one request per account.
    ///
    /// `Thread/set` accepts up to 500 objects, so a whole selection in one
    /// account is a single round trip rather than one per conversation — which
    /// over a home uplink is the difference between instant and a spinner.
    private func sendSnooze(_ until: Date?, targets: [ActionTarget]) async -> SendOutcome {
        var outcome = SendOutcome.accepted

        for (_, group) in Dictionary(grouping: targets, by: \.accountKey) {
            guard let first = group.first else { continue }

            let patches = Dictionary(
                group.map {
                    (ThreadID($0.threadID), ThreadSet.Patch(snoozedUntil: until.map(UTCDate.init)))
                },
                uniquingKeysWith: { first, _ in first })

            let result = await sendThreadSet(
                ThreadSet(accountID: first.accountID, update: patches), target: first)

            // A refusal outranks an unreachable: it is the one the user has to
            // be told about, and it is the one that puts rows back.
            if result == .refused { return .refused }
            if result == .unreachable { outcome = .unreachable }
        }

        return outcome
    }

    /// - Returns: What the server did, or that it never answered.
    private func sendThreadSet(_ request: ThreadSet, target: ActionTarget) async -> SendOutcome {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(request)
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            if let refused = result.notUpdated, refused.isEmpty == false {
                failure = String(
                    localized: "The server wouldn't change that snooze.", bundle: .module)
                logger.error("Snooze refused: \(String(describing: refused), privacy: .public)")

                return .refused
            }

            return .accepted
        } catch {
            logger.error("Snooze failed: \(error, privacy: .public)")

            guard ActionFailure.classify(error).isQueueWorthy else {
                failure = Self.describe(error)

                return .refused
            }

            return .unreachable
        }
    }

    private static func describe(_ until: Date?) -> String {
        guard let until else { return "" }

        return "until " + until.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// What the undo bar says about a snooze.
    private static func describeSnooze(_ until: Date?) -> String {
        until == nil ? "Woken" : "Snoozed \(describe(until))"
    }

    /// Files conversations under `destination` and takes them out of the list
    /// showing `view` — the web's "Move to".
    ///
    /// **Carried out by the server**, through `Thread/set moveTo`: it decides
    /// what comes off, which differs by provider in ways a patch composed here
    /// cannot express. Only a server that refuses `moveTo` by name gets the
    /// `Email/set` fallback, and that is remembered per account for the life
    /// of the process so an upgraded server is noticed on the next launch.
    ///
    /// `view` is nil for a list with no mailbox of its own (unified inbox,
    /// search, Starred, a category tab). Undo is the same move with the two
    /// swapped.
    ///
    /// Not queued offline yet: an unreachable server puts the rows back and
    /// says so. The queue needs a destination it can re-resolve per account,
    /// which is planned in `docs/parity/ANDROID-CATCHUP-2026-11.md` §1.
    public func move(
        _ targets: [ActionTarget], to destination: MailboxID, from view: MailboxID?,
        named name: String
    ) async {
        guard targets.isEmpty == false else { return }

        failure = nil

        var removed: [RemovedFeedRow] = []

        for target in targets {
            removed +=
                (try? await store.removeFromFeeds(
                    target.threadID, accountKey: target.accountKey)) ?? []
        }

        let message = String(localized: "Moved to \(name)", bundle: .module)

        offerUndo(message) { [weak self] in
            guard let self else { return }

            guard let back = view else {
                // From a list with no mailbox, the way back is the Inbox: that
                // is the one thing the server took off.
                for (accountKey, group) in Dictionary(grouping: targets, by: \.accountKey) {
                    guard
                        let inbox = try? await store.mailbox(role: .inbox, accountKey: accountKey)
                    else { continue }

                    _ = await sendMove(group, to: inbox, from: destination)
                }

                for target in targets { await refetch(target) }

                return
            }

            _ = await sendMove(targets, to: back, from: destination)

            for target in targets { await refetch(target) }
        }

        switch await sendMove(targets, to: destination, from: view) {
        case .accepted:
            for target in targets { await refetch(target) }

        case .refused:
            dismissUndo()
            try? await store.restoreFeedRows(removed)

            for target in targets { await refetch(target) }

        case .unreachable:
            dismissUndo()
            try? await store.restoreFeedRows(removed)
            failure = Self.unreachableMessage
        }
    }

    /// Accounts whose server answered that it does not know `moveTo`.
    private var accountsWithoutMoveTo: Set<String> = []

    /// One `Thread/set` per account, or the `Email/set` fallback where the
    /// server predates the instruction.
    private func sendMove(
        _ targets: [ActionTarget], to destination: MailboxID, from view: MailboxID?
    ) async -> SendOutcome {
        var outcome = SendOutcome.accepted

        for (accountKey, group) in Dictionary(grouping: targets, by: \.accountKey) {
            guard let first = group.first else { continue }

            var result: SendOutcome

            if accountsWithoutMoveTo.contains(accountKey) {
                result = await sendMoveFallback(group, to: destination, from: view)
            } else {
                let request = ThreadSet.move(
                    group.map { ThreadID($0.threadID) }, to: destination, from: view,
                    accountID: first.accountID)

                switch await sendMoveInstruction(request) {
                case .outcome(let sent):
                    result = sent

                case .unknownToServer:
                    accountsWithoutMoveTo.insert(accountKey)
                    result = await sendMoveFallback(group, to: destination, from: view)
                }
            }

            if result == .refused { return .refused }
            if result == .unreachable { outcome = .unreachable }
        }

        return outcome
    }

    private enum MoveAnswer {
        case outcome(SendOutcome)
        case unknownToServer
    }

    private func sendMoveInstruction(_ request: ThreadSet) async -> MoveAnswer {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(request)
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            if let refused = result.notUpdated, refused.isEmpty == false {
                if refused.values.contains(where: ThreadSet.refusesMoveTo) {
                    return .unknownToServer
                }

                failure = String(
                    localized: "The server wouldn't move that conversation.", bundle: .module)
                logger.error("Move refused: \(String(describing: refused), privacy: .public)")

                return .outcome(.refused)
            }

            return .outcome(.accepted)
        } catch {
            logger.error("Move failed: \(error, privacy: .public)")

            guard ActionFailure.classify(error).isQueueWorthy else {
                failure = Self.describe(error)

                return .outcome(.refused)
            }

            return .outcome(.unreachable)
        }
    }

    /// The patch for a server without `moveTo`.
    ///
    /// Refuses moves in or out of Trash and Spam out loud: those are provider
    /// operations, and detaching Trash as though it were a tag is the wrong
    /// thing done quietly.
    private func sendMoveFallback(
        _ group: [ActionTarget], to destination: MailboxID, from view: MailboxID?
    ) async -> SendOutcome {
        guard let first = group.first else { return .accepted }

        let accountKey = first.accountKey
        let trash = try? await store.mailbox(role: .trash, accountKey: accountKey)
        let junk = try? await store.mailbox(role: .junk, accountKey: accountKey)
        let bins = [trash, junk].compactMap { $0 }

        if bins.contains(destination) || (view.map { bins.contains($0) } ?? false) {
            failure = String(
                localized: "This server is too old to move mail in or out of Trash or Spam.",
                bundle: .module)

            return .refused
        }

        var leaving = view

        if leaving == nil {
            leaving = try? await store.mailbox(role: .inbox, accountKey: accountKey)
        }

        guard let leaving else { return .refused }

        return await send(
            EmailSet.moveFallback(
                ids: group.flatMap(\.emailIDs), to: destination, leaving: leaving,
                accountID: first.accountID),
            target: first)
    }

    /// Reports a conversation as spam, or rescues it.
    ///
    /// Both directions are undoable, which matters more here than elsewhere:
    /// a mis-tap on Spam trains the provider's filter against someone the user
    /// actually wanted to hear from.
    public func setSpam(_ isSpam: Bool, _ target: ActionTarget) async {
        guard let inbox = try? await store.mailbox(role: .inbox, accountKey: target.accountKey),
            let junk = try? await store.mailbox(role: .junk, accountKey: target.accountKey)
        else {
            failure = String(localized: "This account has no Spam mailbox.", bundle: .module)
            return
        }

        await apply(
            target,
            kind: isSpam ? .spam : .moveToInbox,
            inverseKind: isSpam ? .moveToInbox : .spam,
            localChange: {
                try await $0.removeFromFeeds(target.threadID, accountKey: target.accountKey)
            },
            request: EmailSet.setSpam(
                isSpam, ids: target.emailIDs, inbox: inbox, junk: junk,
                accountID: target.accountID),
            undoMessage: isSpam ? "Reported as spam" : "Moved to Inbox",
            undoneMessage: isSpam ? "Moved to Inbox" : "Reported as spam",
            undoRequest: EmailSet.setSpam(
                isSpam == false, ids: target.emailIDs, inbox: inbox, junk: junk,
                accountID: target.accountID)
        )
    }

    // MARK: - Bulk

    /// What a selection can be acted on with.
    ///
    /// A label is named by its **user-scoped** ``LabelID`` rather than a
    /// mailbox id, because a selection can span accounts and a mailbox id
    /// belongs to exactly one of them. The binding is resolved per account on
    /// the way out — which is the whole reason the server exposes `labelId`.
    public enum BulkAction: Sendable {
        case archive
        case trash
        case setSeen(Bool)
        case setFlagged(Bool)
        case setLabel(Bool, LabelID, name: String)
        /// Nil wakes the selection.
        ///
        /// Not an `Email/set` like the others: snooze is thread state and the
        /// server does the label moves, so it takes its own path out of
        /// ``perform(_:on:)`` rather than a request pair.
        case snooze(Date?)
    }

    /// Applies one action to many conversations at once.
    ///
    /// Every account's changes go out in a **single** batch — one `Email/set`
    /// per account, all in one POST — rather than a request per conversation.
    /// Selecting forty messages and archiving them is one round trip, which
    /// over a home uplink is the difference between instant and a progress
    /// spinner.
    ///
    /// One undo covers the whole selection, because that is what was done: an
    /// undo bar per conversation would be forty toasts for one gesture.
    public func perform(_ action: BulkAction, on targets: [ActionTarget]) async {
        guard targets.isEmpty == false else { return }

        failure = nil

        if case .snooze(let until) = action {
            await performSnooze(until, on: targets)

            return
        }

        let byAccount = Dictionary(grouping: targets, by: \.accountKey)
        var requests: [(target: ActionTarget, request: EmailSet, undo: EmailSet)] = []

        for (accountKey, group) in byAccount {
            guard let pair = await self.requests(for: action, accountKey: accountKey, group: group)
            else { continue }

            // One target per account stands in for the group when a refetch is
            // needed; it carries every email id in that account's selection.
            let combined = ActionTarget(
                threadID: group[0].threadID,
                accountKey: accountKey,
                accountID: group[0].accountID,
                emailIDs: group.flatMap(\.emailIDs)
            )

            requests.append((combined, pair.request, pair.undo))
        }

        guard requests.isEmpty == false else { return }

        var removedRows: [RemovedFeedRow] = []

        for target in targets {
            removedRows += (try? await localChange(for: action, target: target)) ?? []
        }

        let undoRequests = requests.map { (target: $0.target, request: $0.undo) }
        let restored = removedRows

        offerUndo(Self.describe(action, count: targets.count)) { [weak self] in
            guard let self else { return }

            for pair in undoRequests {
                _ = await send(pair.request, target: pair.target)
                await refetch(pair.target)
            }
        }

        // Sent as one batch, then inspected per call: one account being
        // read-only must not silently discard the others' changes.
        var refused = false
        var unreachable = false

        for pair in requests {
            switch await send(pair.request, target: pair.target) {
            case .accepted: continue
            case .refused: refused = true
            case .unreachable: unreachable = true
            }
        }

        if refused {
            dismissUndo()
            try? await store.restoreFeedRows(restored)

            for pair in requests {
                await refetch(pair.target)
            }

            return
        }

        guard unreachable else { return }

        // Queued per conversation rather than per account: the feed projection
        // asks the queue which *threads* it has an opinion about, and a
        // whole-account entry would tell it nothing about which rows a sync may
        // rewrite.
        await enqueueBulk(action, targets: targets, restoring: restored)
    }

    /// Files every conversation in a selection the server never heard about.
    private func enqueueBulk(
        _ action: BulkAction, targets: [ActionTarget], restoring rows: [RemovedFeedRow]
    ) async {
        guard let queue, let kind = Self.kind(for: action) else {
            dismissUndo()
            try? await store.restoreFeedRows(rows)
            failure = Self.unreachableMessage

            return
        }

        var queuedIDs: [UUID] = []

        for target in targets {
            let mutation = PendingMutation(
                accountKey: target.accountKey,
                accountID: target.accountID,
                threadID: target.threadID,
                emailIDs: target.emailIDs,
                kind: kind
            )

            if let queued = try? await queue.enqueue(mutation) { queuedIDs.append(queued.id) }
        }

        await refreshQueuedCount()

        let ids = queuedIDs

        offerUndo(
            Self.queuedMessage(Self.describe(action, count: targets.count)), isQueued: true
        ) { [weak self] in
            guard let self else { return }

            for id in ids {
                await queue.remove(id)
            }

            await refreshQueuedCount()
            try? await store.restoreFeedRows(rows)

            for target in targets {
                await undoLocally(Self.inverseKind(of: action), target: target, restoring: rows)
            }
        }
    }

    /// How a bulk action is filed for later.
    ///
    /// No account is needed: a bulk label change already names the label by its
    /// user-scoped id, which is the whole reason ``BulkAction/setLabel(_:_:name:)``
    /// carries one rather than a binding.
    private static func kind(for action: BulkAction) -> PendingMutation.Kind? {
        switch action {
        case .archive: .archive
        case .trash: .trash
        case .setSeen(let isSeen): .setSeen(isSeen)
        case .setFlagged(let isFlagged): .setFlagged(isFlagged)
        case .setLabel(let isApplied, let labelID, _):
            .setLabel(
                isApplied: isApplied, labelID: labelID)
        case .snooze(let until): .snooze(until: until)
        }
    }

    /// The local effect of taking a queued bulk action back.
    private static func inverseKind(of action: BulkAction) -> PendingMutation.Kind {
        switch action {
        case .archive, .trash: .moveToInbox
        case .setSeen(let isSeen): .setSeen(isSeen == false)
        case .setFlagged(let isFlagged): .setFlagged(isFlagged == false)
        case .setLabel(let isApplied, let labelID, _):
            .setLabel(
                isApplied: isApplied == false, labelID: labelID)
        case .snooze: .snooze(until: nil)
        }
    }

    /// Snoozes or wakes a whole selection.
    ///
    /// Each conversation's previous snooze time is read before the write, so
    /// the undo restores every one of them to the different day it was already
    /// sleeping until rather than waking the lot.
    private func performSnooze(_ until: Date?, on targets: [ActionTarget]) async {
        var previousByTarget: [String: Date?] = [:]
        var removed: [RemovedFeedRow] = []

        for target in targets {
            previousByTarget[target.id] =
                (try? await store.snoozedUntil(
                    threadID: target.threadID, accountKey: target.accountKey)) ?? nil

            guard until != nil else { continue }

            removed +=
                (try? await store.removeFromFeeds(
                    target.threadID, accountKey: target.accountKey)) ?? []
        }

        offerSnoozeUndo(
            message: Self.describe(.snooze(until), count: targets.count),
            applied: until,
            previousByTarget: previousByTarget,
            targets: targets)

        switch await sendSnooze(until, targets: targets) {
        case .accepted:
            for target in targets {
                await refetch(target)
            }

        case .refused:
            dismissUndo()
            try? await store.restoreFeedRows(removed)

            for target in targets {
                await refetch(target)
            }

        case .unreachable:
            await enqueueBulk(.snooze(until), targets: targets, restoring: removed)
        }
    }

    /// The wire pair for one account's share of a bulk action.
    private func requests(
        for action: BulkAction, accountKey: String, group: [ActionTarget]
    ) async -> (request: EmailSet, undo: EmailSet)? {
        let ids = group.flatMap(\.emailIDs)
        let accountID = group[0].accountID

        switch action {
        case .archive:
            guard let inbox = try? await store.mailbox(role: .inbox, accountKey: accountKey)
            else { return nil }

            let archive = try? await store.mailbox(role: .archive, accountKey: accountKey)

            return (
                EmailSet.archive(ids: ids, inbox: inbox, archive: archive, accountID: accountID),
                EmailSet.moveToInbox(
                    ids: ids, inbox: inbox, leaving: archive, accountID: accountID)
            )

        case .trash:
            guard let inbox = try? await store.mailbox(role: .inbox, accountKey: accountKey)
            else { return nil }

            return (
                EmailSet.trash(ids: ids, accountID: accountID),
                EmailSet.moveToInbox(ids: ids, inbox: inbox, accountID: accountID)
            )

        case .setSeen(let isSeen):
            return (
                EmailSet.setSeen(isSeen, ids: ids, accountID: accountID),
                EmailSet.setSeen(isSeen == false, ids: ids, accountID: accountID)
            )

        case .setFlagged(let isFlagged):
            return (
                EmailSet.setFlagged(isFlagged, ids: ids, accountID: accountID),
                EmailSet.setFlagged(isFlagged == false, ids: ids, accountID: accountID)
            )

        case .setLabel(let isApplied, let labelID, _):
            // An account with no binding for this label is skipped rather than
            // failed: labels are user-scoped and a selection spanning accounts
            // will routinely include one that has never seen this label.
            guard
                let mailbox = try? await store.mailbox(labelID: labelID, accountKey: accountKey)
            else { return nil }

            return (
                EmailSet.setLabel(isApplied, mailbox: mailbox, ids: ids, accountID: accountID),
                EmailSet.setLabel(
                    isApplied == false, mailbox: mailbox, ids: ids, accountID: accountID)
            )

        case .snooze:
            // Never reached: `perform` sends a snooze down its own path,
            // because it is a `Thread/set` and has no `Email/set` inverse to
            // pair with. Returning nil rather than crashing keeps a future
            // caller that forgets from taking the app with it.
            return nil
        }
    }

    private func localChange(
        for action: BulkAction, target: ActionTarget
    ) async throws
        -> [RemovedFeedRow]
    {
        let emailIDs = target.emailIDs.map(\.rawValue)

        switch action {
        case .archive, .trash:
            return try await store.removeFromFeeds(target.threadID, accountKey: target.accountKey)

        case .setSeen(let isSeen):
            try await store.setSeen(isSeen, emailIDs: emailIDs, accountKey: target.accountKey)

        case .setFlagged(let isFlagged):
            try await store.setFlagged(
                isFlagged, emailIDs: emailIDs, accountKey: target.accountKey)

        case .setLabel(let isApplied, let labelID, _):
            guard
                let mailbox = try? await store.mailbox(
                    labelID: labelID, accountKey: target.accountKey)
            else { return [] }

            try await store.setMailbox(
                isApplied, mailboxID: mailbox.rawValue, emailIDs: emailIDs,
                accountKey: target.accountKey)

        case .snooze:
            // Handled by `performSnooze`, which has to read each conversation's
            // previous snooze time before the rows leave.
            break
        }

        return []
    }

    private static func describe(_ action: BulkAction, count: Int) -> String {
        let noun = count == 1 ? "conversation" : "conversations"

        return switch action {
        case .archive: "Archived \(count) \(noun)"
        case .trash: "Moved \(count) \(noun) to Trash"
        case .setSeen(let isSeen): "Marked \(count) \(noun) \(isSeen ? "read" : "unread")"
        case .setFlagged(let isFlagged): "\(isFlagged ? "Starred" : "Unstarred") \(count) \(noun)"
        case .setLabel(let isApplied, _, let name):
            isApplied
                ? "Labelled \(count) \(noun) \(name)" : "Removed \(name) from \(count) \(noun)"
        case .snooze(let until):
            until == nil
                ? "Woke \(count) \(noun)" : "Snoozed \(count) \(noun) \(describe(until))"
        }
    }

    // MARK: - Undo

    public func undo() async {
        guard let pending else { return }

        self.pending = nil
        dismissal?.cancel()

        await pending.undo()
    }

    public func dismissUndo() {
        pending = nil
        dismissal?.cancel()
    }

    // MARK: - Machinery

    /// `kind` is how this action is filed if the server cannot be reached, and
    /// nil when it cannot be filed at all — a label with no user-scoped
    /// `labelId` has nothing stable to re-resolve at drain time, so keeping it
    /// would mean replaying a binding id that may by then name a different
    /// label.
    private func apply(
        _ target: ActionTarget,
        kind: PendingMutation.Kind?,
        inverseKind: PendingMutation.Kind?,
        localChange: @Sendable (SyncStore) async throws -> [RemovedFeedRow],
        request: EmailSet,
        undoMessage: String,
        undoneMessage: String,
        undoRequest: EmailSet
    ) async {
        failure = nil
        // Kept so a refusal can put the row back exactly where it was, rather
        // than re-paging the list and moving the reader's place.
        let removedRows = (try? await localChange(store)) ?? []

        offerReversible(
            message: undoMessage, request: request,
            undoneMessage: undoneMessage, inverse: undoRequest,
            target: target)

        switch await send(request, target: target) {
        case .accepted:
            return

        case .refused:
            // The optimistic move has to be taken back. Leaving it would show
            // a message as archived that is still in the inbox on every other
            // device — divergence the user has no way to notice.
            dismissUndo()
            try? await store.restoreFeedRows(removedRows)
            await refetch(target)

        case .unreachable:
            // Kept, not discarded. The user archived a conversation on a train
            // and watched the row leave; rolling it back and saying "couldn't
            // reach the server" throws away work they have already seen happen.
            guard let kind, let inverseKind else {
                dismissUndo()
                try? await store.restoreFeedRows(removedRows)
                failure = Self.unreachableMessage

                return
            }

            await enqueue(
                kind, inverseKind: inverseKind, target: target,
                message: undoMessage, restoring: removedRows)
        }
    }

    /// Offers an undo that is itself undoable.
    ///
    /// Without the re-offer, a mis-tap on Undo is unrecoverable — there is no
    /// way back from the way back, and the only remedy is to redo the gesture
    /// by hand and hope the row is still findable. The message alternates with
    /// the action, so the bar never claims the opposite of what just happened.
    private func offerReversible(
        message: String,
        request: EmailSet,
        undoneMessage: String,
        inverse: EmailSet,
        target: ActionTarget
    ) {
        offerUndo(message) { [weak self] in
            guard let self else { return }

            // The undo re-fetches rather than reversing the local edit: the
            // server is the authority on where a message ended up, and a
            // guessed reversal would drift from it.
            let outcome = await send(inverse, target: target)
            await refetch(target)

            guard outcome == .accepted else { return }

            offerReversible(
                message: undoneMessage, request: inverse,
                undoneMessage: message, inverse: request,
                target: target)
        }
    }

    /// Files a change the server never heard about, and says so.
    private func enqueue(
        _ kind: PendingMutation.Kind,
        inverseKind: PendingMutation.Kind,
        target: ActionTarget,
        message: String,
        restoring rows: [RemovedFeedRow]
    ) async {
        guard let queue else {
            // No queue: the old behaviour, which is at least honest about
            // having lost the change rather than pretending it is waiting.
            dismissUndo()
            try? await store.restoreFeedRows(rows)
            failure = Self.unreachableMessage

            return
        }

        let mutation = PendingMutation(
            accountKey: target.accountKey,
            accountID: target.accountID,
            threadID: target.threadID,
            emailIDs: target.emailIDs,
            kind: kind
        )

        guard let queued = try? await queue.enqueue(mutation) else {
            dismissUndo()
            try? await store.restoreFeedRows(rows)
            failure = Self.unreachableMessage

            return
        }

        await refreshQueuedCount()

        // Taking back a change that never left the device means deleting it
        // from the queue, not sending its opposite: sending an inverse the
        // server never saw the original of would either fail the same way or,
        // worse, arrive first.
        offerUndo(Self.queuedMessage(message), isQueued: true) { [weak self] in
            guard let self else { return }

            await queue.remove(queued.id)
            await refreshQueuedCount()
            await undoLocally(inverseKind, target: target, restoring: rows)
        }
    }

    /// Reverses a queued change on this device only.
    private func undoLocally(
        _ inverseKind: PendingMutation.Kind,
        target: ActionTarget,
        restoring rows: [RemovedFeedRow]
    ) async {
        let emailIDs = target.emailIDs.map(\.rawValue)

        switch inverseKind {
        case .moveToInbox, .snooze(nil):
            try? await store.restoreFeedRows(rows)

        case .archive, .trash, .spam, .snooze:
            try? await store.removeFromFeeds(target.threadID, accountKey: target.accountKey)

        case .setSeen(let isSeen):
            try? await store.setSeen(isSeen, emailIDs: emailIDs, accountKey: target.accountKey)

        case .setFlagged(let isFlagged):
            try? await store.setFlagged(
                isFlagged, emailIDs: emailIDs, accountKey: target.accountKey)

        case .setLabel(let isApplied, let labelID):
            guard
                let mailbox = try? await store.mailbox(
                    labelID: labelID, accountKey: target.accountKey)
            else { return }

            try? await store.setMailbox(
                isApplied, mailboxID: mailbox.rawValue, emailIDs: emailIDs,
                accountKey: target.accountKey)
        }
    }

    /// What happened to one request.
    ///
    /// Three outcomes rather than a `Bool`, because the two failures need
    /// opposite treatment: a refusal has to put the row back, and a transport
    /// failure has to keep it.
    enum SendOutcome: Equatable, Sendable {
        case accepted
        case refused
        case unreachable
    }

    /// - Returns: What the server did, or that it never answered.
    @discardableResult
    private func send(_ request: EmailSet, target: ActionTarget) async -> SendOutcome {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(request)
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            // A 200 is not success: Email/set reports per-object refusals in
            // notUpdated, and treating the call's status as the answer is how
            // a rejected change looks like an applied one.
            if let refused = result.notUpdated, refused.isEmpty == false {
                failure = Self.describe(refused)
                logger.error("Rejected: \(String(describing: refused), privacy: .public)")
                return .refused
            }

            if let refused = result.notDestroyed, refused.isEmpty == false {
                failure = Self.describe(refused)
                logger.error("Refused destroy: \(String(describing: refused), privacy: .public)")
                return .refused
            }

            return .accepted
        } catch {
            logger.error("Action failed: \(error, privacy: .public)")

            // A refusal is the server having considered the change; a transport
            // failure is it never having heard of it. Replaying the first loops
            // forever, and discarding the second loses the user's gesture.
            guard ActionFailure.classify(error).isQueueWorthy else {
                failure = Self.describe(error)

                return .refused
            }

            return .unreachable
        }
    }

    /// The sentence for a server that could not be reached at all.
    private static var unreachableMessage: String {
        String(localized: "Couldn't reach the server. Nothing was changed.", bundle: .module)
    }

    /// "Archived — waiting for the server", the middle of Android's three
    /// sentences: this device is right and the server has not caught up.
    private static func queuedMessage(_ message: String) -> String {
        "\(message) — " + String(localized: "waiting for the server", bundle: .module)
    }

    /// What the undo bar says once an action has been taken back.
    private static var putBackMessage: String {
        String(localized: "Put back", bundle: .module)
    }

    /// A thrown error, for the rare refusal that arrives as an exception rather
    /// than in `notUpdated` — an unreadable answer, or a revoked credential.
    private static func describe(_ error: any Error) -> String {
        guard let error = error as? JMAPError else { return unreachableMessage }

        switch error {
        case .notAuthenticated:
            return String(
                localized: "Your app password was revoked or is no longer valid.",
                bundle: .module)
        case .untrustedCertificate:
            return String(
                localized: "That server's certificate no longer matches.", bundle: .module)
        default:
            return String(
                localized: "The server didn't accept that change.", bundle: .module)
        }
    }

    /// Turns a per-object refusal into something a person can act on.
    private static func describe(_ refusals: [EmailID: JSONValue]) -> String {
        let type =
            refusals.values
            .compactMap { $0.objectValue?["type"]?.stringValue }
            .first

        return switch type {
        case "invalidProperties":
            // Almost always one rule: a message must be in at least one
            // mailbox. Archiving hits it when the account has no Archive
            // binding to move to, and removing a label hits it when that label
            // was the last one. Both leave the message nowhere, so the copy
            // names the rule rather than guessing which of the two it was.
            String(
                localized:
                    "A message has to stay in at least one label, and that was the last one.",
                bundle: .module)
        case "forbidden", "accountReadOnly":
            "This account is read-only."
        default:
            "The server didn't accept that change."
        }
    }

    public func dismissFailure() {
        failure = nil
    }

    /// Pulls the thread back so an undone action shows the server's version.
    private func refetch(_ target: ActionTarget) async {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let get = builder.add(
                EmailGet(
                    accountID: target.accountID,
                    ids: .value(target.emailIDs),
                    properties: EmailGet.listRowProperties
                )
            )
            let threads = builder.add(
                ThreadGet(
                    accountID: target.accountID,
                    ids: .reference(get.reference(path: "/list/*/threadId"))
                )
            )

            let results = try await client.send(builder)

            try await store.upsert(
                emails: try results.result(of: get).list,
                threads: try results.result(of: threads).list,
                accountKey: target.accountKey,
                emailState: nil
            )
        } catch {
            logger.error("Could not refetch after undo: \(error, privacy: .public)")
        }
    }

    private func offerUndo(
        _ message: String,
        isQueued: Bool = false,
        _ undo: @escaping @MainActor @Sendable () async -> Void
    ) {
        dismissal?.cancel()
        pending = Undoable(message: message, isQueued: isQueued, undo: undo)

        dismissal = Task { [undoWindow] in
            try? await Task.sleep(for: undoWindow)

            guard Task.isCancelled == false else { return }

            pending = nil
        }
    }
}

/// What an action applies to.
///
/// A whole thread rather than a message: archiving one reply and leaving the
/// rest is not something anyone means, and the list is a list of conversations.
public struct ActionTarget: Hashable, Sendable, Identifiable {
    public var threadID: String
    public var accountKey: String
    public var accountID: AccountID
    public var emailIDs: [EmailID]

    /// Scoped by account: thread ids are unique only within one.
    public var id: String { "\(accountKey)#\(threadID)" }

    public init(threadID: String, accountKey: String, accountID: AccountID, emailIDs: [EmailID]) {
        self.threadID = threadID
        self.accountKey = accountKey
        self.accountID = accountID
        self.emailIDs = emailIDs
    }
}
