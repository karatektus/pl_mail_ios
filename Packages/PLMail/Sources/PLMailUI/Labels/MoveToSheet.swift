#if os(iOS)

public import PLMailCore

import Foundation
import JMAPKit
import SwiftUI

/// "Move to": one destination, one tap.
///
/// Unlike ``LabelPickerView`` this is not a checklist — a move has exactly one
/// place to go, so there is nothing to tick and the sheet closes on the tap.
/// The server carries the move out (``MailActions/move(_:to:from:named:)``).
///
/// Leads with the three places mail was last moved to in this account, because
/// filing is repetitive: the label you used a minute ago is the likeliest one.
/// Past eight labels a filter is offered, as on Android.
struct MoveToSheet: View {
    let targets: [ActionTarget]
    /// The mailbox the list on screen shows, or nil for a list without one.
    let view: MailboxID?
    let sync: MailSyncService
    let actions: MailActions
    /// Called once a destination is chosen, before the sheet closes — so a
    /// reader can close behind it, the conversation having left its list.
    var onMoved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var accountKey: String? { targets.first?.accountKey }

    var body: some View {
        NavigationStack {
            List {
                if recent.isEmpty == false && query.isEmpty {
                    Section {
                        ForEach(recent) { row(for: $0) }
                    } header: {
                        Text(.ui("Recent"))
                    }
                }

                Section {
                    ForEach(filtered) { row(for: $0) }
                }
            }
            .navigationTitle(.ui("Move to"))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(FilterIfLong(isLong: destinations.count > 8, query: $query))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }
            }
        }
    }

    private func row(for mailbox: MailboxSnapshot) -> some View {
        Button {
            move(to: mailbox)
        } label: {
            Label(mailbox.name, systemImage: Self.symbol(for: mailbox.role))
        }
        .disabled(mailbox.mailboxID == view)
    }

    private func move(to mailbox: MailboxSnapshot) {
        if let accountKey { RecentMoves.record(mailbox.mailboxID, accountKey: accountKey) }

        let targets = targets
        let view = view

        Task { await actions.move(targets, to: mailbox.mailboxID, from: view, named: mailbox.name) }
        onMoved()
        dismiss()
    }

    /// The server takes the user's own labels, the Inbox, Spam and Trash —
    /// and refuses Sent, Drafts and Archive with `invalidProperties`, so they
    /// are not offered at all.
    private var destinations: [MailboxSnapshot] {
        let allowedRoles: [MailboxRole] = [.inbox, .junk, .trash]

        let mine = sync.mailboxes.filter { $0.accountKey == accountKey }
        let roles = allowedRoles.compactMap { role in mine.first { $0.role == role } }
        let labels =
            mine
            .filter { $0.role == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return roles + labels
    }

    private var filtered: [MailboxSnapshot] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard trimmed.isEmpty == false else { return destinations }

        return destinations.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var recent: [MailboxSnapshot] {
        guard let accountKey else { return [] }

        let all = destinations

        return RecentMoves.read(accountKey: accountKey).compactMap { id in
            all.first { $0.mailboxID == id }
        }
    }

    private static func symbol(for role: MailboxRole?) -> String {
        switch role {
        case .inbox: "tray"
        case .junk: "exclamationmark.shield"
        case .trash: "trash"
        default: "tag"
        }
    }
}

/// Adds the search field only when the list is long enough to need one.
private struct FilterIfLong: ViewModifier {
    let isLong: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if isLong {
            content.searchable(text: $query, prompt: Text(.ui("Filter labels")))
        } else {
            content
        }
    }
}

/// The last three places mail was moved to, per account.
///
/// In `UserDefaults` rather than the store, whose rule is that everything in
/// it can be deleted and re-synced: the server never knew this, so it could
/// not be rebuilt.
enum RecentMoves {
    private static let limit = 3

    private static func key(_ accountKey: String) -> String {
        "recentMoves.\(accountKey)"
    }

    static func read(accountKey: String) -> [MailboxID] {
        (UserDefaults.standard.stringArray(forKey: key(accountKey)) ?? []).map { MailboxID($0) }
    }

    static func record(_ mailbox: MailboxID, accountKey: String) {
        var ids = read(accountKey: accountKey).filter { $0 != mailbox }
        ids.insert(mailbox, at: 0)
        UserDefaults.standard.set(
            Array(ids.prefix(limit)).map(\.rawValue), forKey: key(accountKey))
    }
}

#endif
