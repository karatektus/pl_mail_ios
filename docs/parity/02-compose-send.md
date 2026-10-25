# 02 — Compose, send, drafts, outbox

Domain: composing, sending, drafts, outbox, send-later, attachments, share-into-app, `mailto:`,
rich text, recipient autocomplete, identities/From-picker.

Reference client: `pl_mail_android/feature/compose/` + `pl_mail_android/core/data/` +
`pl_mail_android/core/jmap/src/main/kotlin/de/plmail/jmap/mail/`.
Target: `pl_mail_ios/Packages/PLMail/Sources/PLMailCore/Compose/`, `…/PLMailUI/Compose/`.

## Server version note

**Read the server from `origin/main`, not from the working tree.** `pl_mail/`'s checkout sits at
`71d5474` (2026-07-31). The server the Android client is built against — and the one this audit is
written against — is `origin/main`, `132c1bf`, *release: v0.1.9*. The two differ substantially in
exactly this domain: the stale tree has `maxDelayedSend: 0`, no `FUTURERELEASE`, no submission
cancel, no JMAP contacts method, and `Identity/get` returning empty-string signatures as literals.
An earlier draft of this document concluded from the working tree that four of Android's compose
features were "dormant against this server". **All four were wrong.** Everything Android implements
here is real, live server behaviour.

Read-only recipe — do not check out, do not fetch, do not modify `pl_mail/`:

```
cd /Users/karatektus/Documents/plmailstuff/pl_mail
git show origin/main:docs/CLIENT_DEVELOPMENT.md
git show origin/main:src/Jmap/Mail/SubmissionEnvelope.php
git ls-tree -r --name-only origin/main -- src/Jmap/Method
```

Note also that this repo's Bash tool resets the working directory between calls, so a bare `git
show` can silently resolve against `pl_mail_ios` instead. Always `cd` into `pl_mail` in the same
command.

The evidence behind every server claim below:

| Claim | Where |
|---|---|
| `maxDelayedSend` = 2 592 000 s (30 days), `FUTURERELEASE: [HOLDFOR, HOLDUNTIL]` | `src/Jmap/Session/SessionBuilder.php:435` `submissionCapabilities()`; `src/Jmap/Mail/SubmissionEnvelope.php:49` `MAX_HOLD_SECONDS` |
| Hold enforced, not clamped; elapsed hold sends now | `SubmissionEnvelope.php:188`, `:216`; `docs/CLIENT_DEVELOPMENT.md` "Scheduled send" |
| `undoStatus: "canceled"` update; `cannotUnsend`; `notFound` if never submitted | `src/Jmap/Method/Mail/EmailSubmissionSetMethod.php` `applyUpdates()` |
| `EmailSubmission/get` reports `pending`/`canceled`/`final` + real `sendAt` | `EmailSubmissionGetMethod.php:26–45`, `:144–167` |
| `EmailSubmission/changes` exists | `src/Jmap/Method/Mail/EmailSubmissionChangesMethod.php` |
| `identityId` resolved; `forbiddenFrom` for a stale id | `EmailSubmissionSetMethod.php` `applyIdentity()`; `src/Jmap/Mail/IdentityResolver.php` |
| Per-alias HTML signature, `textSignature` derived | `IdentityResolver.php:104–126`; `src/Service/Mail/SignatureProvider.php` |
| `Identity/set` create/update/destroy incl. `htmlSignature`/`textSignature` | `IdentitySetMethod.php:122`, `:195`, `applySignature()` |
| `Contact/autocomplete` under `urn:plmail:params:jmap:contacts` | `src/Jmap/Method/Contact/ContactAutocompleteMethod.php`; `SessionBuilder.php:363` |
| `attachments` works on `Email/set update`, whole-value, all-or-nothing | `src/Jmap/Mail/JmapDraftWriter.php:87` `update()`, `:200` `planAttachments()`; `docs/CLIENT_DEVELOPMENT.md` "Writing: Email/set" |
| `maxSizeUpload` 50 MB, `maxSizeAttachmentsPerEmail` 50 MB, `maxConcurrentUpload` 4 | `SessionBuilder.php:162`, `:186` |
| Signature marker `data-pl-signature`, quote marker `data-quoted="1"` | `SignatureProvider.php:35`, `:96`; `src/Service/Mail/ReplyDraftBuilder.php:225`, `:248` |
| **Both markers are stripped from a saved body** — the allow-list drops `class` and every `data-` attribute; inline `style` survives | `src/Service/Mail/MailBodySanitizer.php:165` `buildSanitizer()`, `:194`; called from `JmapDraftWriter.php:115` and `DraftPersister.php:154` |

## Summary

iOS has a good **send** path and an absent **draft** path, and it is disconnected from both the
operating system and about half of what the server offers.

What iOS does well is real and worth protecting: a persistent on-disk outbox that survives
relaunch, EXIF/GPS stripping on attached photos, a rich-text editor with links and paste
sanitising, an inspectable Outbox screen, App Intents, `BGTaskScheduler` wired to the next due
send, and a single-round-trip create-and-submit via `#draft`.

What is missing falls into three groups:

1. **iOS never writes a draft to the server.** `ComposeModel` (`…/Compose/ComposeModel.swift`) has
   no save path at all — the first and only `Email/set` happens inside `OutboxSender.send(_:)` at
   delivery. Dismissing the composer discards everything typed, silently, with no confirmation.
   Android autosaves to Drafts on a 3 s debounce (`ComposeViewModel.kt:531`). This costs
   cross-device drafts, crash safety, web-UI interop, and the Save Draft idiom every iOS user
   expects from Cancel. It is also the **prerequisite for almost everything else on this list**:
   scheduled send, server-side undo and cancel all address a submission by Email id, so they need a
   draft on the server first.

2. **iOS is closed to the outside world.** `App/Info.plist` registers only `plmail://` (pairing).
   There is no `mailto` scheme, no Share Extension target — `plMail.xcodeproj` has exactly one
   app-extension target and it is the Widget — and `RootView.onOpenURL` discards every URL once
   signed in. Android answers `VIEW mailto:`, `SENDTO`, `SEND` and `SEND_MULTIPLE`
   (`app/src/main/AndroidManifest.xml`) with hardened parsers for each.

3. **iOS leaves live server features on the table.** Scheduled send is implemented server-side with
   a 30-day ceiling; iOS holds messages on the device instead and ships a caveat apologising for
   the imprecision. Undo-send is a server-honoured cancel; iOS blocks the composer open for five
   seconds instead. Signatures are stored per alias and are writable over JMAP; iOS reads only
   `textSignature`, appends it once as plain text, and its settings screen tells the user
   signatures cannot be edited. `Contact/autocomplete` gives frequency-ranked suggestions from the
   user's own mail; iOS does not call it.

Roughly 45 % of Android's behaviour in this domain is missing on iOS, ~25 % partial, ~20 % at
parity, and ~10 % is iOS ahead.

## Gaps

| Feature | Android source | iOS status | Notes |
|---|---|---|---|
| Draft autosave to server | `ComposeViewModel.kt:531` `watchForAutosave`, `ComposeRepository.kt:214` `save` | **Missing** | No `Email/set` until send. Dismiss = data loss. Blocks items below. |
| Draft create vs patch; attachment read-back | `ComposeRepository.kt:214–244`, `ComposeDraft.kt:51` | **Missing** | `attachments` on update is whole-value and all-or-nothing — see gap notes. |
| Discard vs save on close | `ComposeViewModel.kt:283` `close`, `ComposeRepository.kt:509` `discard` | **Missing** | iOS Cancel = unconditional dismiss, no sheet, no save. |
| "Saving…/Saved" indicator | `ComposeScreen.kt:471` `SaveState` | **Missing** | Nothing tells the user where their text is. |
| `ifInState` on draft writes | not used by either | **Missing (both)** | Honoured server-side; the fix for two devices editing one draft. |
| `mailto:` URL handling | `Mailto.kt`; manifest `VIEW mailto` filter | **Missing** | No URL type registered; `RootView.swift:41` drops URLs when signed in. |
| Share-sheet intake | `ShareIntake.kt`; manifest `SEND`/`SEND_MULTIPLE` | **Missing** | No Share Extension target. App Group `group.de.pluetzner.plmail` already declared. |
| Shared-file staging, size refusal by name | `SharedAttachments.kt` | **Missing** | Constraints carry over to a Share Extension. |
| Attachment size ceiling | `SharedAttachments.kt:295` `MAX_BYTES`, size per chip | **Missing** | iOS shows a total only (`ComposeView.swift:352`); nothing refuses a 300 MB video. |
| Session upload limits honoured | neither reads them | **Missing (both)** | 50 MB upload, 50 MB attachments/email, 4 concurrent uploads. |
| Attachment bytes held once | `StagedAttachment` holds a URI, reads at upload | **Worse on iOS** | iOS holds full `Data` in memory, again on disk, again at upload. |
| Attachment upload retry | `ComposeRepository.kt:637` (sequential; fails the send) | **Partial** | iOS retries the whole message but **re-uploads every blob** each attempt. |
| Bcc restored when reopening a draft | `ComposeRepository.kt:187` `loadDraft` | **Missing** | `ComposeModel.apply(_:)` (`:312`) restores to/cc/subject/body only. |
| Draft attachments reopened as blob ids | `ComposeRepository.kt:744` `toStaged` | **Missing** | Reopening a draft with files loses them, then rewrites the draft without them. |
| Scheduled send, server-held | `SendLater.kt`, `SendQueue.kt:207` `schedule` (`HOLDUNTIL`) | **Missing** | Real feature: 30-day ceiling, leaves on time with the phone in a drawer. |
| Send-later ceiling from session | `SendLater.kt:52` `resolve(now, zone, latest)`, `WithinWindow` | **Missing** | iOS's picker is unbounded; the server refuses past 30 days rather than clamping. |
| Scheduled send, device-held (offline) | — | **iOS only** | `Outbox.PendingMessage.sendAfter`. Keep as the offline fallback. |
| Scheduled sends visible outside the composer | `SendStatus.kt:143` `ScheduledSendsBar` | **Partial** | `OutboxView` is the better surface; it just has nothing server-held to show. |
| Cross-device schedule reconcile | `ScheduledSendReconciler`, `SendQueue.kt:334` | **Missing** | `EmailSubmission/get` + `/changes` both exist. |
| Undo send, server cancel | `SendQueue.kt:178` `sendHeld` (`HOLDFOR`), `:239` `undo` | **Missing** | iOS delays locally and blocks the composer for 5 s. |
| Undo send after the composer closes | `SendStatus.kt:58` `SendStatusHost` | **Missing** | Once the iOS sheet is gone there is no undo at all. |
| "Too late" reported honestly | `SendState.TooLate`, `CancelOutcome.AlreadySent` | **Missing** | `cannotUnsend` must never be shown as "undone". |
| Undo-send delay configurable | neither | **Missing (both)** | iOS Mail offers Off/10/20/30 s. |
| Reopen composer on send failure | `SendStatus.kt:113`, `asEditRequest` | **Missing** | `OutboxView` offers Discard / Try now only. |
| Send with Bcc only (no To) | `ComposeDraft.hasRecipients` (`ComposeDraft.kt:58`) | **Broken** | `ComposeModel.canSend` (`:175`) requires `to`. |
| Recipient chips / tokens | `RecipientField.kt:150` `InputChip` | **Missing** | iOS is a raw comma-separated `TextField`. |
| `Name <address>` parsing | `RecipientField.kt:546` `parseAddresses` | **Missing** | iOS keeps the whole token as the email. |
| Quoted display names with commas | `RecipientField.kt:570` `splitAddresses` | **Broken** | `"Meyer, Anna" <a@x>` is split in half; the half without `@` is dropped. |
| Invalid recipients reported | dropped visibly at chip time | **Silent** | iOS filters at send with no feedback. |
| Recipient de-duplication | `RecipientField.kt:120` | **Missing** | Two identical addresses send two copies. |
| Server-ranked autocomplete | `ContactSuggestions.kt:131` `fromServer` | **Missing** | `Contact/autocomplete` is live; see gap notes for the privacy trade-off. |
| Autocomplete from synced mail | `ContactSuggestions.kt:170` `offline` | **Present** | `store.knownAddresses` + `RecipientSuggestions.merge`. |
| Device address book suggestions | `ContactSuggestions.kt:204` | **Present / better** | `SystemContacts` caches, asks on first keystroke, ≥2 chars. |
| Suggestion list presentation | `RecipientField.kt:270` floating popup, capped, scroll hint | **Partial** | iOS is a horizontal chip strip of 5 inside the form row. |
| From picker across accounts | `ComposeViewModel.kt:135` `setIdentity` | **Missing** | `ComposeView.init` fixes one `accountKey`; no cross-account send. |
| `forbiddenFrom` handled | `ComposeRepository.kt:476` `refusal` (names the alias, refreshes list) | **Missing** | Server refuses a stale `identityId` by design. |
| Signature inserted as a marked block | `Signatures.block` (`Signatures.kt:46`) | **Partial** | iOS appends `\n\n-- \n` + `textSignature` as plain text (`ComposeModel.swift:307`). |
| Signature swapped when From changes | `Signatures.replaceSignature` (`Signatures.kt:63`) | **Missing** | `hasSignature` guard applies it once, never replaces. |
| `htmlSignature` stored at all | `SendIdentity.htmlSignature` | **Missing** | `SchemaV1.swift:351` / `SyncStore.swift:537` persist `textSignature` only. |
| Signature editing | neither client offers it | **Missing (both)** | `Identity/set` accepts it; `IdentitiesView` currently says it is impossible. |
| Empty-composer detection excludes signature + quote | `ComposeDraft.isEmpty` (`ComposeDraft.kt:72`) | **Missing** | Required before autosave, or every opened composer litters Drafts. |
| Reply prefers `Reply-To` | `DraftComposer.kt:90` | **Missing** | iOS uses `fromAddress` only. |
| Reply-all excludes all own identities | `DraftComposer.reply(self:)`, `ComposeViewModel.kt:366` | **Broken** | iOS excludes only the original sender; the user Ccs themselves. |
| Reply-all keeps header order | `DraftComposer.kt:103` | **Partial** | iOS does `Array(Set(others)).sorted()` — alphabetical. |
| Subject prefix stripping (multi-language, stacked) | `DraftComposer.kt:26–33`, `:149` | **Broken** | iOS checks one lowercase `re:`/`fwd:`. `AW:`, `WG:`, `Re[2]:` all stack. |
| `References` trimmed to 20, root kept | `DraftComposer.kt:45`, `:171` | **Missing** | iOS appends unbounded (`ComposeModel.swift:512`). |
| Forward carries the original's attachments | `ComposeViewModel.kt:428` | **Missing** | iOS forwards the quote only. |
| Forward header block (From/Date/Subject/To/Cc) | `DraftComposer.kt:217` `forwardBlock` | **Missing** | iOS reuses the reply quote for forwards. |
| Forward starts a new thread | `DraftComposer.kt:125` | **Correct** | Parity. |
| Localised attribution line | `ComposeStrings.attribution` (`ComposeState.kt:147`) | **Missing** | `MailHTML.quote` hardcodes English (`RichText.swift:322`). |
| Quote from `sentAt` before `receivedAt` | `ComposeState.kt:156` | **Partial** | iOS uses `receivedAt` only. |
| Quote split on a web-written draft | server-side `ReplyDraftBuilder.php:225` | **Broken** | `splitQuote` cuts at `<blockquote`; the attribution stays editable. Markers are stripped on save — split on `style`, not `data-quoted`. |
| Quote preview / expand | `ComposeScreen.kt:419` | **Partial** | iOS shows a one-line row with Remove; no preview. |
| Rich text: bold/italic/underline | `ComposeScreen.kt:540` | **Present** | |
| Rich text: strikethrough, links | — | **iOS only** | `FormattingBar.swift`. |
| Rich text: bullet lists | `toggleUnorderedList()` | **Missing** | |
| Paste sanitising | library-dependent | **iOS better** | `AttributeScopes.MailEditorAttributes`. |
| EXIF/GPS stripped from photos | — | **iOS only** | `ImagePrivacy.swift`. |
| Hardware-keyboard shortcuts (⌘↩, Esc) | — | **iOS only** | `ComposeView.swift:73,81`. |
| App Intents / Siri compose | — | **iOS only** | `App/Intents/MailIntents.swift` + `IntentRouter`. |
| Persistent outbox surviving relaunch | — | **iOS only** | `Outbox.swift`. |
| `#creationId` back-reference (1 round trip) | Android uses 2 requests | **iOS better** | `OutboxSender.send` (`:232`). |

## Detailed gap notes

### Draft autosave to the server

**Behaviour.** A few seconds after typing stops, and again on close, the composer writes what it
holds to the account's Drafts mailbox. Android debounces 3 s on the whole draft value
(`ComposeViewModel.kt:531`), skips the save when the draft is "empty", and folds only the
server-assigned bits — email id and attachment blob ids — back into state, deliberately not
overwriting anything typed since (`:547`).

**API.** First save `Email/set { create: { "c1": {…} } }`; every save after
`Email/set { update: { <id>: <patch> } }`.

- Create: `to`, `cc`, `bcc`, `subject`, `htmlBody` + `bodyValues`, `inReplyTo`, `references`,
  `attachments`. Do **not** send `mailboxIds` or `keywords` — `JmapDraftWriter::create()` files it
  into Drafts and sets `$draft` itself. `from` is not settable; the From address is decided by
  `identityId` at submission.
- Update: the draft-property allow-list is `subject, to, cc, bcc, textBody, htmlBody, bodyValues,
  inReplyTo, references, attachments` (`EmailPatchApplier.php` `DRAFT_PROPERTIES`). A body change
  only lands if `bodyValues` is in the patch — `JmapDraftWriter::update()` reads the body through
  the part ids in `textBody`/`htmlBody`, so naming either without the values does nothing.
- `ifInState` is honoured. Use it once autosave exists: two devices on one draft is now a real
  scenario, and `stateMismatch` is how you find out instead of clobbering.
- Errors arrive inside a 200 — read `notUpdated`/`notCreated` per object.

**The attachments contract** (this shapes the whole design, and an earlier draft of this document
got it backwards from the stale tree — `JmapDraftWriter::update()` *does* implement it):

- `attachments` is a **whole value**, not a patch. Send the complete list the draft should end up
  with: `p-` blob ids for parts you are keeping, `u-` blob ids for what you just uploaded.
- **Parts you leave out are removed and their bytes deleted.** An autosave that omits the key
  entirely leaves them alone; an autosave that sends `[]` destroys them. These are different.
- A part re-listed by its `p-` blob id keeps its id and is **not re-uploaded**. Supplying a
  different `name` renames it.
- **A blob id that will not resolve fails the entire patch.** You get
  `notUpdated[id].type = "invalidProperties"` and *nothing* is applied — not the attachments, not
  the subject beside them. Recovery is re-upload and retry the whole patch.

So: track `savedAttachments` alongside `attachments` and send the array **only when the set has
changed** (Android's `ComposeDraft.attachmentsChanged`, `ComposeDraft.kt:54`). Re-stating a dozen
blob ids on every keystroke is pure cost over someone's home uplink, and the whole-value semantics
make an accidental empty array destructive.

**UX.** A quiet "Saving… / Saved" line, shown once the draft has an id (`ComposeScreen.kt:471`).
Cancel becomes a confirmation with **Delete Draft / Save Draft / Cancel**.

**Edge cases.**
- *Empty means empty.* Port `ComposeDraft.isEmpty` (`ComposeDraft.kt:72`): no recipients, blank
  subject, no attachments, and a body that is blank once the signature block and the quoted
  original are removed. Without it, opening and abandoning a composer leaves a draft containing
  only the user's own sign-off. `isBlankHtml` (`:137`) strips tags, `&nbsp;` and U+00A0 first — a
  rich editor emits `<div><br></div>` for "nothing".
- The quote lives outside the editor and must be appended for the save exactly as for the send
  (`withQuote`, `ComposeViewModel.kt:659`), or a draft reopened in the browser loses it.
- Cancel any in-flight autosave before submitting, or a late save overwrites the body being sent
  (`ComposeViewModel.kt:231`).
- Uploading at *pick* time is tempting and wrong: the server reclaims unreferenced blobs, so a
  draft left open over a holiday would be sent with its attachments already collected. Upload on
  the save that first references them, which is what makes the `p-` id durable.

### Reopening a draft: Bcc and attachments are dropped

`ComposeModel.apply(_:)` (`ComposeModel.swift:312`) restores `to`, `cc`, `subject` and the body. Not
`bcc`, not `attachments`. Because `OutboxSender.send` rewrites the draft from whatever the composer
holds, reopening a draft with a Bcc line and two PDFs and pressing Send delivers it with neither —
and, per the whole-value rule above, deletes the stored parts.

**API.** `EmailGet.readerProperties` already fetches `attachments`. Map non-inline parts that have a
`blobId` into a pending-attachment case carrying a blob id instead of `Data` (Android:
`StagedAttachment.blobId`). Filter `isInline` out — a `cid:` image belongs to the body and listing
it as removable confuses people.

**Edge case.** Blob ids are account-scoped; the resolver refuses one belonging to another account.
If the From account becomes changeable, drop blob-backed attachments on an account switch.

### Scheduled send — recommendation: server-first, with the outbox as the offline fallback

**The evidence.** `SubmissionEnvelope.php` implements RFC 4865 FUTURERELEASE as
`envelope.mailFrom.parameters`, accepting `HOLDFOR` (whole seconds, as a string) **or** `HOLDUNTIL`
(a date-time) but not both (`:161`). `MAX_HOLD_SECONDS = 2_592_000` — 30 days — is both the
advertised `maxDelayedSend` and the enforced limit: a longer hold is **refused with
`invalidProperties`, not clamped** (`:188`, `:216`). A hold that has already elapsed sends
immediately. The rest of the envelope is validated rather than applied — plMail sends the From and
recipients stored on the Email, so a `mailFrom.email` or `rcptTo` naming anything else is refused.
The release time comes back on `sendAt` in the create response, and `EmailSubmission/get` reports
it for as long as the message is held.

**The re-argument.** An earlier version of this document called iOS's device-local scheduling "the
correct design, not a stopgap". That rested on the server having no `futureRelease`. It has one, and
the comparison is not close:

- Server-held: the message leaves at the chosen minute with the phone off, in a drawer, or
  reinstalled. Cancelling works from any device. The web UI sees the same schedule.
- Device-held: the message leaves "at the first check after this time", which needs the phone awake
  and the app or a granted background refresh — the caveat `SendLaterSheet.caveat` currently
  apologises for. A phone that is flat at 08:00 sends the "before you start work" mail at lunchtime.

So the server path is the default, and the local outbox stops being the scheduler and becomes what
it is genuinely good at: surviving an unreachable server.

**The design.**

*Server path (default).* Requires the draft to exist server-side, so it is gated on autosave.
1. Save the draft (create or patch), so it has an Email id.
2. `EmailSubmission/set create` with `envelope.mailFrom.parameters.HOLDUNTIL` = the chosen instant
   as a UTC date-time. Prefer `HOLDUNTIL` over `HOLDFOR` for user-chosen times: `HOLDFOR` is counted
   from when the request *arrives*, so a phone whose clock is a minute fast promises a moment that
   has not happened. Reserve `HOLDFOR` for the undo window, where a duration is what is meant.
3. **Record the server's `sendAt`, never the user's chosen time.** They agree today and would not on
   an instance that rounds. What is shown must be what the mail actually leaves at
   (`SendQueue.kt:214`).
4. Persist `{accountKey, emailId, identityId, subject, sendAt}` locally so the Outbox screen can
   show and cancel it without a round trip (Android's `ScheduledSend`). The bytes are **not** kept —
   the message is on the server.
5. Do not enqueue anything in the local outbox for this path.

*Local path (fallback).* Used when the server is unreachable at the moment of scheduling — which
includes the whole offline-composition case the outbox exists for. File as today with `sendAfter`.

*The handover, precisely.* On every drain (`OutboxSender.drainNow`), for each queued message that
has a `sendAfter`:
- If `sendAfter` has **passed**: submit now, with no hold. Unchanged from today.
- If `sendAfter` is **still in the future and within `maxDelayedSend` of now**: *convert*. Create or
  update the draft, submit with `HOLDUNTIL`, and on success remove the outbox entry and record the
  schedule from the response's `sendAt`. The message stops being the device's problem. This is the
  only place a queued message leaves the outbox without being sent, so it must be atomic in the
  same order everything else uses: draft written first, submission second, outbox entry removed
  only after the submission is accepted. A crash between steps leaves a draft in Drafts and a
  message in the outbox — recoverable and visible, which is the right failure.
- If `sendAfter` is **beyond the ceiling**: leave it local. Do not send a request that will be
  refused.

*The picker.* Bound it at `now + maxDelayedSend`, as Android does (`SendLater.kt:128`
`SendLaterPicker`, `WithinWindow`): dates past the ceiling are not selectable and the confirm button
is disabled for a time already past or one minute over. The server refuses rather than clamps, and a
refusal arriving after the composer has closed is a message the user believes is scheduled. Drop
presets that resolve to a moment already gone — offering "later today" at eleven at night and having
the mail leave immediately is a control that appears to do nothing (`SendLater.kt:52`).

*The caveat text.* `SendLaterSheet.caveat` is true for the local path and a lie for the server path.
Make it conditional, and show it in `OutboxView` only on rows that are actually device-held. Removing
it entirely would be the same mistake in the other direction.

*Reconcile.* On launch, `EmailSubmission/get` the recorded ids and act on the table: `pending` keep,
`canceled` drop, `final` drop. Subscribe to `EmailSubmission/changes` so a cancel made in the browser
takes the row away here. Android's retirement rule is worth copying wholesale
(`ScheduledSends.kt`, `SendQueue.settle`): never drop a record on silence alone before its release
time, and drop it after a grace period once the server says nothing useful — a row still saying
"leaving at 08:00" at half past nine is worse than no row.

### Undo send — the server can cancel; stop blocking the composer

**Current iOS.** `ComposeModel.send()` starts a five-tick countdown and the sheet only dismisses when
`status == .sent` (`ComposeView.swift:168`). The user watches a progress bar for five seconds, and
the moment the sheet is gone there is no undo at all. Nothing has been submitted, so a process death
inside the window drops the send silently — the user watched the composer close and believes the mail
went.

**Server behaviour.** The web UI's own grace period is deliberately *not* applied to JMAP submissions
— a JMAP client asked to send now — and `docs/CLIENT_DEVELOPMENT.md` tells clients to implement a
window themselves. Doing that by delaying the *call*, as iOS does, is the weaker of the two ways.
Submitting immediately with `HOLDFOR` is better on every axis: the mail leaves on time if the app
dies, and the cancel is a real server operation (`EmailSubmissionSetMethod` `applyUpdates()`).

**Design.** This is `SendQueue.sendHeld`/`undo` (`SendQueue.kt:178`, `:239`) and the reasoning in that
file's header applies verbatim.

1. Save the draft. Submit at once with `envelope.mailFrom.parameters.HOLDFOR = "<delay>"`.
2. Dismiss the composer immediately. Keep the submission id (which *is* the Email id).
3. Show an **Undo Send** affordance outside the composer for the delay — see "The Apple way".
4. Undo is `EmailSubmission/set { update: { <id>: { "undoStatus": "canceled" } } }`.
   - Accepted → the draft is still in Drafts; reopen the composer on it **by id**, so what comes back
     is what is stored rather than an in-memory copy that could disagree.
   - `cannotUnsend` → the mail has gone. Say so. "Undone" over a delivered message is the one
     sentence this whole path exists to avoid.
   - `notFound` → nothing was submitted; there is nothing to call back.
5. Offer the delay as a setting — Off / 10 / 20 / 30 s. `Off` means submit with no hold, which is
   what the outbox already does.

**Edge cases.**
- The cancel is *reliable while held* and *a race once dispatched with no hold* — which is exactly
  why the window must be a hold rather than a local delay.
- Only `undoStatus` may be updated, and only to `"canceled"`; anything else is `invalidProperties`.
- Re-submitting after a cancel clears the flag server-side, so "undo, edit a word, send" works.
- `drainNow` currently has no in-flight guard, so a discard racing a send can remove a message that
  has already gone. Add a per-message in-flight flag when the outbox starts carrying held sends.

### Signatures

**Server behaviour.** Real, and richer than either client uses. `IdentityResolver::fromAlias()` calls
`SignatureProvider::htmlFor($account, $alias->address)` — a per-alias signature falling back to the
account's — and returns `htmlSignature` plus a `textSignature` *derived* from it. There is one
signature, in HTML, and two renderings. `Identity/set` accepts `htmlSignature` and `textSignature` on
both create and update (`:122`, `:195`); `htmlSignature` wins when both are sent; everything written
is sanitised. Absence of both keys means "leave it alone"; an **explicitly empty `htmlSignature` is a
distinct stored statement** meaning "this address signs with nothing", which on an account that has a
signature is not the same as inheriting it.

The marker is `<div class="pl-signature" data-pl-signature>…</div>`
(`SignatureProvider.php:96`), and `assets/controllers/compose/compose_controller.js` scopes its own
From-swap to `[data-pl-signature]`.

**But the marker does not survive being saved, and this is worth knowing before copying Android's
design.** `MailBodySanitizer::buildSanitizer()` allows `style` and explicitly does not allow `class`
or any `data-` attribute (`:194`), and it runs on every stored draft body — `JmapDraftWriter::update()`
calls it at `:115`, `DraftPersister` at `:154`. So a client that writes a marked signature block into
a draft and saves it gets the block back as a bare `<div>`. Android's `Signatures.kt` header claims
the marker is what lets "a draft started on the phone be re-opened in the browser and still have its
From menu swap the signature"; that round trip does not actually happen on this server. The marker is
live-DOM only.

**Current iOS.** `SchemaV1.swift:351` and `SyncStore.swift:537` persist `textSignature` only.
`ComposeModel.applySignature` (`:298`) appends `"\n\n-- \n" + textSignature` into the
`AttributedString`, guarded by `hasSignature` so it happens once and is never replaced. And
`IdentityEditor.swift:15` documents, as a server fact, that signatures cannot be edited — which was
true of the stale tree and is not true of `origin/main`.

**Consequences.** The signature is indistinguishable from typed text, so empty-draft detection counts
it as content; changing From does not swap it; and an autosaved draft reopened in the browser has no
marker for the web composer's swap to find, so choosing a different From there appends a second
sign-off under the first.

**Design.**
1. Store `htmlSignature` in the identity snapshot beside `textSignature`.
2. **Track the signature's extent in the composer's own state, not by re-parsing the body.** Because
   the marker is stripped on save, an `AttributedString` range (or a custom attribute alongside
   `MailInlineStyle`) is both simpler and more reliable than Android's markup surgery, and it is the
   natural SwiftUI shape. Emit the marked block on the wire anyway — it costs nothing and is correct
   for the same-session case — but never depend on reading it back.
3. On From change, replace over that tracked range. Everything outside it is untouched: changing From
   must never cost a typed paragraph. If a body ever does have to be re-scanned for a marker, use a
   depth-counting scan rather than a regex — a signature is arbitrary user HTML and routinely
   contains `<div>`s, so a regex ending at the first `</div>` welds the tail of the old signature
   onto the front of the new one (`Signatures.kt:87`).
   Empty signature → **no block at all**, not an empty one; an empty block would be a stray `div` in
   every message the user sends from that address.
   On a **reopened draft**, do not attempt a swap: the text already contains whatever signature it
   was written with, there is no marker left to scope to, and appending again would stack them. iOS's
   existing `editingEmailID == nil` guard is the right rule and should stay.
4. Exclude the block from `isEmpty`.
5. Correct the copy in `IdentitiesView` and offer an editor: `Identity/set update { <id>: {
   "htmlSignature": "<p>…</p>" } }`. Remember the empty-string semantics — a "no signature" toggle
   must send `""`, and "inherit the account's" must send nothing at all. Renaming already works
   (`IdentityEditor.rename`); create and destroy are available too, gated on `mayDelete`.

### Recipient autocomplete, and the privacy trade-off

**Server behaviour.** `Contact/autocomplete`, under `urn:plmail:params:jmap:contacts`, advertised per
account and at the top level with `maxSuggestions` (50) and `defaultSuggestions` (8). Arguments are
`accountId`, `query`, `limit` and nothing else — an unknown argument is rejected. It returns:

```json
{ "accountId": "7", "query": "ada", "limit": 8, "list": [
  { "name": "Ada Lovelace", "email": "ada@example.org",
    "frequency": 12, "lastSeenAt": "2026-08-01T09:14:00Z", "isCorrespondent": true } ] }
```

The entry is a JMAP `EmailAddress` with ranking signals hung off it, so it drops straight into an
`Email/set` create. Ordering is frequency then recency; `isCorrespondent` says whether the user has
ever *written* to the address rather than merely heard from it. The address book is harvested from
mail headers server-side and is not writable — there is no `Contact/get`, `/query` or `/set`. Both
`query` and `limit` are echoed back because both are normalised.

**The privacy trade-off, stated plainly.** iOS today has a property worth naming: **recipient
suggestions never leave the device.** They come from mail already synced (`store.knownAddresses`) and
from the system address book (`SystemContacts`), and the `NSContactsUsageDescription` string promises
exactly that — "Your contacts are read on the device and never leave it."

Calling `Contact/autocomplete` changes that. It sends a prefix of what the user is typing to the
server on a debounce. Two things are worth separating:

- The **addresses** are not new information. The server harvested them from the user's own mail
  headers; it already holds them.
- The **keystrokes** are. The server learns what the user typed, when, and from which account — and
  when the match comes from the device address book rather than from mail, it learns a name it had no
  other way to know. On a self-hosted box that the user owns this is a small thing; it is still a
  change, and the Info.plist string as written would become false.

**Design.** Server for ranking, device for reach, merged locally — Android's order
(`ContactSuggestions.kt`), which is also the shape `RecipientSuggestions.merge` already has:

1. `Contact/autocomplete` for the ranked list. Guard on the capability being present and fall back
   silently when it is not — an instance without the extension is supported, not broken.
2. The device address book as a **supplement**, not a re-ranking: it holds people the user has never
   mailed, which is precisely what the server cannot know.
3. Merge by lowercased address, first source wins, so server-ranked entries stay on top. Keep the
   local cache as the offline answer when the request fails, filtered against the current fragment,
   so a phone in a lift still suggests.
4. Debounce ~220 ms and minimum 2 characters — the server is frequently a Raspberry Pi advertising
   four concurrent requests, shared with the message list the user may still be scrolling. Cancel a
   superseded lookup rather than letting it return, so a stale answer cannot overwrite a fresh one.
   `ComposeModel.lookUpContacts` already has the cancel-and-debounce shape; it just needs the second
   source.
5. **Make it a setting**, defaulting on, and reword `NSContactsUsageDescription` so the promise
   matches the behaviour. "Suggest people as you type; matching happens on your own server" is
   honest. Leaving the current string in place while sending fragments to the server is not.
6. Cap at `maxSuggestions`; ask for `defaultSuggestions` unless the UI can show more.

### Attachment ceilings and memory

iOS has no limit anywhere. `PendingAttachment` holds full `Data` in memory, the outbox writes a
second copy to disk, and `OutboxSender.send` holds every attachment's bytes again while building the
request. Ten 4K videos terminate the app before the user learns the server would have refused them.

**API.** Published and unread by both clients: `session.capabilities.core.maxSizeUpload` = 50 MB,
`maxConcurrentUpload` = 4, and per account
`accountCapabilities["urn:ietf:params:jmap:mail"].maxSizeAttachmentsPerEmail` = 50 MB. `Session`
already decodes the first and the third (`JMAPKit/Protocol/Session.swift`); nothing consults them.
Over-size upload gets `tooLarge` / 413.

**UX.** Per-file size on each row (Android puts it on the chip, `ComposeScreen.kt:398`), a running
total against `maxSizeAttachmentsPerEmail`, and a refusal **at pick time, naming the file**. Never
truncate — a message that goes out with the first 25 MB of a video looks like it worked.

**Edge case.** Stream rather than materialise: read from the security-scoped URL straight into the
outbox directory and upload from the file handle. That also removes the double copy that exists
today. Upload sequentially — `maxConcurrentUpload` is 4, and the audience runs this against hardware
where four simultaneous multi-megabyte POSTs is the difference between a send and a timeout.

### `mailto:` handling

**Behaviour.** Tapping an address anywhere on the device opens plMail's composer prefilled. Android
parses RFC 6068 in `Mailto.kt`: addresses before `?`, then `name=value&…` pairs, of which exactly
five are honoured — `to`, `cc`, `bcc`, `subject`, `body`. Everything else, notably `from` and
`reply-to`, is ignored on purpose: a link that can set the sender is a way to compose mail in someone
else's name from a page the user merely visited.

Three parser details are load-bearing:

- **`+` is a plus sign, never a space.** RFC 6068 is percent-encoding, not form encoding.
  Form-decoding turns `anna+lists@example.org` into an address with a space in it, which then gets
  dropped. A literal `+` surviving in a subject is cosmetic; a vanished recipient is not.
  `URLComponents.queryItems` does not substitute `+`, so it is safe — a hand-rolled decoder must not
  either.
- **Split the address list before percent-decoding.** Decoding first lets a `%2C` inside a quoted
  display name become a separator and cut one recipient into two unusable halves (`Mailto.kt:87`).
- **Decode runs of escapes as bytes.** `%C3%A4` is one `ä`; per-escape decoding yields two
  replacement characters. Every German subject line comes through here (`Mailto.kt:101`).
- A `%` not followed by two hex digits stays literal rather than throwing.

**UX.** Open the composer as for a new message, with Cc/Bcc already expanded when the link filled
either — a link that Ccs someone invisibly is the failure to avoid (`ComposeViewModel.kt:470`). The
body arrives as **plain text** and must be escaped into the editor, never inserted as markup.

**Edge cases.** `mailto:` with nothing after it is legal and means a blank message. Both
`mailto:a@x` and `?to=a@x` may appear in one link and the lists concatenate. Header names match
case-insensitively. A malformed link must open a composer, not fail.

### Share-sheet intake

**Behaviour.** Another app hands plMail text, a URL or files, and a composer opens on them. Android
reads four intents into one shape (`ShareIntake.kt:43`) and covers, from experience, address extras
in all three shapes real apps send them, a subject falling back to the share sheet's title, a list of
texts joined by a blank line, and `ClipData` as a last resort. It deliberately does **not** read
`EXTRA_HTML_TEXT` — foreign markup never enters the editor.

**UX.** The composer opens with the shared text as the body (escaped, paragraph-broken at blank
lines — `asBodyHtml`, `ComposeViewModel.kt:642`), the subject filled, files listed, and anything that
could not be taken named out loud.

**Edge cases, all learned the hard way in `SharedAttachments.kt`.**
- Copy the bytes while the grant is alive. A draft holding a reference to another app's file is a
  draft holding a link that expires quietly, and it surfaces at send time — days later, where the
  user can do nothing about it.
- Never put a supplied display name in a path. Write bytes to a fixed filename inside a UUID
  directory and keep name and MIME type in a sidecar. A shared name can be
  `../../databases/plmail.db`.
- Refuse an over-large file **by name, out loud, never truncated**.
- Count bytes while copying rather than trusting a declared size.
- Distinguish "too large" from "unreadable" — they lead the user somewhere different.
- Losing one file of four is bad; losing the message being written around them is worse. Never fail
  the whole intake.
- Sweep staged copies on a timer (Android: 7 days, on the way *into* the next share, because there
  is no reliable way-out hook — the send outlives the composer).

### Recipient parsing and entry

`ComposeModel.recipients(from:)` (`:518`) splits on `,`/`;`, trims, keeps anything containing `@`,
and builds `EmailAddress(email:)` from the whole token. In severity order:

1. `"Meyer, Anna" <anna@example.org>` — an ordinary Outlook address — splits into `"Meyer` (dropped,
   no `@`) and `Anna" <anna@example.org>` (kept, junk as the address). Android's `splitAddresses`
   (`RecipientField.kt:570`) tracks quote and angle-bracket depth.
2. `Anna Meyer <anna@example.org>` becomes an address equal to that whole string. Android's
   `parseAddresses` (`:546`) extracts the angle-address and keeps the name.
3. A typo without `@` is dropped at send with no message. Android refuses it at chip time, visibly.
4. Duplicates send two copies.
5. More than one `@`, or a leading/trailing `@`, are accepted.

**UX.** Tokens, not a string. Android commits a typed address on Enter, on a typed separator, and
**on losing focus** — the last is what stops a half-typed address disappearing when the user taps
Send straight from the field (`RecipientField.kt:215`).

**Edge case.** Take a picked suggestion whole, name included. Android's earlier version re-parsed the
bare address and threw away the name the contact list had just supplied (`:134`).

### Reply, reply-all and forward

Pure logic; belongs beside `MailHTML` where it can be unit-tested.

- **`Reply-To` wins over `From`** — the header's entire purpose, and mailing lists depend on it
  (`DraftComposer.kt:90`).
- **Reply-all must exclude every address the user can send as**, not just the sender being answered
  (`ComposeViewModel.kt:366`). Otherwise replying-all to a thread you are on Ccs you on your own
  reply.
- **To/Cc placement.** The person answered goes to To; the original's To *and* Cc go to Cc, minus the
  user and anyone already in To. De-duplicate case-insensitively on the address, keeping the first
  spelling of the name (`DraftComposer.kt:254`).
- **Subject prefixes.** Strip repeatedly and across both families before adding one: `re`, `aw`,
  `antw`, `sv`, `vs`, `odp`, `ref` and `fw`, `fwd`, `wg`, `tr`, `rv`, `enc`, `vb`, case-insensitive,
  including Outlook's `Re[2]:`. German is a first-class language here, so `AW:` and `WG:` matter as
  much as `Re:`. A reply to a forward becomes `Re: x`, not `Re: Fwd: x` (`DraftComposer.kt:26–33`,
  `:149`).
- **`References` cap.** Keep the first id — every threading algorithm finds the root through it — plus
  the most recent 19, dropping from the second onwards (RFC 5537 §3.4.4). A hundred-message thread
  otherwise produces a header MTAs reject.
- **Message-ID.** A draft has none; plMail assigns it at send. Replying to an unsent draft cannot
  thread and must not fabricate an id.
- **Forward carries the original's attachments by blob id** — nothing downloaded and re-uploaded
  (`ComposeViewModel.kt:428`). Non-inline parts with a blob id only.
- **Forward has its own header block** — `---------- Forwarded message ----------` then From / Date /
  Subject / To / Cc, each escaped (`DraftComposer.kt:217`). Reusing the reply quote produces "On …, X
  wrote:" above a message the user is forwarding, not answering.
- **Forward starts a new conversation:** no `inReplyTo`, no `references`. iOS already gets this right.
- **Attribution is localised and prefers `sentAt` over `receivedAt`.** `MailHTML.quote`
  (`RichText.swift:318`) hardcodes English and takes `receivedAt`; the two dates differ by days for
  anything that sat in a queue.
- **Escape a plain-text original before quoting.** A message whose text contains `<b>` must not start
  rendering as markup (`DraftComposer.kt:201`).

### Quote markers and web interop

The server's sentinel is `data-quoted="1"` on a wrapper div that contains **the attribution line and
the blockquote together** (`ReplyDraftBuilder.php:225`, `:248`), with legacy fallbacks the web
composer still recognises on bare `<blockquote>` and `div[style*="border-top"]` /
`div[style*="font-size:0.85em"]` (`compose_controller.js:2092`).

`MailHTML.splitQuote(fromHTML:)` (`RichText.swift:174`) splits at the first `<blockquote` only. A
draft written in the browser therefore splits in the wrong place: the attribution line and the
wrapper's opening tag stay in the editable body, and the user sees "On 3 March, Ada wrote:" as
editable text above a quote chip.

**The marker is not the fix, though, and this is the part that is easy to get wrong.** `data-quoted`
is a `data-` attribute, so the sanitiser strips it from the stored body exactly as it strips
`data-pl-signature` — the server consumes it at save time (`DraftPersister::plainTextBody()` splits
the *incoming* HTML on it, `:216`) and then persists a body without it. What actually survives a
round trip is the inline `style`, because `style` is allowed: the wrapper keeps
`border-top:1px solid #e0e0e0 … font-size:0.85em`. That is why `compose_controller.js:2092` matches
on those style fragments alongside the marker, and why they are not "legacy fallbacks" at all — after
one save they are the only signal left.

**Fix.** Split on, in order: `data-quoted` (same-session only), then `div[style*="border-top"]` /
`div[style*="font-size:0.85em"]`, then the attribution-then-blockquote heuristic `trimQuotedHistory`
already implements (`RichText.swift:211`), then bare `<blockquote`. Emit
`<div data-quoted="1" style="border-top:…;font-size:0.85em;…">` on the wire so the styling — the
durable half — matches what the browser writes.

### From picker across accounts

`ComposeView.init` fixes `accountKey`/`accountID`, so the identity list is one account's aliases. A
user with two connected accounts cannot answer from the other and cannot see that the choice exists.

`identityId` is genuinely honoured: `EmailSubmissionSetMethod::applyIdentity()` resolves it through
the same `IdentityResolver` list `Identity/get` publishes and writes `fromAddress` on the message the
worker reads. An id the server did not publish is **`forbiddenFrom`**, not a silent send as the
account address. Neither client handles that error well on iOS's side — Android translates it,
naming the alias, and re-reads `Identity/get` in the same breath so the picker stops offering it
(`ComposeRepository.kt:476`).

Android's `setIdentity` (`ComposeViewModel.kt:135`) also handles the cross-account case: a different
account is a different object graph, so the draft id is abandoned, blob-backed attachments are
dropped, and the submission window is re-read (`maxDelayedSend` is per account). A reply should
default to the account the message arrived in, and `loadDraft` should match the draft's own `from`
against known identities rather than taking the first — otherwise reopening a draft written from an
alias silently moves it back to the primary address (`ComposeRepository.kt:181`).

### Server capabilities neither client uses

- **`ifInState` on `Email/set`** — honoured. With autosave, two devices on one draft is real;
  `ifInState` turns a clobber into a `stateMismatch` you can merge.
- **`EmailSubmission/changes`** — a tracked push type. Lets the app learn a message was sent or a
  schedule cancelled in the browser and reconcile its Outbox.
- **`onSuccessUpdateEmail`** — optional here because `MessageSendService` already performs the whole
  draft→sent transition. iOS correctly omits it. `onSuccessDestroyEmail` is read by nobody
  server-side; do not rely on it.
- **`Identity/set` create and destroy** with `mayDelete` published per identity — a "manage sending
  addresses" screen is buildable; iOS only renames.
- **`Contact/autocomplete`'s `frequency` / `lastSeenAt` / `isCorrespondent`** — Android decodes them
  and draws none. Enough to mark a real correspondent, or to explain the order.
- **Inline `Content-ID` parts.** `MessagePart` supports inline embedding on send, but no client-facing
  path creates one — inline images cannot be composed today. Worth knowing before promising them.
- **Blob `m-<id>`** is the full RFC822 source — the basis for a "forward as attachment" feature
  neither client has.
- **`maxSizeUpload` / `maxSizeAttachmentsPerEmail` / `maxConcurrentUpload`** — published, unread.

## The Apple way

**Share intake: a Share Extension, not an intent filter.** Add a `com.apple.share-services` target
with an `NSExtensionActivationRule` accepting text, URLs, images and files. It runs in its own
process, so Android's expiring-grant problem is replaced by a different one: the extension's
container is not the app's. The App Group `group.de.pluetzner.plmail` is already declared in
`App/plMail.entitlements` and `Widget/PLMailWidget.entitlements` — write shared items into
`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. Read items with
`NSItemProvider.loadTransferable(type:)` / `Transferable` rather than type-identifier soup. Every
constraint in the `SharedAttachments.kt` note still applies: copy the bytes, never trust a supplied
filename as a path component, refuse by name rather than truncating.

Two viable shapes: (a) the extension presents a minimal compose UI and files straight into the
outbox — the iOS Mail behaviour, and the reason people use share sheets; (b) it stages and the app
opens a full composer. Prefer (a), with an "Open in plMail" escape hatch. Note (a) and server-side
scheduling interact: an extension cannot assume a live session, so it should always file locally and
let the app's next drain convert.

**`mailto:`: a URL type plus, separately, the Default Mail App capability.** Declare `mailto` under
`CFBundleURLTypes` and handle it in `RootView.onOpenURL`, which today discards every URL once signed
in — it needs a second branch, not a replacement. Being *offered* as a choice is separate from being
*the default*: since iOS 18.2 a third-party client can be set as the default mail app, which requires
the managed `com.apple.developer.mail-app` entitlement (Apple approval). Ship the URL type first;
treat the entitlement as a separate, gated step. Route the parsed result through `IntentRouter` with
a new `Request` case, not a second bespoke channel.

**Undo send: iOS Mail's model, not a snackbar and not a blocking bar.** Dismiss the composer at once,
submit with `HOLDFOR`, and show an **Undo Send** row pinned at the bottom of the message list while
anything is inside its window. Expose the delay with Apple's own choices — Off, 10, 20, 30 s. Android
uses a snackbar because that is the Material equivalent; do not port the snackbar.

**`UndoManager` is for text, not for send.** The composer should support ⌘Z and shake-to-undo over
the body. `TextEditor` with an `AttributedString` binding participates in the responder chain's undo
manager already; the risk is `RichTextEditor.normalized(_:)` writing back on every change
(`RichTextEditor.swift:52`) and polluting the stack. Verify undo steps are typing-sized, not
one-per-normalisation.

**Cancel is an action sheet.** `.confirmationDialog` with **Delete Draft** (destructive) and **Save
Draft**, as Mail does. Pair it with `interactiveDismissDisabled` gated on "has content", so a
swipe-down on an empty composer just closes.

**Keep `PhotosPicker` and `.fileImporter`.** Already right, including loading photos as `Transferable`
`Data` rather than by URL — a `PhotosPickerItem` is a promise and the asset may still be in iCloud.
The sequential loading is deliberate; do not parallelise it.

**App Intents over broadcast receivers.** `ComposeMailIntent` exists. Extend it with `cc`, `bcc`,
`body` and file parameters, add an `AppEntity` for identities so "send from my work address"
resolves, and donate after a send. Keep `openAppWhenRun = true` — an intent that sends without
showing the recipient list is the one mistake that cannot be taken back.

**`ShareLink` is for the other direction.** Not intake. Worth adding on a received attachment, which
neither client has.

**Recipient tokens.** SwiftUI has no token field; the Apple-correct surface is a
`UIViewRepresentable` over `UITextField` with token attachments, or a wrapping chip layout. The
commit rules from `RecipientField.kt` matter more than the pixels.

**Scheduling: server-held, honestly labelled.** Keep `BGTaskScheduler.earliestBeginDate` wired to
`OutboxSender.nextDueAt` (`App/AppModel.swift:145`) for the local fallback, and make the caveat
conditional rather than universal — it is true of a device-held message and false of a server-held
one.

## Do not regress

Things iOS currently does better, or does deliberately, which a port from Android would break.

- **The persistent on-disk outbox** (`Outbox.swift`) — outside SwiftData on purpose, because the
  store's governing rule is "everything here is reconstructible from the server" and an unsent
  message is the one thing that is not. One directory per message, so appending an attachment does
  not rewrite the queue. Both properties survive the server-first scheduling change: the outbox stops
  being the scheduler and remains the offline safety net.
- **Queue-then-drain, never send directly from the composer** (`ComposeModel.deliver`). The comment
  there records a real regression: the previous version told the user "saved as a draft" when the
  request that failed *was* the draft creation.
- **`ImagePrivacy.strippingLocation`** — GPS out of attached photos, applied in `ComposeModel.attach`
  so it covers every route a file arrives by, and only location is removed (stripping metadata
  wholesale is how photos arrive rotated). Android has no equivalent.
- **The attribute-scope-constrained editor** (`AttributeScopes.MailEditorAttributes`). Pasting from a
  web page drops colours, sizes and fills at the boundary, so what is on screen is always
  serialisable. Losing this means text that looks formatted and arrives plain.
- **Deriving `MailInlineStyle` from the font rather than the reverse** (`RichTextEditor.normalized`).
  ⌘B, the edit menu and paste all write the font directly; the other direction does not see them.
- **`<div>` line wrapping, not `<p>`** (`MailHTML.html(from:)`) — matches Gmail, Apple Mail and
  plMail's own web composer; `<p>` margins render differently everywhere.
- **Single round trip via the `#draft` back-reference** (`OutboxSender.send`). Android pays two.
  Keep it for the send-now path; scheduled sends need the draft to exist first anyway.
- **Emitting only what the server's sanitiser keeps.** `class`, `id` and every `data-` attribute are
  stripped server-side, so anything cleverer is deleted and the sender never finds out. Inline
  `style` is allowed, which is why structure that has to survive a save must be carried in `style`
  rather than in a marker — see the quote and signature notes above.
- **The quote kept out of the editor** (`ComposeModel.quotedHTML`) and appended verbatim at send.
  Both clients do this and both are right.
- **`BGTaskScheduler.earliestBeginDate` tied to `nextDueAt`**, and `settle()` awaited during
  background refresh so the system cannot suspend the process mid-send.
- **Contacts permission asked on the first recipient keystroke, ≥2 characters, once per launch**
  (`SystemContacts.isAuthorised`) — not at launch.
- **Saying what the app cannot promise.** `SendLaterSheet.caveat` is the right instinct even though
  its scope must narrow: keep it for device-held messages rather than deleting it once most sends are
  server-held.
- **⌘↩ to send, Escape to cancel**, and `FormattingBar` under the field rather than at
  `placement: .keyboard` — which renders nothing when a hardware keyboard is attached, i.e. exactly
  when someone is writing something worth formatting.
- **Failures named rather than spun** in `OutboxView` — "waiting for the server" and "the server
  refused this" call for different responses from the person who wrote the message.
