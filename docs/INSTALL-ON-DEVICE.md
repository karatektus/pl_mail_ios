# Putting plMail on your own iPhone or iPad

With a **free** Apple ID. No developer programme, no €99, no waiting for
approval. About fifteen minutes the first time.

The catch is the seven-day expiry — see [The seven-day thing](#the-seven-day-thing)
at the end. Everything else works.

---

## What you need

- A Mac with **Xcode 26**.
- An **Apple ID**. Any one. The same one you use on the iPad is easiest.
- A **cable**. Wireless works later; the first install is more reliable wired.
- Your **plMail server reachable from the iPad** — same Wi-Fi, or Tailscale, or
  a public address. An iPad cannot reach `127.0.0.1` on your Mac, so the
  address you paired the simulator with will **not** work here. Use the Mac's
  LAN address (`http://192.168.x.x:8001`) or your real server.

---

## 1. Add your Apple ID to Xcode

Xcode → Settings → **Accounts** → **+** → Apple ID → sign in.

You'll now have a team called something like *Paul Lützner (Personal Team)*.
That is a free team. It can sign apps onto devices you own and nothing else.

## 2. Tell the project who you are

```bash
cp App/Config/Signing.xcconfig.dist App/Config/Signing.xcconfig
```

Open `App/Config/Signing.xcconfig` and set your team id:

```
DEVELOPMENT_TEAM = ABCDE12345
```

Find it in Xcode → Settings → Accounts → select the team → the ten-character
string beside it. (Or leave it blank and pick the team in Xcode's Signing &
Capabilities tab — the file just saves you doing it three times.)

Leave the two `PLMAIL_*_ENTITLEMENTS` lines alone. They already point at the
free-tier files, which ask for no capabilities at all. This matters: a free
team **cannot** grant Push or App Groups, and asking for either fails the
build outright with *"Personal development teams do not support the …
capability"*.

## 3. Bundle ids have to be unique to you

`de.pluetzner.plmail` is taken — it is the App Store id of this project. Free provisioning
registers the id against your team the first time you build, and two people
cannot register the same one.

In Xcode, select the **plMail** target → Signing & Capabilities → change the
Bundle Identifier to something of yours:

```
com.yourname.plmail
```

Do the same for the **PLMailWidget** target (`com.yourname.plmail.Widget`).

## 4. Turn on Developer Mode on the device

Plug the iPad in, unlock it, tap **Trust** if asked.

On the iPad: Settings → Privacy & Security → **Developer Mode** → on → reboot →
confirm after the reboot. (The item only appears once a Mac has tried to
install something, so if you can't find it, do step 5 first and come back.)

## 5. Build and run

In Xcode, pick your iPad from the device menu at the top, then **▶ Run**.

The first run fails on the device with *"Untrusted Developer"*. That's
expected. On the iPad:

Settings → General → **VPN & Device Management** → your Apple ID → **Trust**.

Run again. The app opens.

## 6. Pair it

The QR pairing flow needs a code from your server:

```bash
docker exec -e APP_ENV=test pl_mail_test-app-1 \
  php bin/console app:device:pair e2e@plmail.test --base-url=http://192.168.x.x:8001
```

Use your Mac's **LAN address**, not `127.0.0.1` — the iPad has its own idea of
what localhost means. Show the QR in plMail's web UI (Settings → App passwords
→ Pair a device) and scan it, or type the address and paste an app password by
hand.

Codes last two minutes and work once.

---

## What you don't get on a free account

**Push notifications.** A free team cannot create an APNs key. The app already
handles this: it looks for push support, doesn't find it, and says nothing.
Mail arrives when the app checks — on opening, and periodically in the
background. The interface says "last checked N minutes ago" rather than
pretending to be live.

**The widget's numbers.** The widget installs and renders, but it lives in a
separate process and needs an App Group to see the app's data — which a free
team also cannot grant. Rather than showing a confident `0`, it says *"Needs a
paid developer account"*. If that annoys you, remove it: Xcode → plMail target
→ General → **Embed Foundation Extensions** → select PLMailWidget → **–**.

Everything else — the unified inbox, offline, search, compose with formatting,
the outbox, snooze, labels, dark mode, German — works exactly as it does on the
simulator.

---

## The seven-day thing

An app signed by a free Apple ID **stops launching after seven days**. It
doesn't delete itself and it doesn't lose your mail; it just refuses to open,
with a message about the developer.

To fix: plug in, press Run again. Ten seconds. Your account and cached mail
survive — they're in the Keychain and the app container, and reinstalling over
the top leaves both alone.

Two other free-tier limits, in case you hit them:

- **Three apps at a time** per device. The app and the widget count as two.
- **Ten app ids per week.** Only relevant if you keep renaming bundle ids.

If the weekly re-signing gets old, that — and push — is what the €99 buys. Not
before people are actually interested.

---

## When it goes wrong

**"Failed to register bundle identifier"** — someone already has that id. Pick
a more specific one (step 3).

**"Personal development teams do not support the Push Notifications
capability"** — `Signing.xcconfig` is pointing at the paid entitlements.
Both `PLMAIL_ENTITLEMENTS` and `PLMAIL_WIDGET_ENTITLEMENTS` should name the
`-free` files.

**"Untrusted Developer"** on the iPad — step 5, the Trust step.

**The app opens but can't reach the server** — almost always the address. From
the iPad's Safari, try opening the same URL you gave the app. If Safari can't
load it either, it's the network, not the app.

**"Failed to create app extension placeholder"** — the widget's Info.plist has
lost its `NSExtension` dictionary. It's at `Widget/Info.plist`; it needs
`NSExtensionPointIdentifier` = `com.apple.widgetkit-extension`. The error names
neither the extension nor the reason, which is why it's written down here.
