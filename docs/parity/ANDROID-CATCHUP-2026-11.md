# Catching up with Android, November 2026

Written for the next agent (or person) bringing the iOS app level with plMail for Android again.
The first parity programme ended on **2026-08-25** (iOS `c7bbbfa`). Android has shipped
**~38 feature/fix commits since then** (0.0.22 → 0.4.3). None of them are in iOS yet. This is
the gap, in the order to work through it, with the wire shapes and the iOS files to touch.

Read [00-HOUSE-STYLE.md](00-HOUSE-STYLE.md) first. It still holds.

---

## How to get the sources

Android and the server are public, read-only for us:

```bash
git clone --filter=blob:none --shallow-since=2026-08-24 https://github.com/karatektus/pl_mail_android /home/user/karatektus/pl_mail_android
git clone --depth 1 https://github.com/karatektus/pl_mail /home/user/karatektus/pl_mail
```

- `git -C pl_mail_android log --since=2026-08-24` — every commit body is a full design note. Read the
  body of the commit for a feature before porting it; they say *why*, which matters more than the
  Kotlin.
- The server spec is `pl_mail/docs/CLIENT_DEVELOPMENT.md` (main branch, 1748 lines). Line numbers
  below are from 2026-11-05.

## What you can and cannot check from a Linux container

**No Xcode, so PLMailCore and PLMailUI cannot be compiled** (SwiftData, SwiftUI, OSLog). JMAPKit
can: a Swift 6.2 toolchain for Ubuntu 24.04 installs from download.swift.org, and
`scripts/linux-jmapkit-check.sh` mirrors JMAPKit + its tests into a scratch package (dropping
ServerTrust, URLSessionTransport and EventSourceClient, injecting `import FoundationNetworking`)
and runs `swift test`. **159 JMAPKit tests passed** on 2026-11-05 at `c7bbbfa`.

```bash
mkdir -p /opt/swift && cd /opt/swift && curl -sSfL https://download.swift.org/swift-6.2-release/ubuntu2404/swift-6.2-RELEASE/swift-6.2-RELEASE-ubuntu24.04.tar.gz | tar xz
```

```bash
PATH=/opt/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH scripts/linux-jmapkit-check.sh
```

So: put every wire change in JMAPKit with a fixture test, and verify it there. Core/UI changes
written blind must be kept small and checked on a Mac (`swift test --package-path Packages/PLMail`,
then `xcodebuild`) before anyone trusts them.

---

## The gap, in the order to do it

Status column: nothing below has been started in code. The only thing committed in this pass is
this document and the Linux script.

### 1. Move to — `Thread/set moveTo` (Android 9ff096e, 7dcc1f7, 83deaff)

Spec: CLIENT_DEVELOPMENT.md §"Moving: Thread/set moveTo" (~line 911).

```json
["Thread/set", {"accountId": "7", "update": {"812": {"moveTo": {"mailboxId": "17", "fromMailboxId": "42"}}}}, "m0"]
```

- `mailboxId`: a user label, Inbox, Spam or Trash. `fromMailboxId`: the mailbox the list is showing,
  or null/omitted for a list without one (search, Starred, a category tab). **The server decides
  what comes off.** Undo = the same move with the two swapped.
- Old server: `notUpdated[id].type == "invalidProperties"` naming `moveTo` → fall back to an
  `Email/set` attach-target/detach-view patch, and remember per account for the process lifetime.
  Against such a server refuse moves into/out of Trash/Spam out loud.
- **iOS work:**
  - `JMAPKit/Methods/ThreadSet.swift`: add `moveTo: MoveTo?` (struct `{mailboxId, fromMailboxId}`,
    encode `fromMailboxId` as explicit null when nil) and `inboxTab: String?` (needed by §3) to
    `Patch`. Keep the `mentionsSnooze` rule — encode each key only when set. Add
    `ThreadSet.move(_:to:from:accountID:)`. Fixture test in `Tests/JMAPKitTests/RequestEncodingTests.swift`.
  - `PLMailCore/Sync/MailActions.swift`: `func move(_ targets: [ActionTarget], to: MailboxID, from: MailboxID?, named: String)`.
    Model it on `snooze` (lines ~101–288): it is a `Thread/set`, so it can't use `apply(...)`.
    Local change: `store.removeFromFeeds` for the current list; then `refetch`. Add a `BulkAction.move`.
  - Offline: add `PendingMutation.Kind.moveTo(destination:, from:)` in `Sync/ActionQueue.swift`.
    Mailbox ids are per-account, so store a role-or-`LabelID` enum and resolve at drain time in
    `MailSyncService.send(_ mutation:)` (~line 560), next to the `.snooze` special case. Every
    exhaustive `switch` on `Kind` must gain the case (`MailActions.undoLocally`, `MailSyncService.request(for:)`).
  - UI: a one-tap "Move to" sheet (reuse `PLMailUI/Labels/LabelPickerView.swift` styling): the three
    most recent destinations first (store in UserDefaults per account), a filter field past 8 labels,
    Inbox/Spam/Trash included. Entry points: reader toolbar (`Reader/ThreadReaderView.swift`), the
    selection bar overflow and row context menu (`List/ThreadListView.swift` ~line 1170).
  - `fromMailboxId` comes from the current `FeedID` (`Sync/FeedID.swift`) — the mailbox for a label/
    role feed, nil for unified/search/starred/category.
  - Strings in en + de (and fr, §8).

### 2. Reply from the address the mail was sent to; drafts keep their identity (Android 9bd5eaa, 800a783)

Spec: §"Which identity answers a mail" (~line 1041) and "Say which identity a draft is written
from" (~line 1070).

- `Email/get` property `replyFrom`: a whole Identity or null. Only returned when asked by name.
  Add it to the property list used for building a reply/forward/reopened draft (not list rows).
  `JMAPKit/Mail/Email.swift` → `replyFrom: Identity?`.
- Compose (`PLMailCore/Compose/ComposeModel.swift`): reply, forward, and reopening a draft default
  the From to `replyFrom` (name, address, signature). If its id is not in `Identity/get`
  (catch-all address), add it to the From picker for this message only; never persist it.
  Reply-all leaves that address out of Cc.
- Drafts: when the account's `urn:ietf:params:jmap:mail` capability has `"draftIdentity": true`
  (`JMAPKit/Protocol/Session.swift`), send `identityId` on every draft `Email/set` create and update
  (`Compose/DraftWriting*` / `EmailSet` draft builders), and count a From change as an unsaved
  change. Without the flag, never send it (old servers refuse the whole patch with `invalidPatch`).
- Also from Android d70d192: To on a reply is Reply-To/From **unfiltered** (don't strike the
  sender because it is one of the user's addresses on another account; "own" = the answering
  account only); a reply to mail the user sent goes to that mail's recipients; Reply answers the
  newest non-draft message; an untouched reply/forward is not autosaved (compare against what it
  opened as). Check iOS `ReplyDrafting` against each and add tests in `ReplyDraftingTests.swift`.

### 3. The user's own inbox tabs, and "one list" (Android f9cddf0, 49e0ce4, b00d165)

Spec: §"Inbox tabs (urn:plmail:params:jmap:inboxtabs)" (~line 216) and the `inboxTabs` boolean
on the appearance capability (~line 210).

- New capability `urn:plmail:params:jmap:inboxtabs` in `JMAPKit/Protocol/Capability.swift` (and the
  declarable-capability test).
- `InboxTab/get` → `{id, name, builtIn, isEnabled, sortOrder}`; `InboxTab/changes`; push
  `StateChange` carries an `InboxTab` type. New `JMAPKit/Methods/InboxTabMethods.swift` + fixtures.
- `Thread.inboxTab` (string key: `primary|social|promotions|updates|forums|c<N>`). Decode on
  `Thread`; store on `StoredThread` (SchemaV1 is a cache — adding a column is fine, wipe-and-resync
  is the migration).
- `Email/query` filter `threadInboxTab: "<key>"` — add to the filter type in `EmailMethods.swift`.
- `Thread/set {"inboxTab": "<key>"}` to move a conversation between tabs (patch field from §1),
  local first, queued offline, undo to each conversation's previous tab.
- iOS today draws the five built-ins from `Thread.category` (`PLMailCore/.../InboxCategory*`,
  `PLMailUI/List/InboxCategoryPicker.swift`). With the capability: draw enabled tabs from
  `InboxTab/get` in `sortOrder`, built-ins with localised names, own tabs by `name` with a generic
  icon, and query by `threadInboxTab`. Without it: unchanged.
- `inboxTabs == false` in the appearance capability (Session): no tabs at all, Primary = the whole
  inbox unfiltered, no category bundles, Move to offers no tabs. Re-page when it changes.
- Notifications: decide a message's tab with the same rule (`inboxTab` against enabled tabs) and
  list own tabs among the notification categories (`PLMailCore/Notifications/`, `Settings/NotificationsView.swift`).
- The "other tabs have new mail" digest (Android 1704b7a): when the bundles above Primary have
  scrolled away, a single bar names which tabs and how many; tapping scrolls back to the bundles.

### 4. Swipe actions you choose, each direction asking or not (Android 83deaff, 185677b)

- iOS already has per-edge choice (`PLMailUI/List/SwipeActions.swift`). Add **snooze** and
  **move** as swipe actions (they open the snooze menu / Move to sheet), and a per-direction
  "Ask before acting" switch (UserDefaults, per device). Defaults: off, except whichever side is
  Trash (migrate as Android did). Settings screen in `PLMailUI/Settings/`.
- A swipe that does not remove the row (read, star) springs back.

### 5. Reader parity (Android 83deaff, 82fd36c, 2911207, 7900fa1, 3a305ec, 6d5ab26, 4316cf6, b9237e5, d70d192)

- **Heading:** star toggle beside the subject (shows state); under it, message count and (multi-
  account) which account; label chips (tap → that label's list, long press/context menu → remove;
  "+" → label sheet); "Snoozed until …" with change/wake buttons. Observed, not read once.
  File: `Reader/ThreadReaderView.swift`.
- **Swipe between conversations** in the reader (left = next/older, right = previous), committed
  on release past 20% width, not followed under the finger, and not marking the neighbour read
  until it is opened. iPhone only; on iPad the list is visible.
- **Open at the first unread message**; fetch messages for a conversation never seen on device;
  ignore a stale load that finishes after another conversation was opened.
- **Draft body cache:** a body cached while a message was `$draft` must be invalidated once it
  is no longer a draft (sending keeps the id). Find where iOS caches bodies
  (`PLMailCore/Reader/BodyPrefetcher.swift`, `SyncStore` bodies) — don't prefetch drafts, and drop
  a cached body whose message lost `$draft`.
- **Empty body:** blank/whitespace body ≠ not fetched. Show "This message has no text" and still
  list attachments, instead of an empty card.
- **HTML fitting** (`Reader/MessageRenderStyle+CSS.swift`): invert the cap — every element except
  table cells and replaced elements gets `max-width:100%; box-sizing:border-box`; cap declared
  horizontal padding at 16px; strip `vh/vb/vmin/vmax` (and s/l/d variants) declarations from
  `style` attributes and `<style>` before wrapping (infinite-growth bug). Android commit bodies
  have the measured cases — turn them into tests.
- **Attachments with a Content-ID:** disposition decides; only a part with no disposition falls
  back to `cid != nil` for inline. Check `AttachmentRow`/the part filter.
- **Mail actions must not send `ifInState`** (Android b3ebcd8). Grep `ifInState` in
  `EmailSet.swift`/`MailActions.swift`; drop it for archive/trash/flags/labels.
- Trash/spam/archive from the list must act on **all** of the conversation's messages, asked of
  the server, not just the cached one; trash/spam remove the row from every cached list.
- Sync: remove conversations the server destroyed (`Thread/changes` destroyed); keep the inbox at
  its top while new mail arrives.

### 6. Calendar (Android bbd4fa2, 069a879, c66ae2f, a7d1b21)

- **IETF URN:** when the Session advertises `urn:ietf:params:jmap:calendars`, declare it and speak
  the draft's shape (`calendarIds` map, single `recurrenceRule`, `baseEventId`, recurring from
  `plmail.org:isRecurring`); otherwise keep `urn:plmail:params:jmap:calendars` and translate
  (`calendarId`, `recurrenceRules`, `seriesId`, `isRecurring`) at the edge. iOS:
  `JMAPKit/Protocol/Capability.swift` (comment there says deliberately *not* IETF — now outdated),
  `JMAPKit/Calendar/*`, `Methods/CalendarMethods.swift`, `CalendarEventSet.swift`. Under the IETF URN
  a get is capped by core `maxObjectsInGet`. Ideal for JMAPKit fixture tests on Linux.
- **Deltas:** `Calendar/changes` and `CalendarEvent/changes` exist now, states are real. Ask first,
  re-run the window only if anything changed, and only for windows already fetched in this
  process (and same device zone). `cannotCalculateChanges` → forget the cursor. iOS
  `CalendarMethods.swift` header says no `/changes` exists — outdated.
- **Time zones:** an event with a zone is an instant — show it on the device's clock (time and
  day); all-day/floating untouched. Editor shows device time and writes back in the event's own
  zone. Detail says "08:00–08:30 in UTC. Shown above in your time." Re-read the zone on foreground.

### 7. Compose (Android 9df3cb2, 4ba810f, a331185)

- Pasting `a@x, b@y; "C" <c@z>` into a recipient field makes one token per address
  (`PLMailCore/Compose/RecipientParsing*`, `PLMailUI/Compose/` token field).
- A discarded draft (from composer or reader) leaves the Drafts list immediately: delete the
  message row, recompute the thread's labels, reconcile the feed rows — only after the server
  accepted the move to Trash.
- Drafts inside a conversation get Edit and Delete in their message menu.
- Signature: verify iOS sends the signature and that reopening a draft does not sign twice.

### 8. French (Android 39cc191)

Add `fr.lproj/Localizable.strings` to **both** `PLMailCore/Resources` and `PLMailUI/Resources`,
every key present in en (CatalogueCoverageTests must learn about fr), plus the Widget and
`App/Info.plist` permission strings, and `CFBundleLocalizations`. Terminology from the server's
`translations/messages.fr.yaml`: "vous", "Agenda", "Libellé", "Suivre/Suivis" (star), "Mettre en
attente" (snooze), "Principal / Réseaux sociaux / Promotions / Mises à jour / Forums". No-break
space before `:` `?` `!` and inside « ». **Never run a formatter over a `.strings` file** (see
WHATS-LEFT.md).

### 9. Smaller, or deliberately later

- `popoverAlpha` in `Appearance/get`: decode it (`AppearanceMethods.swift`); nothing draws with it.
- `logoMotif` / `logoPaint` (read-only): iOS could offer them through alternate app icons; low priority.
- Sealed push / calendar reminders (Android f3b2ad9): iOS push is blocked on APNs (WHATS-LEFT.md).
  When unblocked, reminders arrive as `CalendarAlert` payloads.
- **End-to-end encryption (PGP, 5 phases) and S/MIME (2 parts)** — Android 82fd36c/#39–#49. The
  largest item by far and needs a crypto library decision (no OpenPGP in CryptoKit). Do it last,
  as its own programme; read those PR bodies in full first.

---

## Done means

Each item: JMAPKit tests (Linux script or Mac), Core tests in swift-testing per house style, en/de/fr
strings, `swift format lint --strict --recursive App Packages`, and a line here moving it to done.
Then update README's feature list and WHATS-LEFT.md's numbers.
