import Foundation
import OSLog

/// The handful of numbers a widget or an intent needs, in a place another
/// process can read.
///
/// **Why not just read the database.** The store is SwiftData in the app's own
/// container, and a widget runs in a different process with a different
/// sandbox. Pointing both at one SQLite file means coordinating writes across
/// processes for the sake of two integers, and a widget that takes a lock the
/// app then waits on is a widget that hangs someone's home screen. A few
/// values in shared defaults are the right size for the job.
///
/// **Why it records when it was written.** A widget shows whatever it was last
/// given, and the system decides when to refresh it. A count with no timestamp
/// invites a widget that says "3 unread" for an hour after you have read them
/// all, with no way to tell. Anything reading this can decide for itself
/// whether the number is too old to show.
public struct SharedMailState: Codable, Equatable, Sendable {
    public var unreadCount: Int
    public var totalCount: Int
    /// The newest sender and subject, for a widget with room for one line.
    /// Deliberately optional: an empty inbox is a normal state, not an error.
    public var latestSender: String?
    public var latestSubject: String?
    public var updatedAt: Date

    public init(
        unreadCount: Int = 0,
        totalCount: Int = 0,
        latestSender: String? = nil,
        latestSubject: String? = nil,
        updatedAt: Date = .now
    ) {
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.latestSender = latestSender
        self.latestSubject = latestSubject
        self.updatedAt = updatedAt
    }
}

/// Reads and writes ``SharedMailState`` through the app group.
public enum SharedMailStore {
    /// Must match the App Groups entitlement in both the app and the widget.
    public static let suiteName = "group.de.pluetzner.plmail"

    private static let key = "sharedMailState"
    private static let logger = Logger(subsystem: "de.plmail", category: "shared")

    /// Falls back to standard defaults when the group is unavailable — which
    /// happens on a build without the entitlement. The app then still works
    /// and only the widget goes stale, rather than the whole thing crashing
    /// over a provisioning detail.
    nonisolated(unsafe) private static let defaults =
        UserDefaults(suiteName: suiteName) ?? .standard

    public static func write(_ state: SharedMailState) {
        guard let data = try? JSONEncoder().encode(state) else { return }

        defaults.set(data, forKey: key)
    }

    public static func read() -> SharedMailState? {
        guard let data = defaults.data(forKey: key) else { return nil }

        return try? JSONDecoder().decode(SharedMailState.self, from: data)
    }

    /// True when the group is actually shared, rather than silently falling
    /// back to this process's own defaults. Worth surfacing in diagnostics:
    /// the symptom otherwise is a widget that never updates and no error
    /// anywhere.
    public static var isShared: Bool {
        UserDefaults(suiteName: suiteName) != nil
    }
}

/// What the unread-count intent reads.
@MainActor
public final class UnreadCountReader {
    public static let shared = UnreadCountReader()

    private init() {}

    public func current() -> Int {
        SharedMailStore.read()?.unreadCount ?? 0
    }
}
