# What's left

Written at the end of the parity programme, for whoever picks this up — likely me,
with no memory of any of it. Ordered by what I would do next, not by size.

Current state: **991 tests green** (from 337), iOS builds clean on iPhone and
iPad, `swift format lint --strict` silent across the tree, catalogues at 453/453
and 115/115 keys with en/de in exact parity. **Nothing is committed** — all of it
is in the working tree.

The app pairs, syncs, reads, writes, sends, schedules, searches, snoozes,
categorises, notifies, themes itself from the server, and now has a calendar. It
went from 171 Swift files / ~30k lines to **300 files / ~65k lines**; plMail for
Android is 357 Kotlin files / ~81k lines.

**Since superseded in part:** Android moved on after 2026-08-25; the new gap and plan are in [parity/ANDROID-CATCHUP-2026-11.md](parity/ANDROID-CATCHUP-2026-11.md).

The gap analysis it was all built from is in [parity/](parity/) — six audit
documents, a plan, and [parity/WIRING-TODO.md](parity/WIRING-TODO.md), which is
the ledger of every seam between agents and the honest record of what was handed
back rather than finished.

---

## The thing to do before believing any of this

**Almost none of it has run against a live server.** The seeded test stack was
down throughout, so the work was verified against fakes, captured fixtures, a
hand-seeded cache and — in the best cases — a throwaway JMAP server built in a
scratch directory. Tests being green means the logic holds. It does **not** mean
pairing, syncing and sending work end to end.

Specifically **verified by construction, not demonstration**: the ⌘ menu bar,
multi-window, Spotlight, Handoff, drag and drop, the calendar widget, and every
notification path. One agent found a **launch-terminating crash** in the menu bar
only because it ran the app — iPadOS installs its own ⌘⌃S for a
`NavigationSplitView`, and a duplicate makes `UIKitMainMenuController.buildMenu`
throw. That is the argument for doing a real device pass before trusting the list
above.

---

## Blocked on you, not on work

**Push notifications.** The client half is built. What is missing is an APNs key
(paid Apple account) **and** a sender on the plMail side. The good news:
`PushSenderRegistry` is built from an iterable of tagged senders and
`PushDispatcher` never names one, so an APNs sender is one enum case, one class
and one create-shape — the dispatcher, delivery log and verification handshake
come free. Note the client previously declared an invented `…:apns` URN in
`using`, which would have made the server refuse **every** request with
`unknownCapability`; that is fixed, and a test now scans the package to assert
every declared capability is declarable.

**The widget's data, and a share extension.** Both need an App Group, and the
build resolves to the deliberately empty `plMail-free.entitlements`. Do not build
a share extension before that: in the Simulator a group container resolves
*without* the entitlement, so it would look like it worked here and silently drop
every file on a device. First step when a paid team exists: create
`App/Config/Signing.xcconfig` with a `DEVELOPMENT_TEAM`, switch both entitlement
variables to the paid files, confirm `SharedMailStore.isShared` is true **on a
device**, and only then add the target.

**The app has no icon.** `App/Assets.xcassets/AppIcon.appiconset` exists and is
empty; it was added only because `xcodebuild` fails without it.

---

## Known gaps, roughly in order

**The README overstates a limitation that is gone.** `README.md:21` says a
scheduled message "goes out at the first check after the time you chose". That is
now true only of the *fallback*. The default path is a server-held `HOLDUNTIL` and
the mail leaves on time with the phone flat on a table. The in-app strings are
already conditional; only the README is stale. Left alone deliberately — product
copy is the maintainer's call.

**The calendar's system integration is half-wired.** App Intents, Spotlight
continuation and a multi-window scene all need files in `App/`; the routers and
roots are ready and named in the wiring ledger.

**Two calendar wire gaps.** `CalendarEventGet.occurrenceProperties` omits
`calendarId`, which the UID collapse needs — `CalendarStore` appends it locally.
`StoredCalendarOccurrence` has no zone column, so an occurrence's zone is derived
series-first; right except for a `recurrenceOverrides` that patches `timeZone`.

**`AccountOrder` is read by one screen** when it should also decide the composer's
default account and where a new label is created.

**`ifInState` is plumbed through `DraftUpdate` and never passed**, because nothing
hands the composer the account's `emailState`. Two devices editing one draft still
clobber each other.

**Invitations are invisible, not merely unanswerable.** RSVP is what materialises
occurrence rows, so an unanswered invitation is absent from `CalendarEvent/query`
entirely. Answering it over JMAP is the **top** server-side ask — until then the
calendar is silently incomplete rather than visibly so.

---

## Traps that cost real time to rediscover

**The `pl_mail` checkout is stale.** Its working tree sits at `71d5474`
(2026-07-31) and has no calendar code and an older filter compiler. The real
server is `origin/main`. **Four separate agents drew a wrong conclusion from it**,
two of which would have changed a design — including "the server has no
`futureRelease`", which is what the README's apology was built on. Read the server
with `cd pl_mail && git show origin/main:<path>`, and `cd` first: the shell's
working directory resets between calls and a bare `git show origin/main:…`
resolves against the wrong repository and returns plausible, wrong output.

**Never run a formatting or sorting pass over a `.strings` file.** One agent did.
It orphaned every multi-line comment, broke plist parsing, and failed the whole
suite for everybody. Two agents restored the files independently. Add keys in
place — and check whether a key already exists first, because generic words like
`Cancel` and `Save` always do.

**`SwiftData cannot type-check `body == nil` inside `#Predicate`.**
`messagesWithoutBody` uses `modelContext.enumerate` with an early-exit sentinel.
Do not "simplify" it back.

**A patch type that cannot say "explicitly null" is a bug waiting to happen.**
`ThreadSet.Patch` originally could not distinguish "not mentioned" from "null", so
reporting a display would have sent `snoozedUntil: null` and **woken every snoozed
conversation the list drew**. There is a test for it now. The same distinction
matters for identity signatures and mailbox colours.
