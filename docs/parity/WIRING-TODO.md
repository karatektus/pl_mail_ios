# Cross-agent wiring left over

Agents own disjoint file sets so they can work in one tree at once. That works,
but it leaves seams: an agent builds an API and stops at the call site because the
call site belongs to somebody else. **Every item here is a feature that is built
but not reachable**, which is worse than one that is absent, because the tests pass
and the screen is wrong. Clear this list before believing any wave is done.

---

## From the search agent (Wave 2C, operators) — needs `Sync/MailSyncService.swift`

**`label:` currently returns nothing, deliberately.** The agent made the legacy
`filter(for:mailboxID:)` refuse a query carrying `label:` rather than compile an
under-narrowed filter that would page a whole mailbox and merely look as though
search had ignored the operator. That is the right call and it is also a trap:
until the call site moves, the operator is dead.

1. ~~**`pagerFor`** must ask for a `SearchScope`~~ — **done** (Wave 2A). Both
   `pager(for:account:)` and `loadSnippets` now compile through
   `SearchQueryCompiler.scope(for:mailboxes:)`, so `label:` narrows rather than
   returning nothing.
2. ~~**`loadSnippets` must batch**~~ — **done** (Wave 2A). It loops
   `SearchSnippetBatch.batches(ids)` and merges, so highlighting survives past
   the server's 500-id cap.
3. **Gap A9 — the Core half is done, the view half is not.**
   `MailSyncService.highlights` is now `[String: SearchHighlight]` with separate
   `subject` and `body` fields, and `MailSyncService.snippets` is a computed
   body-only view of it, so a subject match is no longer drawn in the
   body-snippet slot. **Owed:** `PLMailUI/List/ThreadListView.swift:297` and
   `ThreadRowView.snippetLine` should read `sync.highlights` and draw a
   highlighted *subject* in the subject line, rather than reading the
   compatibility `snippets` dictionary. Until then a subject-only match simply
   shows the row's stored preview, which is honest but loses the highlight.

---

## Standing rule for whoever picks these up

Do not treat a wiring item as a small mechanical edit. Each one is the point where
two agents' assumptions meet, and the assumptions are written down in different
documents. Read both sides before changing the seam.

---

## From the reader agent (Wave 6, pulled forward)

Gaps 5, 6 and 7 are complete and reachable. Gap 9 is **half** done and gap 10 is
built but **never called** — nothing runs the prefetcher today.

1. ~~**`Store/SyncStore.swift`** — `messagesWithoutBody(accountKey:limit:)`~~ —
   **done** (Wave 2A). Walked in batches rather than filtered in a `#Predicate`:
   SwiftData cannot compile `body == nil` against a to-one relationship.
2. ~~**`Store/SyncStore.swift`** — a write recording *"this message has no
   body"*~~ — **done** (Wave 2A): `recordMissingBody(emailIDs:accountKey:)`
   writes the empty body row, and never over a body that is already there.
3. **`App/AppModel.swift`** — construct `BodyPrefetcher` and call `run(accounts:)`
   after `sync.refreshInBackground()`, wiring `hydrate` to `EmailGet` +
   `storeReaderContent`, and call `cancel()` from the `BGAppRefreshTask`
   expiration handler. **Foreground paths must not call it** — this audience runs
   the server on a Raspberry Pi with a single PHP worker pool.
4. **`Sync/MailActions.swift`** — both halves of gap 9 are **done** (Wave 2A).
   `undoWindow` is a `public var`, and an undo now re-offers its own inverse so
   an undo is itself undoable. **Owed in the shell:** nothing assigns
   `UndoWindow.current()` to it yet — `PLMailUI/MailView.swift:76` builds
   `MailActions` and is the place to do it.

---

## From the calendar wire agent (Phase 0)

The wire layer is complete and tested, but two types it must eventually rely on
live in files it did not own. **Phase 1 cannot discover the calendar account
without the first one.**

1. **`JMAPKit/Protocol/Session.swift`** — `Session.Capabilities` decodes only
   core/push/apns and `SessionAccount.AccountCapabilities` only `mail`, so §1.1's
   discovery rule (*the single account whose `accountCapabilities` carry the
   calendars URN*) cannot be expressed against `Session` at all. The rule is proven
   against the captured session JSON decoded as `JSONValue` instead, and the typed
   path is unwritten. Needs `calendars` on **both**, plus `maxEventsInGet`,
   `maxEventsInSet`, `mayCreateCalendar`, and an **opaque** `materialisedHorizon`
   (its values are PHP relative-date expressions like `"+2 years"` — nothing in the
   client may parse them).
2. **`JMAPKit/Protocol/JMAPError.swift`** — `MethodErrorType` has no
   `cannotCalculateOccurrences` case. It arrives correctly as
   `.other("cannotCalculateOccurrences")`, and the wire agent added a named
   `static let` in its own file so callers compare against a symbol rather than a
   retyped string literal. Promote it to a real case when that file is free.

---

## From the iPad agent (Wave 5B) — P2–P7 landed

Items 1–5 are **done** (Wave 5C). Item 6 stands.

1. ~~**`App/plMailApp.swift` — the real ⌘ menu bar.**~~ — **done**. The
   `Commands` struct is `MailCommands` in `PLMailUI/MailView.swift` rather than
   in `App/`, because every title has to go through `Localization.ui(_:)` and a
   `Text` written in the app target resolves against `Bundle.main` and ships the
   English literal. It is attached with one line on the primary `WindowGroup`.
   **No item implements an action**: each calls a closure published by the view
   that owns the on-screen control, through `FocusedValues.mailShellCommands`
   and `.mailMessageCommands`.
2. ~~**`App/plMailApp.swift` — P6 multi-window.**~~ — **done**, but not with
   the types this list named. `ThreadRef` is not `Codable` and
   `ComposeModel.Kind` carries a `MessageSnapshot`; a scene value is persisted
   and handed back after a relaunch, so both would restore stale. The groups
   take `ThreadWindowValue` and `ComposeWindowValue` — ids only — which resolve
   against the cache when the window opens.
3. ~~**`App/Info.plist`** — `UTExportedTypeDeclarations` for
   `de.plmail.threads`~~ — **done**, conforming to `public.data` and
   `public.content`.
4. ~~**P7 Spotlight and Handoff**~~ — **done**, and in `App/` rather than
   `PLMailCore/Store/*`: `App/MailSpotlightIndex.swift` indexes the unified
   inbox from the cache after every completed sync, incrementally against a
   high-water record, never as a re-scan and never as a reason to fetch.
   Handoff is two ids on an `NSUserActivity` from `ThreadReaderView`. Both come
   back in through the new `IntentRouter.Request.thread`.
   **Not done:** the `IndexedEntity` promotion of `SearchMailIntent`.
5. ~~**`PLMailUI/Reader/ThreadReaderView.swift:324`** — the 96 pt trailing
   inset~~ — **done**; the reply bar is symmetrical again.
6. **`PLMailUI/Theme/*`** — 5B needs an `accentSoft`-style token for drop
   highlights and the focus stroke. It used `Color.accentColor.opacity(0.20)`,
   matching what `ThreadRowView` already does for open/selected, so it
   re-grounds automatically when the appearance agent lands. **No new colours were
   invented**, which is the outcome the ownership rule was there to get.

**Verified by construction, not by demonstration:** drag and drop compiles and is
wired, but no convincing synthetic drag session was produced in the simulator, and
Slide Over could not be reproduced there at all (it is covered by unit tests over
the breakpoint function instead). Both want a human with a real iPad before anyone
claims they work.

---

## From the notifications agent (Wave 2B)

Local notifications now exist end to end: a background refresh that finds unseen
mail posts one banner per conversation, with Archive, Mark as read and inline
Reply, deduplicated across relaunches. Three seams were left because the files
belong to somebody else.

1. **`PLMailUI/Settings/NotificationsView.swift` — not written, deliberately.**
   Settings views belong to another agent. Everything the screen needs is built
   and tested in `PLMailCore/Notifications/`:
   - `NotificationPreferences.shared` (`@MainActor @Observable`, `UserDefaults`),
     with `isMuted(accountKey:)` / `setMuted(_:accountKey:)`,
     `choice(forScope:)` → `.on` / `.off` / `.unset`, `setEnabled(_:scopeKey:)`
     and `clearChoice(forScope:)`.
   - `NotifyScopes.selectable(in: sync.mailboxes)` → the rows, already sorted, by
     **path** rather than leaf name, already excluding the never-notifiable
     roles, already de-duplicated across accounts.
   - `NotifyScope.isNotifiableByDefault` is what an untouched toggle should show.
     The store is **tri-state on purpose**: a `Toggle` bound straight to a `Bool`
     collapses "switched off" into "never opened this screen", and a label
     created on the web next month must default to off rather than inheriting
     anything.
   - Per doc 04's *The Apple way*: a `Form` of `Toggle`s in the existing
     settings stack, one section per account with the account's mute switch as
     its header row, plus a link to `UIApplication.openSettingsURLString` for the
     system-level permission. **No per-account channels.**

2. ~~**`PLMailCore/Shared/IntentRouter.swift` — `case thread(accountKey:threadID:)`**~~
   — **done** (Wave 5C). The case is there, the responder's `default:` branch
   requests it, and `MailView.performPendingIntent` resolves the ids against the
   cache and selects the conversation. Spotlight and Handoff came in through the
   same case rather than inventing a second route.

3. ~~**`PLMailUI/MailView.swift:89` — `MailActions.undoWindow` flat at six
   seconds**~~ — **done** (Wave 5C), by the second route this item recommended:
   `MailView.init` now takes the `MailActions`, `AppModel` builds it with
   `UndoWindow.current()`, and every window shares it, so two windows share one
   undo stack. Original note follows.

   **`PLMailUI/MailView.swift:89` — `MailActions.undoWindow` is still flat at six
   seconds for the UI's own instance.** `undoWindow` became settable while this
   wave ran and `App/AppModel.swift` now assigns `UndoWindow.current()` to the
   instance it builds for notification actions, but `MailView` constructs its own
   in `init` and the composition root cannot reach it. Either add one line beside
   `_actions = State(wrappedValue:)`, or change the initialiser to take the
   `MailActions` from the shell. The second is the better shape and is a
   signature change, so it wants the view's owner rather than this agent.

**Also fixed in passing:** `App/Assets.xcassets` arrived from another wave with an
`AccentColor` and no `AppIcon`, which broke `xcodebuild` outright — the project has
carried `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` since before there was a
catalogue for it to look in. An empty `AppIcon.appiconset` was added to unblock the
build. **It has no image in it**; whoever is drawing the icon should fill it.

---

## From the offline-durability agent (Wave 2A) — needs `PLMailUI/*`

Gaps 1, 2, 8, 11 and 12 are built and reachable from Core. The queue drains, the
projection runs on every delta write, and the offline state is a value on
`MailSyncService`. What is missing is the half that is drawn.

1. **The offline banner.** `MailSyncService.offlineState` is a four-case
   `OfflineState` carrying its own localised sentence, the queued count and
   `isRetryable`. `ThreadListView.degradedSection` still reads
   `degradedAccounts` directly, so the three cases Android distinguishes —
   device offline, whole server silent, one account down — are still drawn as
   one. Nothing shows the queued count.
2. **Retry.** `MailSyncService.retry(accountKey:)` re-syncs one account and
   leaves the others alone. No button calls it.
3. **The queued undo wording.** `MailActions.Undoable.isQueued` is the middle of
   Android's three sentences ("Archived — waiting for the server"). The message
   is already phrased for it; `UndoToast` may want to style it differently from
   an applied action.
4. **Bulk snooze.** `MailActions.BulkAction.snooze(Date?)` exists and undoes to
   each conversation's own previous time. The selection bar offers
   Archive/Labels/Read/Star/Trash and no Snooze.
5. **The action queue is claimed, not injected.** `ActionQueue.shared(serverID:)`
   sets `ActionQueue.current` when `MailSyncService` is built, and `MailActions`
   picks it up from there, because the view that constructs `MailActions` is
   handed a client and a store and no server id. If `MailView.swift:76` ever
   gains the server id, pass the queue explicitly and the global can go.

---

## From the notifications agent (Wave 2B)

1. **`PLMailUI/Settings/NotificationsView.swift`** — the model is complete and
   tested; the screen is not written. **A `Toggle` bound to a plain `Bool`
   destroys the tri-state** (`on`/`off`/`unset`), which is what lets a label
   created on the web next month default to off rather than silently inheriting
   a yes.
2. **`App/Assets.xcassets/AppIcon.appiconset` is empty.** It exists only to
   unblock `xcodebuild`, which fails without it because the project has carried
   `ASSETCATALOG_COMPILER_APPICON_NAME` since before a catalogue existed. **The
   app currently has no icon.** Somebody has to draw one.

## From the drafts agent (Wave 4A) — including a live bug in shipped code

1. **`JMAPKit/Methods/EmailSubmission.swift` — `EmailUpdateDraft` is broken, and
   has been.** Its `Patch` copies `from` out of the draft, but `from` is **not**
   in `EmailPatchApplier::DRAFT_PROPERTIES` on `origin/main` (`subject, to, cc,
   bcc, textBody, htmlBody, bodyValues, inReplyTo, references, attachments`).
   An `Email/set update` naming it throws `invalidPatch`, which
   `EmailSetMethod::applyUpdates()` catches per object into `notUpdated` — so
   **nothing** is applied, the body included. Sending an edited draft has been
   failing outright. *Verified independently against `origin/main`.*
   4A worked around it with its own `DraftUpdate` in `PLMailCore/Compose/`.
   **The right home for that type is `JMAPKit/Methods/`, and `EmailUpdateDraft`
   should be deleted — it now has no callers.**
2. **`Store/Snapshots.swift` (`MessageSnapshot`) has no `bcc`, `sentAt` or
   `replyTo`**, and `SchemaV1` does not store `bcc`/`replyTo`. Three consequences
   were routed around rather than fixed: draft loading bypasses the store cache
   entirely (an extra `Email/get` on every reopen); the quote attribution uses
   `receivedAt` rather than `sentAt`; and **reply does not prefer `Reply-To` over
   `From`**. `ReplyDrafting.replyRecipients(answering:…)` takes the address list
   as a parameter precisely so that last one is a one-line change once the
   snapshot carries it.
3. **`ifInState` is plumbed through `DraftUpdate` but never passed**, because
   nothing hands the composer the account's `emailState`. Two devices editing one
   draft still clobber each other.
4. **`Identity/get` → `htmlSignature` is not persisted**, so signatures remain
   plain-text-appended. Wave 4B territory.

---

## From the labels agent (Wave 2C)

**`Store/SyncStore.swift` never persists the colour** — Wave 1 added
`StoredMailbox.color` and `MailboxSnapshot.color` and nothing fills them, so every
label reads as "no colour". Two lines. *(Assigned to the adoption agent.)*

**Not shipped, and worth doing:** recolouring a **system** label. The server allows
it (`MailboxSetMethod`'s update arm is deliberately not gated by `assertMutable`),
but iOS's only route in is an edit sheet that also renames, so it is gated on
`mayRename`. It wants a colour-only affordance for `mayRename == false` rows.

**Two places the audit was wrong and the server won**, recorded so nobody
"restores" them: a create reads colour as `$properties['color'] ?? null`, so absent
and null are the same request and `Creation.color` is a plain optional — only
`Patch.color` needs the double-optional. And colour does **not** require
`mayRename`.

## From the sync agent (Wave 2A)

- **Gap A9's view half** — `MailSyncService.highlights` is now
  `[String: SearchHighlight]` with separate `subject`/`body`; `snippets` remains a
  body-only computed view, so a subject match is no longer drawn in the body slot
  but the subject highlight is not drawn at all. *(Assigned to the adoption agent.)*
- Nothing draws `offlineState`, the queued count, a Retry button, or bulk snooze.
  *(Assigned to the adoption agent.)*
- **`SwiftData cannot type-check `body == nil` inside `#Predicate`.**
  `messagesWithoutBody` uses `modelContext.enumerate` with an early-exit sentinel
  instead. Worth knowing before anyone "simplifies" it back.

## From the calendar agent (phases 1–2)

The feature is complete and tested but **had no entry point**; the `MailView`
change was handed to the app-shell agent. Remaining, for whoever owns the file:

1. **`JMAPKit`: `CalendarEventGet.occurrenceProperties` omits `calendarId`**,
   which the UID collapse cannot work without — *two rows on one calendar are two
   meetings* is one of the five merge facts. `CalendarStore` appends it locally;
   fold it back into JMAPKit.
2. **`StoredCalendarOccurrence` has no zone column**, though the occurrence get
   asks for `timeZone`. The zone is derived from the series row, falling back to
   the calendar's — correct except for the rare `recurrenceOverrides` that patches
   `timeZone`. `CalendarOccurrenceSnapshot` also lacks `dayKey` (harmless).
3. **`SyncStore.deleteEverything(forAccountKey:)` does not delete calendar rows**
   (the full `deleteEverything()` does, via `SchemaV1.models`). If the calendar
   account is disconnected from the session, orphans remain.
   `CalendarStore.deleteCalendarData(accountKey:)` exists for that call site.

**Doc 03 correction:** §2.3 says all-day *and multi-day* clusters never enter the
lane algorithm, but the Phase 2 checkpoint requires a multi-day event to clip with
continues-before/continues-after affordances — which would be dead code under
§2.3. The checkpoint won: all-day goes to the band, and a *timed* event crossing
midnight is clipped into each day's column and flagged. Both directions tested.

---

## From the appearance agent (Wave 5A) — the largest adoption list

The token layer, the `Appearance/get|set` methods and the five derived palettes are
built, tested and lint-clean. `App/Assets.xcassets/AccentColor.colorset` now stops
`Color.accentColor` being system blue. **But almost nothing reads the resolved
theme**, so a *server-set* appearance does not reach the app. Assign these together
— they are one pass, not fourteen.

1. **`Color.accentColor` call sites** — the asset re-tints them all, but none reads
   `theme.accent`, so a server-set accent is inert: `List/ThreadRowView.swift` (×4),
   `Search/SearchFilterChipsView.swift` (×2), `Compose/FormattingBar.swift` (×2),
   `Sidebar/MailboxSidebarView.swift`, `Reader/ThreadReaderView.swift`,
   `List/ThreadListView.swift`, `List/SenderAvatar.swift`,
   `Labels/{LabelPickerView,LabelManagerView,BulkLabelPickerView}.swift`,
   `DragDrop/DropTargetModifier.swift`, `Compose/OutboxView.swift`,
   `Calendar/{MonthGridView,EventChipView}.swift`.
2. **`.snappy(duration:)` literals** should become `Motion` / `\.standardAnimation`:
   `MailView.swift`, `Sidebar/MailboxSidebarView.swift`, `Reader/MessageView.swift`,
   `Reader/ThreadReaderView.swift`, `UndoToast.swift`, `List/SenderAvatar.swift`.
   **`accessibilityReduceMotion` is consulted nowhere outside `Theme/Motion.swift`** —
   that is an accessibility gap, not a polish item.
3. **`App/RootView.swift`** should apply `.environment(\.theme, appearance.theme)`
   and `.resolvedMotion(…)` at the root, and **`App/AppModel.swift`** should own the
   `AppearanceSettings` instance. `SettingsView` currently builds its **own** client
   via `connection.makeClient()` because `MailSyncService.client` is private — a
   second client means a second session fetch and a gate that does not know about
   the other's in-flight requests, which is the exact thing `jmapClient` exists to
   prevent.
4. **`List/ThreadRowView.swift`** should read `theme.previewLines`,
   `theme.showsAvatars` and `theme.unreadEmphasis`; `.mailPane` should read
   `theme.paneCornerRadius`. All resolved, all unread.

**Two shipped colours did not meet their own documented contrast.** Measured with
WCAG 2.1 relative luminance against white: `ActionTint.star` was **4.36:1** and
`.spam` **4.35:1**, both documented as clearing 4.5:1; `AvatarPalette`'s eucalyptus
was 4.49:1. All three nudged one hundredth darker (4.56 / 4.56 / 4.62).
**`AvatarPalette`'s order and count are unchanged**, so no avatar is renumbered and
the pinned hash-index tests still pass. `PaletteContrastTests` now asserts the
property on every value and sweeps all five palettes, so the comment and the colours
cannot drift apart again.

**Catalogue damage, cause identified.** This agent ran the sort script that
scrambled the `PLMailUI` comment blocks and broke plist parsing. It restored both
files and re-inserted the 56 entries that had landed since; the labels agent had
independently rebuilt them too. Both files now parse, both hold 340 keys, en/de
agree exactly — *verified*. **A few comment blocks may now sit beside a different
entry than the one they were written for.** No agent may run a sorting or
reformatting pass over a `.strings` file.

---

## From the sending agent (Wave 4B)

The broken `EmailUpdateDraft` is **deleted**; `DraftUpdate` now lives in
`JMAPKit/Methods/EmailSubmission.swift`, and its regression test asserts the patch
key set is a **subset** of the server's allow-list — so the next property somebody
reaches for is caught too, not just `from`.

1. **`JMAPKit/Protocol/Session.swift` has no submission account capabilities**, so
   `maxDelayedSend` is unreadable. 4B deliberately did **not** hardcode the 30-day
   ceiling: it discovers the limit behaviourally from the server's own refusal,
   which is stricter than reading it. But the **date picker cannot bound itself**,
   so a user can choose a time the server will refuse and only find out from an
   Outbox row. Wants `SessionAccount.AccountCapabilities.submission` carrying
   `maxDelayedSend` and `submissionExtensions`.
2. **`JMAPKit/Methods/IdentitySet.swift`'s doc comment is wrong**, and states its
   error as server fact: it says plMail rejects `htmlSignature`. True of the stale
   tree, **false on `origin/main`** — `IdentitySetMethod` accepts `htmlSignature`
   and `textSignature` on create and update, `htmlSignature` wins when both are
   sent, and an explicitly empty `htmlSignature` is a distinct stored statement
   ("signs with nothing") from omitting it ("inherit the account's").
   `PLMailUI/Settings/IdentitiesView`'s copy telling the user signatures cannot be
   edited is wrong for the same reason. Writable signatures also need
   `htmlSignature` persisted in `SchemaV1`/`SyncStore`/`IdentitySnapshot`.

**A design decision worth not undoing:** `Contact/autocomplete` declares
`urn:ietf:params:jmap:mail`, **not** a contacts URN. `JmapProcessor::assertCapabilities()`
only checks that URNs in `using` are *supported*; it does not gate dispatch on a
method's capability. Declaring a contacts URN would buy nothing and would fail the
**entire request** with `unknownCapability` against an older instance — taking the
message list down along with the type-ahead.

---

## For the maintainer: the README now overstates a limitation

`README.md:21` says a scheduled message "goes out at the first check after the time
you chose — the app has to be open or woken by the system". That is now true only
of the **fallback** path. The default is a server-held `HOLDUNTIL`: the mail leaves
on time with the phone flat on a table. The in-app strings are already conditional
(`SendLaterSheet.caveat` before sending, `deviceHeldCaveat` only for genuinely
device-held Outbox rows), so only the README is stale. **Left unchanged
deliberately — product copy is the maintainer's call, not an agent's.**

---

## From the adoption agent — two bugs it worked around rather than fixed

1. **`MailSyncService.queuedActionCount` is never incremented on enqueue** — only
   by `drainQueuedActions()` / `refreshQueuedCount()`. The offline banner therefore
   read **0 immediately after queueing a change**, which is the one moment the
   count matters. The view takes `max(offline.queued, actions.queuedCount)`, which
   is never lower than the truth, but the real fix is in `Sync/MailSyncService.swift`.
2. **`OfflineState` reports `.current` when the *session* fetch fails.**
   `degradedAccounts` is only ever filled by an account that got as far as syncing,
   so a whole-server outage produces no retryable state at all. The banner falls
   back to `status == .failed` to get its Retry button; `offlineState` should
   arguably return `.wholeServer` there.

**Calendar entry point is now live**: the sidebar row landed, `MailView` passes
`calendar:`/`openCalendar:`, and the duplicate toolbar button was removed — the
sidebar is the root column on compact and permanently visible on iPad, so a toolbar
button was a second control for one destination, and two controls for one place is
how they drift apart. *(Done by the coordinator.)*

**Not demonstrated, only compiled:** the 1-chip narrow budget (`< 400pt` — both
simulators measured wider, so it rests on `LabelChipBudget.slots(paneWidth: 390) == 1`)
and the search-highlight subject rendering (needs a live server for
`SearchSnippet/get`).

---

## From the mailto agent (Wave 4C) — one owed edit in `PLMailUI/MailView.swift`

**A `mailto:` now reaches the composer, and it gets there by riding alongside
`IntentRouter.Request.compose` rather than as a case of its own.**
`MailView.performPendingIntent` switches over `Request` exhaustively and belongs to
another agent, so a sixth case would have stopped the shell compiling. The shell
therefore still sees the `.compose(recipient:subject:)` it already knows, and
`ComposeView` picks the Cc, Bcc and body up from `IntentRouter.mailto`. That works
and it is one channel too many.

1. **Owed — fold the link into the enum.** Add
   `case compose(recipient: String?, subject: String?, mailto: MailtoRequest?)`, or a
   `Request.mailto(MailtoRequest)` case, and delete `IntentRouter.mailto` /
   `takeMailto()` along with the `.onChange(of: IntentRouter.shared.mailto)` in
   `ComposeView`. One channel, one place it is consumed.
2. **Owed — `prefilled` is a two-field tuple.** `MailView.swift:65` holds
   `(recipient: String?, subject: String?)?` and `ComposeView` takes the same shape.
   Widening it to carry Cc, Bcc and a body is what makes item 1 possible.
3. **A live hazard, not introduced here.** `performPendingIntent` sets
   `composing = .new` unconditionally. When a composer is *already* open on a
   `.reply` or `.forward`, that changes the sheet's item, SwiftUI tears the old
   `ComposeView` down and builds a new one, and the old `ComposeModel` goes with it —
   including up to 3 s of typing that the autosave debounce has not yet written.
   Siri's compose intent has been able to do this since it shipped. `ComposeView`
   now defends the `mailto:` route (it asks, saves the draft, and only then re-asks
   the router for a second composer), but the general fix belongs in `MailView`:
   refuse to re-point the sheet at `.new` while one is open, and let the composer
   decide.

**Share Extension: not built, deliberately, and this is the blocker.** The default
build resolves `CODE_SIGN_ENTITLEMENTS = App/plMail-free.entitlements`, which is
empty on purpose — `App/Config/Signing.xcconfig` does not exist in a fresh clone and
`Signing.xcconfig.dist` defaults both the app and the widget to the free files. So
**the App Group `group.de.pluetzner.plmail` is declared in `plMail.entitlements` but is not in
the binary anyone is building**, and a personal team cannot put it there: requesting
App Groups fails signing outright. A Share Extension's only route into the app is
that group container, so an extension added today would hand over nothing.

Worse, it would *look* fine. In the Simulator `UserDefaults(suiteName:)` and the
group container resolve without the entitlement, so a share would appear to work on
the machine it was written on and silently drop every file on a device — which is
the failure `SharedMailStore.isShared` exists to make visible. A text-only
workaround (`NSExtensionContext.open(_:)` with a synthesised `mailto:`) would cover
text and URLs while silently refusing files, and files are the point of share
intake.

**First step when there is a paid team**, in order:

1. Copy `App/Config/Signing.xcconfig.dist` to `Signing.xcconfig`, fill in
   `DEVELOPMENT_TEAM`, and switch `PLMAIL_ENTITLEMENTS` and
   `PLMAIL_WIDGET_ENTITLEMENTS` to the paid files.
2. Confirm on a **device**, not the Simulator, that `SharedMailStore.isShared` is
   true. Until that is true nothing else on this list is testable.
3. Only then add the `com.apple.share-services` target to `project.pbxproj`, with
   `group.de.pluetzner.plmail` in its own entitlements, an `NSExtensionActivationRule`, and
   every constraint from the `SharedAttachments.kt` note in
   [02-compose-send.md](02-compose-send.md) — copy the bytes inside the grant, never
   use a supplied name as a path component, refuse by name rather than truncating.
4. `com.apple.developer.mail-app` — being the system's *default* mail app — is a
   separate, Apple-approved request. The `mailto` URL type shipped in this wave makes
   plMail offerable without it.

---

## From the settings agent (Wave 4C — signatures, notifications, diagnostics)

Doc 04 gaps 6, 7, 9 and 11 are built and reachable, signatures are writable end
to end, and `SessionAccount.AccountCapabilities.submission` exists. Five seams
were left because the call sites belong to other agents.

1. **`PLMailCore/Sync/MailSyncService.swift` — the push log records nothing yet.**
   `PushActivityLog.shared` (in `PLMailCore/Settings/`) is built, tested and
   drawn by `PLMailUI/Settings/PushLogView.swift`, reachable from Diagnostics →
   Push log. What is missing is the **one line** that feeds it:
   `await PushActivityLog.shared.record(change, route: .stream)` as the *first*
   statement of `MailSyncService.handle(_:)`. It must go before the
   "did this token actually move" filter — a `StateChange` that moved nothing is
   still evidence the stream is alive, which is exactly the question the log
   answers. Until that line lands the screen is honest but always empty.
   The `.apns` route case exists and nothing produces it, deliberately: push
   itself is still blocked on an APNs key *and* unwritten server work.

2. **`PLMailUI/Compose/SendLaterSheet` — the date picker can bound itself now.**
   `Session.submissionCapabilities(for:)` returns `maxDelayedSend` and
   `submissionExtensions`, with `latestHold(from:)` giving the picker's upper
   bound directly. **Do not replace the behavioural discovery with it** — the
   refusal is stricter and stays correct when a cached Session is stale. This is
   only so a user cannot *choose* a time the server is going to refuse.
   `allowsDelayedSend` distinguishes an explicit `0` ("this server does not do
   delayed send") from an older server that published nothing, where scheduling
   should still be offered.

3. **`PLMailCore/Compose/*` — signatures are HTML now.**
   `IdentitySnapshot.htmlSignature` is persisted and `hasStoredSignature`
   distinguishes "signs with nothing" from "nothing stored". Wave 4B's per-alias
   swap still appends the flattened `textSignature`; it can use the HTML form
   without re-flattening on every From change. **Empty is not nil** — an address
   that has explicitly said it signs with nothing must not inherit the account's.

4. **`App/AppModel.swift` — the local-notification prompt still never fires.**
   Per doc 04's *The Apple way*, ask after the first successful sync, separately
   from registering for remote notifications. Unchanged by this wave; the
   Notifications screen links to `UIApplication.openSettingsURLString`, which is
   the repair route once it has been asked and denied, not a substitute for
   asking.

5. **`AccountOrder.shared` is read by one screen.** The order is not cosmetic —
   it is meant to decide which account the composer opens on and where a new
   label is created — but only `PLMailUI/Settings/AccountsView` consults it
   today. `PLMailUI/Compose/*` and `PLMailUI/Labels/*` are the other two call
   sites, and both belong to somebody else.

**A doc 04 correction, verified against `origin/main`:** gap note 11 says iOS is
"one line away" from showing the pin. It now shows it, selectable and
monospaced, and the report carries the hex. **Clearing it stays unavailable** —
`ServerTrust`'s fourth branch refuses a changed key permanently, and a Clear
button here would have been a way around that.

**`IdentitySet` was wrong about the server and is fixed.** `IdentitySetMethod`
on `origin/main` accepts `htmlSignature` and `textSignature` on both create and
update; `htmlSignature` wins when both are sent, and an explicitly empty
`htmlSignature` is a stored statement distinct from omitting the key. The patch
type encodes by hand for exactly that reason — Swift's synthesised encoding
drops nil optionals, which would have made "clear this signature" and "leave it
alone" the same request, failing in the direction that looks like it worked.

---

## Closed by the coordinator

- **The push log now records.** `PushActivityLog.shared.record(change, route: .stream)`
  is the first statement of `MailSyncService.handle(_:)`, ahead of the
  "did anything move" filter — a change that moved nothing is still evidence the
  stream is alive, and a log that recorded only consequential changes would look
  dead exactly when somebody is trying to find out whether it is.
- **The calendar sidebar row is wired.** `MailView` passes `calendar:`/`openCalendar:`;
  the duplicate toolbar button was removed.

## A suspected flake, not yet explained

The settings agent saw `SendHandoverTests` fail on one run and pass on the two
after. I then ran the full suite **five times in a row: 921 tests green every
time**, so it did not reproduce. That is *not* the same as fixed — a
handover test is exactly where a real race would hide, and the send handover is
the one place in the app where a duplicate would mean a message sent twice.
Treat a future failure there as real and reproduce it before dismissing it.

---

## From the calendar agent (phases 4–5)

The iPad treatment and the system integration are built, tested and lint-clean.
`swift test` is **991 tests**, up from 921. Five items need a file this agent
does not own.

**1. Owed, and it is the whole of Phase 4 — `MailView` presents the calendar
inside the sidebar column.** `.navigationDestination(isPresented: $isShowingCalendar)`
sits on the sidebar's content, above
`.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)`, so on a
13-inch iPad the calendar is drawn into a **260pt column**. `CalendarView` now
measures its own width and resolves `MailLayout.resolve(width:isCompactSizeClass:)`
against it, so it degrades correctly there — one pane, dots not chips, no
inspector, no rail — but every wide-canvas affordance is unreachable until the
destination moves. Moving it to the **detail** column, or presenting it as a
`.fullScreenCover`, or giving it its own scene, all light it up with no change
here. Nothing else is owed for it.

**2. App Intents need `App/Intents/` and `App/` cannot be edited from here.**
The consuming half is built: `PLMailCore/Calendar/CalendarIntentRouter.swift`
carries `.show(day)`, `.create(title:day:)` and `.occurrence(accountKey:occurrenceID:)`,
and `CalendarView` acts on all three. What is missing is the three-intent file
beside `MailIntents.swift`, following its rule that an intent **opens** the app.
A `.create` opens a prefilled editor and never saves — `EventEditorView` takes a
`title:` for exactly that.

**3. Spotlight indexes events but a tap has nowhere to land.**
`CalendarSpotlightIndex` is an actor over the **cache** with a high-water record
and static, pure planners, modelled on `MailSpotlightIndex`; `CalendarService`
runs it after a refresh that wrote something, and never otherwise. `RootView`'s
`onContinueUserActivity(CSSearchableItemActionType)` needs a second branch:
`CalendarSpotlightIndex.ids(forUID:)` → `CalendarIntentRouter.shared.request(.occurrence(…))`.
Sign-out should also call `CalendarService.forgetIndexedEvents()`, which clears
both the index and the widget's shared state — an entry left behind leaks the
previous account's calendar.

**4. Multi-window** (doc 03 §5.2's last bullet) needs a scene in `App/`.
`CalendarScreen(service:)` is the ready-made root for one.

**5. The widget's strings are English literals**, matching the existing
`PLMailWidget` exactly. The widget target's `packageProductDependencies` lists
only `PLMailCore`, and `Localization.ui(_:)` lives in `PLMailUI` — so this is a
pre-existing gap, not a new one. Fixing it is either one line in the pbxproj or
a small catalogue in `PLMailCore`.

**Two bugs found by looking at a 13-inch iPad, both fixed here.** Neither was
visible to the compiler or to `swift test`:

- **An offline calendar drew no colours, no calendar names and an empty
  sidebar.** `CalendarService.accountKey` was built from the *session's*
  calendar account id, and a launch with no network has no session — so
  `calendars(accountKey: "")` matched nothing while the occurrence query, which
  treats a nil key as "any account", matched everything. `CalendarStore.storedAccountKey()`
  now reads the key back from the cache. The same path also left
  `availability.isAvailable` false, so a month of cached events was covered by
  "This server does not have a calendar"; the session-failure branch now calls
  `availability.refresh(session: nil)`.
- **A saved Year preference opened on Month and rewrote itself on the way
  past.** Year was offered only above a width threshold, so the picker's `.year`
  tag lived inside a conditional and an `onChange(initial: true)` stood the mode
  down before the first layout pass. Year is now never withdrawn: the year grid
  is an adaptive grid of month tiles, so a narrow container gets two columns
  rather than four.

**Still recorded, still not fixed** (both from phases 1–2, both confirmed still
true): `CalendarEventGet.occurrenceProperties` omits `calendarId`, and
`StoredCalendarOccurrence` has no zone column.

**`SendHandoverTests` reproduced.** "A message the server accepted is never
submitted again" failed twice in about eight full runs on a machine running
three agents and two simulators, and passed on every other run. The failing
line is 258 — `try #require(await outbox.pending().first)` returning nil after
the first drain — and the test enqueues with `sendAfter: .now + 2` seconds. That
reads as a **wall-clock race in the test** rather than a double send: under load
the drain lands after the release time and takes the immediate-send branch, so
the message is no longer pending when the test asks for it. Not proven, and the
suite's own note says to reproduce rather than dismiss — this is the
reproduction.

---

## From the calendar agent (phases 4–5)

**Closed by the coordinator:** the calendar was presented with
`.navigationDestination` on the **sidebar column**, so on a 13-inch iPad the
entire phase-4 board — three columns, standing inspector, rail, year grid — was
drawn into 220–320pt, narrower than a phone. It is now pushed into the sidebar
stack **only on compact** (where the sidebar is the screen) and presented as a
full-screen cover on separated layouts. `CalendarView` carries no
`NavigationStack` of its own so it can be a column, and a cover supplies no back
button, so the cover wraps it in a stack with an explicit **Done** — otherwise
the calendar was a room with no door.

Still open, all needing `App/`:

1. **App Intents for events** need a file in `App/Intents/`. The router and the
   prefilled-editor path are ready.
2. **Spotlight taps** need a branch in `RootView.onContinueUserActivity`, and
   sign-out should call `CalendarService.forgetIndexedEvents()`.
3. **Multi-window** needs a scene; `CalendarScreen(service:)` is the root.
4. **Widget strings are English literals** — matching the shipped `PLMailWidget`
   exactly, because the widget target links only `PLMailCore` while `.ui(_:)`
   lives in `PLMailUI`. Fixing it properly means moving the localisation shim.

**Deliberately skipped, with reasons that should survive:** Live Activities
(nothing pushes, so there is no stream to drive one); EventKit
(`EKEventEditViewController` needs `NSCalendarsWriteOnlyAccessUsageDescription`
and terminates without it — `.ics` export does the same job with no entitlement);
drag-to-move an event (it would move **every** occurrence of a series, and the
this-or-all choice needs a `recurrenceOverrides` patch the thirteen-property
vocabulary cannot express).

---

## The `SendHandoverTests` flake: diagnosed and fixed

It reproduced twice for the calendar agent and once for me. **It was a wall-clock
assumption in the test, not a double send.** The test enqueued with
`sendAfter: .now + 2` seconds and assumed the first drain ran inside that window.
Under load — several agents and two simulators — more than two seconds elapse, the
message becomes genuinely due, the drain correctly **sends** it rather than
holding it, the row is gone, and the `#require` fails for a reason unrelated to
what the test guards. The invariant itself ("a message the server accepted is
never submitted again") passed on every single run.

Now enqueued an hour out, with the release time simulated by the backdated
handover the test already performs rather than by waiting. **Verified with eight
consecutive full-suite runs: 991 tests green every time.**

---

## Closed by the coordinator (second pass)

**`AccountOrder` now decides the composer's account.** `MailView.composeAccount`'s
unified-inbox branch returned `sync.accounts.first`, which is `Session`'s order —
**alphabetical by account name**. So the account a user dragged to the top of the
accounts screen was ignored by every composer opened from the unified list, from a
`mailto:` link and from ⌘N, which is where most messages are written. The
`.mailbox` branch above it is deliberately unchanged: composing inside the Work
mailbox must send as Work whatever the ordering says.

*Correction to this file's own earlier entry:* it named `PLMailUI/Compose/*` as the
call site. That was wrong — `ComposeView` is **handed** an account, it does not
choose one.

## Answered: do not declare `urn:plmail:params:jmap:sync`

Doc 04 concluded iOS should declare it. **That conclusion was wrong**, and the
absence is now documented on `JMAPKit/Protocol/Capability.swift` so it does not get
"fixed" later. Verified on `origin/main`:

- It has **no methods**. `SessionBuilder` publishes backfill progress under the URN
  in each account's `accountCapabilities`, and `using` gates method dispatch only —
  a client reads the identical Session whether it declares the URN or not.
- Against any plMail predating the commit that added `SYNC` to `SUPPORTED`, one
  entry in `using` refuses **every call in the batch** with `unknownCapability`.
  The whole app off the air, in exchange for nothing — the same bug this programme
  already fixed once for the invented `apns` URN.
- iOS does not model backfill progress at all, so there is not even a reader.
