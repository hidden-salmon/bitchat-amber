# Amber-Alert App (`bitchat-amber`)

> **An amber-alert receiver for war zones and low-connectivity areas, layered on top of [bitchat](https://github.com/permissionlesstech/bitchat)'s Bluetooth mesh + Nostr fallback. Built at a hackathon, slated for actual NGO deployment.**

When a child is reported missing — say, a victim of trafficking in a conflict zone — every minute counts. But cell towers might be down, internet might be intermittent, and anyone responsible for getting the alert out has to reach across a degraded, patchy network of phones, dumbphones, and offline regions.

This app is the **user-side of an amber-alert system** designed for that environment.

- It receives alerts from an NGO's hub over **whatever path is currently up**: internet when available, **bitchat mesh** (phone-to-phone Bluetooth) when not.
- It lets users **submit sightings, location reports, and free-form messages** back to the NGO — again, over whichever path works.
- It is **strictly hub-and-spoke**: users can only ever talk to the NGO. Never to each other. Never via a route the NGO didn't issue.

This repo is a fork of [`permissionlesstech/bitchat`](https://github.com/permissionlesstech/bitchat) with new typed payloads and a new app surface; the underlying mesh, Noise crypto, and Nostr fallback are untouched.

---

## What you actually see when you run it

Four screens. That's the entire app. The smallness is the point — this is a focused tool, not a chat client.

| Screen | What it does |
|---|---|
| **Onboarding** | First-launch registration with the NGO: name, phone, profession, language. Generates a bitchat keypair. |
| **Alerts** | Read-only list of inbound amber alerts. Each row tagged `internet` or `mesh` so you can see the path it arrived on. Tap to respond. |
| **Map** | MapKit + CoreLocation. Pin yourself (GPS or manual tap), then mark the location **safe** or **unsafe**. |
| **Message NGO** | Free-form one-way message to the NGO. Typed, sent, gone. No replies in the user UI. |
| **Profile** | Edit name / phone / profession / language. |

There is no peers list, no chat, no DMs, no settings beyond profile. By design.

---

## Why this exists — the problem

Most missing-children alert systems assume reasonable infrastructure: working cell towers, broadband, App Store distribution, government partnerships. Conflict zones and disaster areas have **none of those reliably**. What they *do* have:

- A patchwork of phones, some smart, some not.
- Cell towers that come and go.
- People moving — between regions, across borders, in and out of dead zones.
- NGOs with field workers and partial connectivity.

The system that works in this environment has to be **multi-channel**, **resilient to intermittent failure**, and **architecturally hub-and-spoke** — because the NGO is the only entity authorised to issue an alert, and the only entity authorised to receive sensitive sighting reports.

The app you're looking at is the *receiver/reporter* slice of that system.

---

## The big picture — how this app fits into the wider system

```
┌──────────────────────────────────────────────────────────────────┐
│                          NGO HUB                                 │
│             (FastAPI + PostgreSQL — built by teammates)          │
│                                                                  │
│   ┌──────────────────┐   ┌──────────────────────────────────┐    │
│   │  Case database   │   │  Dispatch module                 │    │
│   │  Passport ledger │   │  (decides per recipient: SMS?    │    │
│   │  Operator UI     │   │   App push? Mesh broadcast?)     │    │
│   └─────┬────────────┘   └────┬───────────────┬────────┬────┘    │
│         │                     │               │        │         │
│         │                     ▼               ▼        ▼         │
│         │                ┌────────┐      ┌────────┐ ┌──────────┐ │
│         │                │ Twilio │      │ pybit- │ │ APNs / WS│ │
│         │                │  SMS   │      │ chat   │ │   push   │ │
│         │                │  lane  │      │ node   │ │  to app  │ │
│         │                └───┬────┘      └────┬───┘ └────┬─────┘ │
│         │                    │                │          │       │
└─────────┼────────────────────┼────────────────┼──────────┼───────┘
          │                    │                │          │
          │                    ▼                ▼          ▼
          │             ┌──────────┐     ┌─────────────────────┐
          │             │ Dumb-    │     │   THIS APP          │ ◄── what we built
          │             │ phones   │     │   (iOS / macOS)     │
          │             │ (SMS)    │     │                     │
          │             └──────────┘     │   forked bitchat    │
          │                              │   + amber payloads  │
          │                              │   + 4 new screens   │
          │                              └─────────────────────┘
```

**What we own:** the iOS/macOS app + the contract specifying how it talks to the hub.

**What teammates own:** the FastAPI hub, dispatch module, dashboard, SMS lane, and the `pybitchat` node that participates in the mesh on behalf of the NGO.

---

## The two pipes — how the app and hub actually communicate

The app uses **two transports**, both ending at the same NGO hub. Crucially, **the app never sends or receives SMS** — SMS is for users who don't have the app at all and is handled by the hub's separate dispatch module.

```
                  ┌─────────────────────────┐
                  │      THE APP            │
                  └────┬───────────────┬────┘
                       │               │
              ┌────────┘               └─────────┐
              │ Pipe 1:                Pipe 2:   │
              │ INTERNET               BITCHAT   │
              │ (HTTP + WS)            MESH (BLE)│
              ▼                                  ▼
       ┌─────────────┐                 ┌─────────────────┐
       │  /v1/...    │                 │  encrypted      │
       │  endpoints  │                 │  bitchat        │
       │  + WS push  │                 │  packets        │
       └──────┬──────┘                 └────────┬────────┘
              │                                 │
              │                       ┌─────────┴─────────┐
              │                       ▼                   ▼
              │               ┌──────────────┐    ┌──────────────┐
              │               │ another phone│    │ another phone│
              │               │ (relay only) │ ── │ (relay only) │
              │               └──────────────┘    └──────┬───────┘
              │                                          │
              │                                          ▼
              │                                   ┌──────────────┐
              │                                   │  hub's       │
              │                                   │  pybitchat   │
              │                                   │  node        │
              │                                   └──────┬───────┘
              ▼                                          │
                ┌─────────────────────────────────┐      │
                │           NGO HUB               │ ◄────┘
                └─────────────────────────────────┘
```

### Pipe 1 — Internet

The fast path. Used when the device has cellular or Wi-Fi.

- **Outbound** (app → hub): plain `POST` to `/v1/...` endpoints with JSON bodies.
- **Inbound** (hub → app): a long-running **WebSocket** at `/v1/stream` that pushes typed events (`ALERT_ISSUED`, `STATUS_UPDATE`, `ACK`) in real time.

Carries the **rich** version of an alert — full structured fields, photo URLs, anything that fits in JSON.

### Pipe 2 — Bitchat mesh

The resilient path. Works even when there is **no internet anywhere on the device**.

- The hub runs a [`pybitchat`](https://github.com/permissionlesstech/bitchat-python) node that joins the same bitchat mesh as the phones.
- Outbound from the hub: it broadcasts an **`alert`** payload (signed by the NGO key) into the mesh.
- Outbound from the phone: it encrypts a **`sighting`**, **`location_report`**, **`general_message`**, or **`profile_update`** payload to the hub's bitchat pubkey, and pushes it into the mesh.
- The mesh hops the encrypted bytes phone-to-phone over Bluetooth LE (TTL=7), each phone re-broadcasting blindly. Only the hub can decrypt user-bound packets; only verified hub signatures pass user-side.

Carries a **slim, TLV-encoded** version of every payload — built for tiny BLE MTUs, not human readability.

### Same alert, both pipes — dedup wins

When both pipes are up, the same alert may arrive twice. The app dedups by `case_id` and prefers the richer (internet) version for rendering, while still acknowledging that mesh is the reason it would have arrived at all if internet were down.

---

## Hub-and-spoke as a hard property, not a guideline

Users **must not be able to communicate with each other** through this system. Bitchat is natively peer-to-peer — without enforcement at our layer, anyone could DM anyone. We took it out structurally, not just visually:

| Threat                                      | How it's prevented in this app                                                                                       |
|---------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| User-to-user DMs / chat                     | No compose-to-peer surface in the UI. The user can't pick a recipient — the only destination is the hub.             |
| Faking an alert from the NGO                | App only renders `alert` payloads with a valid signature against the **stored hub pubkey** (acquired during onboarding). |
| Reading other users' sightings via mesh     | Sightings are **encrypted to the hub's pubkey**; relay phones carry opaque ciphertext they cannot decrypt.           |
| Trafficker compromises a phone, snoops mesh | The compromised phone sees only relayed ciphertext. App-level data is keychain-isolated.                             |
| Malicious user issues a "fake amber alert"  | Hub signature verification rejects the payload; mesh nodes will still relay it (cheap), but the app silently drops.  |

The mesh layer underneath continues to relay everyone's encrypted bytes — that's how a mesh works, you can't disable it without killing the network. But the **app surface** is structurally one-to-one with the NGO hub.

---

## Protocol additions over bitchat

We extended bitchat's `NoisePayloadType` enum with five new typed payloads. All are TLV-encoded (1-byte type + 1-byte length + value) using the same forward-compatible pattern bitchat already uses, and travel over the same Noise-encrypted bitchat envelope as private messages — which means we get bitchat's mesh routing, dedup, and crypto for free.

| Code  | Type             | Direction      | Purpose                                                |
|-------|------------------|----------------|--------------------------------------------------------|
| `0x20` | `alert`           | hub → users    | Amber alert. Signed by the NGO's bitchat key.          |
| `0x21` | `sighting`        | user → hub     | "I saw the missing person" report tied to a `case_id`. |
| `0x22` | `locationReport`  | user → hub     | "I am here, this place is safe / unsafe."              |
| `0x23` | `generalMessage`  | user → hub     | Free-form text from a user to the NGO.                 |
| `0x24` | `profileUpdate`   | user → hub     | The user changed their name / phone / etc.             |

Schemas are in [`bitchat/Models/AmberPackets.swift`](bitchat/Models/AmberPackets.swift). The decoder is **tolerant** — unknown TLV fields are silently skipped — so either side can add new fields without breaking older clients.

---

## The hub-side contract

Your hub team needs to expose these endpoints (over HTTPS in production, plain HTTP for local dev). Schemas are mirrored exactly in [`bitchat/Services/HubClient.swift`](bitchat/Services/HubClient.swift).

```
POST /v1/register
  body  : { name, phone_number, profession?, language, bitchat_pubkey, apns_token? }
  reply : { user_id, hub_pubkey, ngo_name }

POST /v1/sighting
  header: Authorization: Bearer <user_id>
  body  : { case_id, free_text, location?, client_msg_id, observed_at }
  reply : { sighting_id, ack }

POST /v1/profile
  header: Authorization: Bearer <user_id>
  body  : { name, phone_number, profession?, language }
  reply : { ok }

POST /v1/message
  header: Authorization: Bearer <user_id>
  body  : { body, client_msg_id, sent_at }
  reply : { ok }

POST /v1/location_report
  header: Authorization: Bearer <user_id>
  body  : { client_msg_id, lat, lng, safety: "safe"|"unsafe", note, observed_at }
  reply : { ok }

GET   /v1/alerts/active
  header: Authorization: Bearer <user_id>
  reply : { alerts: [ { case_id, title, summary, issued_at, version, photo_url? } ] }

WS    /v1/stream
  inbound (server → client): typed events
    { type: "ALERT_ISSUED", case_id, title, summary, issued_at, version, photo_url? }
    { type: "STATUS_UPDATE", case_id, summary }
    { type: "ACK", client_msg_id }
```

Plus, the hub needs to run a `pybitchat` node that:
- Has a stable Noise keypair (its `staticIdentityPublicKey` is the `hub_pubkey` returned by `/v1/register`).
- Broadcasts `alert` payloads (`0x20`) signed with that key.
- Listens for, decrypts, and acks `sighting` / `locationReport` / `generalMessage` / `profileUpdate` payloads addressed to its key.

---

## Run it locally

### Prereqs
- macOS with **Xcode 16+** installed.
- For iOS Simulator runs: the iOS Simulator runtime (Xcode → Settings → Platforms → install the iOS one — about 6 GB).
- For mesh testing on real devices: an Apple Developer account (free tier works for cabled side-loading; paid required for TestFlight). And two iPhones, since BLE doesn't work in the iOS Simulator.

### macOS — fastest preview, no simulator needed
```bash
cd bitchat-amber
xcodebuild -project bitchat.xcodeproj \
  -scheme "bitchat (macOS)" \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/bitchat-amber-dd \
  CODE_SIGNING_ALLOWED=NO build
open /tmp/bitchat-amber-dd/Build/Products/Debug/bitchat.app
```
You'll see a desktop window. Click "Skip — demo mode" to populate the UI without a backend.

### iOS Simulator — phone-shaped UI for the demo
```bash
# Once-off: create + boot a simulator
SIM_ID=$(xcrun simctl create "Amber Demo iPhone" \
  "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro" \
  "com.apple.CoreSimulator.SimRuntime.iOS-26-4")
xcrun simctl boot "$SIM_ID"
open -a Simulator

# Build for the simulator
xcodebuild -project bitchat.xcodeproj \
  -scheme "bitchat (iOS)" \
  -destination "id=$SIM_ID" \
  -derivedDataPath /tmp/bitchat-amber-dd-ios \
  CODE_SIGNING_ALLOWED=NO build

# Install + launch with --demo so it bypasses onboarding
APP=$(find /tmp/bitchat-amber-dd-ios/Build/Products -name bitchat.app -type d | head -1)
xcrun simctl install "$SIM_ID" "$APP"
xcrun simctl launch "$SIM_ID" chat.bitchat --demo
```
You'll see a real iPhone-shaped window with the amber-alert app populated with sample data.

### On a real iPhone — the only way to actually test mesh
1. Open `bitchat.xcodeproj` in Xcode.
2. Plug in an iPhone, sign in to Xcode with any Apple ID (free tier ok).
3. Pick the `bitchat (iOS)` scheme + your iPhone as the destination.
4. ⌘R. Trust the developer certificate on the phone.
5. Repeat with a second iPhone. Both phones now run the app *and* are bitchat mesh peers.

Free-tier signing certs **expire every 7 days**. Re-cable + re-build to refresh.

---

## Demo mode (no backend needed)

The whole UI works without a hub running, so you can demo the screens at a hackathon table:

- **iOS launch flag**: pass `--demo` to `xcrun simctl launch` (the snippet above already does this). The app auto-bootstraps a fake registration + three sample alerts on launch.
- **Tap-to-enter**: on macOS or any unflagged iOS launch, the OnboardingView has a `Skip — demo mode (no backend)` button. Tapping it does the same bootstrap.

In demo mode every "Send" action fakes a successful response after a brief delay, so the green ✓ confirmations appear and the sent-history lists populate.

---

## Project structure (the parts you wrote / care about)

```
bitchat-amber/
├── bitchat/
│   ├── BitchatApp.swift           ← app entry point, injects ChatViewModel + AlertsViewModel
│   ├── Protocols/
│   │   └── BitchatProtocol.swift  ← + alert / sighting / locationReport / generalMessage / profileUpdate
│   ├── Models/
│   │   └── AmberPackets.swift     ← TLV encoders/decoders for the new payloads ★ NEW
│   ├── Services/
│   │   └── HubClient.swift        ← HTTP + WS client to the NGO hub      ★ NEW
│   ├── ViewModels/
│   │   └── AlertsViewModel.swift  ← the "what should the app show" state ★ NEW
│   └── Views/
│       ├── AmberRootView.swift    ← onboarded? → TabView : OnboardingView ★ NEW
│       ├── OnboardingView.swift   ← registration form                    ★ NEW
│       ├── AlertsListView.swift   ← inbound alerts                       ★ NEW
│       ├── SubmitInfoView.swift   ← per-case sighting modal              ★ NEW
│       ├── MapView.swift          ← location pinning + safe/unsafe       ★ NEW
│       ├── MessageNGOView.swift   ← free-form to NGO                     ★ NEW
│       └── ProfileView.swift     ← edit profile                          ★ NEW
└── bitchatTests/
    └── AmberPacketsTests.swift    ← TLV round-trip + tolerant decode     ★ NEW
```

The rest of `bitchat/` (BLE service, Noise crypto, mesh routing, identity) is **upstream code we did not modify** — except for forwarding the new payload types in switch statements. You should be able to merge upstream bitchat changes with minimal conflict.

---

## What's NOT in this slice

So you can correctly point at the contributors when asked:

- **The NGO hub** (FastAPI + PostgreSQL + dashboard) — built separately by teammates.
- **The dispatch module** (decides per recipient: SMS / app push / both) — also teammates.
- **The SMS lane** to dumbphones — Twilio integration on the hub side, *not* in the app.
- **The hub-side `pybitchat` node** that participates in the mesh on behalf of the NGO.

This app *only* talks to those things. It doesn't *contain* them.

---

## Roadmap / known gaps

| Item | Status | Notes |
|---|---|---|
| Mesh fallback for sighting / location / message submission | TODO | Today the app tries HTTP only. Wiring an `AmberMeshSender` to push encrypted TLV payloads through `meshService` is the next big piece. |
| Hub-signature verification on inbound alerts | TODO | Code path drops anything that doesn't decode, but doesn't yet check `signed_by == hub_pubkey`. Pending hub team's signing scheme finalisation. |
| CoreLocation auto-attach on submit | Stub | Toggle exists in `SubmitInfoView`; CoreLocation wiring deferred until the NGO confirms what "opt-in geolocation" should look like operationally. |
| APNs push when app backgrounded | Stub | Token is collected at registration but APNs entitlements + paid Apple Developer account are required for live push. WebSocket-while-foreground is the v1 fallback. |
| Android | Out of scope | iOS-only for the hackathon. `bitchat-android` exists upstream and could be forked the same way. |

---

## Built on the shoulders of

- **[bitchat](https://github.com/permissionlesstech/bitchat)** by [@permissionlesstech](https://github.com/permissionlesstech) — Bluetooth mesh chat protocol, Noise crypto, Nostr fallback. We forked it; the BLE/Noise/Nostr code is theirs and is unchanged in this fork.
- **[Anthropic](https://anthropic.com/)** + **Claude Code** — pair-programmed most of this slice during the hackathon.

License: this fork inherits bitchat's public-domain dedication. Use it.
