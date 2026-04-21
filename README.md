# MacAsDisplay

**English** | [中文](README.zh.md)

Turn an older Mac into a second display for your newer Mac over Thunderbolt
Bridge or Wi-Fi. HEVC hardware-encoded, 30 fps at native retina resolution,
~1 frame of latency on a good link.

> Status: **alpha / daily-driver for the author**. Uses a private macOS API
> (`CGVirtualDisplay`) — not shippable to the App Store, may break in future
> macOS versions. See [Limitations](#limitations).

---

## What it is

```
┌──────────────┐  HEVC/UDP + HMAC ctrl   ┌──────────────┐
│   Sender     │──────────────────────▶  │   Receiver   │
│ (primary Mac)│    Thunderbolt / Wi-Fi  │  (old Mac)   │
│              │                         │              │
│ VirtualDisplay│                         │ HW decoder   │
│ ScreenCapture│                         │ Metal render │
│ VT encoder   │                         │ Full-screen  │
└──────────────┘                         └──────────────┘
```

- **Sender** creates a headless virtual display, captures it with
  ScreenCaptureKit, hardware-encodes HEVC via VideoToolbox, ships it over UDP.
- **Receiver** hardware-decodes and renders full-screen with Metal.
- **Display only.** No input forwarding — macOS's native multi-display cursor
  routing handles everything.

## Why not just use …

| Tool | Why it doesn't fit |
|---|---|
| **Sidecar** | iPad only. |
| **Universal Control** | Cursor/keyboard sharing between Macs — not a second display. |
| **AirPlay to Mac** | 1080p cap, higher latency, Apple-only. |
| **Luna / Duet** | Commercial, closed-source, subscription. |
| **DDC over USB-C** | Panel has to be DP-in capable (old MBPs aren't). |

MacAsDisplay exists because you have a perfectly good older Mac sitting in a
drawer and want to use it as a ~3K 30 fps second screen, for free, over a
cable you already own.

## Requirements

| Role | Requirement |
|---|---|
| Both | macOS 14+ (Sonoma), Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |
| Sender | Apple Silicon or recent Intel with HEVC hardware encoder |
| Receiver | Any Mac with HEVC hardware decoder (Intel 7th-gen+ / any Apple Silicon) |
| Link | **Thunderbolt Bridge** direct-cable (recommended), or shared Wi-Fi |

## Build

```sh
git clone https://github.com/fiacc218/MacAsDisplay.git
cd MacAsDisplay
brew install xcodegen            # one-time
./build.sh all                   # → build/Build/Products/Debug/*.app
```

That's it. `build.sh` regenerates the xcodeproj when `project.yml` changes,
then builds both schemes. Common invocations:

| Command | What it does |
|---|---|
| `./build.sh sender` | Local Sender build. |
| `./build.sh receiver` | Receiver, cross-compiled `x86_64` by default (for old Intel Macs). |
| `./build.sh all` | Both of the above. |
| `./build.sh deploy user@old-mac` | Build Receiver → rsync → ad-hoc codesign → relaunch on remote. |
| `CONFIG=Release ./build.sh all` | Release build instead of Debug. |
| `RECEIVER_ARCH=arm64 ./build.sh receiver` | Apple-Silicon Receiver. |
| `./build.sh clean` | Wipe `build/` and regenerated `.xcodeproj`. |

Prefer the IDE? `xcodegen generate && open MacAsDisplay.xcodeproj` still works
— the two schemes (**Sender** / **Receiver**) show up in Xcode as usual.

### Signing (optional but recommended)

Default signing is ad-hoc (`CODE_SIGN_IDENTITY = -`), so `xcodebuild` works
with no Apple ID configured. Downside: macOS TCC treats every rebuild as a
new identity, so **you'll re-approve Screen Recording / Local Network after
every build.**

To avoid that, create a local, gitignored `Config.xcconfig`:

```sh
cp Config.xcconfig.example Config.xcconfig
# Edit Config.xcconfig — fill in your own signing identity fingerprint
# (Apple Development or Developer ID).
```

TCC binds grants to the signing identity — with a stable cert, rebuild
without re-permissioning.

## Deploy & Run

### 1. Sender (on your primary Mac)

```sh
./build.sh sender
open build/Build/Products/Debug/MacAsDisplaySender.app
```

First launch triggers **Screen Recording** and **Local Network** TCC
prompts. Grant both in System Settings, then relaunch the app.

The app installs a **menu-bar icon** (`LSUIElement`, no Dock icon). Click
to open the popover — target host, start/stop, status.

> **Notch-model MBP users (14"/16"):** the menu-bar icon can be hidden by
> apps crowding the notch. Use `VS_AUTOSTART=1` to bypass the UI entirely
> (see [Headless run](#headless-run)).

### 2. Receiver (on your old Mac)

Three ways, pick whichever fits.

**A — one-liner install (recommended, no Xcode on old Mac).** On the old
Mac, open Terminal and paste:

```sh
curl -fsSL https://raw.githubusercontent.com/fiacc218/MacAsDisplay/main/install.sh | sh
```

Downloads the latest pre-built Receiver from GitHub Releases, strips macOS
quarantine, ad-hoc re-signs, installs to `/Applications/`, launches. The
script is 50 lines, sitting at `install.sh` in the repo — read it first if
you prefer (`curl -fsSL ...install.sh | less`).

**B — build on the old Mac itself (for hackers).** Old Mac has Xcode?
Skip the deploy dance entirely:

```sh
git clone https://github.com/fiacc218/MacAsDisplay.git
cd MacAsDisplay && brew install xcodegen && ./build.sh receiver
open build/Build/Products/Debug/MacAsDisplayReceiver.app
```

**C — cross-compile + ssh deploy from primary Mac (dev loop).**

```sh
./build.sh deploy user@old-mac        # rsync to /Applications + auto-launch
# or ./build.sh deploy user@old-mac:/custom/path
```

> Prereq: old Mac has **System Settings → General → Sharing → Remote
> Login** (SSH) on. Recommend adding the primary Mac's public key to
> `~/.ssh/authorized_keys` for passwordless deploys.

The Receiver opens a full-screen black window and starts announcing its
capability every 2 s. Press **ESC** to exit full-screen; ESC again to quit.

## Pairing (first time)

MacAsDisplay authenticates the control channel with a 32-byte pre-shared
key (HMAC-SHA256 per packet, nonce-based replay protection). On first
launch each app auto-generates a PSK at:

```
~/.config/macasdisplay/psk
```

**Copy it to the other machine** (same path) before they can talk:

```sh
scp ~/.config/macasdisplay/psk user@receiver-mac:~/.config/macasdisplay/psk
```

Both apps log `PSK fp=<first 16 hex>` at startup. **Fingerprints must match
on both sides.** If they don't, control packets are silently rejected.

For throwaway testing: `VS_PSK_HEX=<64 hex chars>` env var overrides the
file.

## Configuring the target

The Sender needs to know where to send packets. Two options:

### Option A — menu-bar popover (interactive)

Click the status item, type the Receiver's IP in the **Target** field,
click **Start**. Persisted in `defaults` — next launch auto-fills.

### Option B — `defaults` one-liner (scriptable)

```sh
defaults write xyz.dashuo.macasdisplay.sender VS.targetHost 192.168.1.99
```

Find the Receiver's IP:

- **Thunderbolt Bridge:** `ifconfig bridge0 | grep 'inet '` on the Receiver
  (typically `169.254.x.x` link-local).
- **Wi-Fi:** `ipconfig getifaddr en0` on the Receiver.

### Option C — auto-learn (zero-config)

If Receiver first sends Hello / Capability toward a known host, Sender
learns the peer from `recvfrom` and talks back. In practice you still set
the target once via A or B — auto-learn just survives IP changes.

## Thunderbolt Bridge (recommended)

TB Bridge is a point-to-point cable, 10+ Gbps, sub-ms RTT, no contention
with Wi-Fi / AWDL / Bonjour.

1. Connect both Macs with a TB3/TB4 cable.
2. **System Settings → Network → Thunderbolt Bridge → Details → TCP/IP →
   Configure IPv4: Using DHCP with manual address** — assign
   `169.254.0.1` / `169.254.0.2` (or any pair on the same /16).
3. Verify: `ping -c 3 169.254.0.2` from the other side.
4. Set the Receiver's TB IP as the Sender's `VS.targetHost`.

**Jumbo frames (optional):** raising MTU to 9000 on `bridge0` on both sides
lets you push much larger UDP payloads without fragmentation — big I-frames
stop exploding into hundreds of 1500-byte fragments.

```sh
sudo ifconfig bridge0 mtu 9000
```

## Using it

1. Launch **Receiver** first — it sits on a black full-screen window.
2. Launch **Sender** — menu-bar icon appears. `Target` auto-fills from
   Receiver's announcements.
3. Click **Start**. A new 30 fps virtual display appears on the Sender,
   sized to the Receiver's panel. Drag a window across; it lights up.

## Headless run

```sh
VS_AUTOSTART=1 open -n /path/to/MacAsDisplaySender.app
```

Sender starts without showing any UI; waits ~1.5 s for the Receiver's
Capability, then starts streaming. Useful when the menu-bar icon is
crowded out by the notch.

## Troubleshooting

### Receiver shows only black

1. Did the Sender actually **click Start**? (Auto-learn doesn't start
   streaming — you still have to trigger it.)
2. PSK fingerprints match? Check both logs for `PSK fp=...`.
3. Firewall allowing UDP on ports 52100 (video) and 52101 (control)?
4. Try `VS_PSK_HEX=...` on both sides to rule out PSK-file issues.

### "User denied screen capture" (TCC -3801)

Sender needs **Screen Recording**. System Settings → Privacy & Security →
Screen Recording → toggle on. If the toggle is already on, toggle off +
on (TCC caches stale signatures):

```sh
tccutil reset ScreenCapture xyz.dashuo.macasdisplay.sender
```

### Old Mac's screensaver keeps interrupting

```sh
caffeinate -d -i -s -w $(pgrep MacAsDisplayReceiver)
```

Keeps display / idle / sleep blocked for the lifetime of the Receiver.

### Menu-bar icon invisible

14"/16" MBPs with the notch crowd out right-side icons. Workarounds:

- Use [Bartender](https://www.macbartender.com/) / [Hidden Bar](https://github.com/dwarvesf/hidden).
- Use headless mode: `VS_AUTOSTART=1`.

### Occasional `-17694` decode errors

Happens after packet loss or network hiccups; the decoder recovers on the
next keyframe (Receiver auto-requests one). Nothing to fix.

### WindowServer crashes on old Intel Macs

Fixed in the MetalRenderer — the renderer now uses displayLink-pull with
2-frame GPU backpressure. If you see this, you're on an older commit;
update.

## Security model

- Control channel is **authenticated** (PSK + HMAC-SHA256) and
  **replay-protected** (per-peer nonce high-water).
- Video payload is **not encrypted.** Anyone on your link can sniff it.
- **Do not run this on an untrusted network.** Use Thunderbolt Bridge or
  a private LAN. See [SECURITY.md](SECURITY.md).

## Limitations

- **`CGVirtualDisplay` is a private macOS API.** Symbols are `dlopen`'d at
  runtime. Apple can remove/change them any release. Cannot ship to the
  App Store.
- **No input forwarding.** By design. Use the Sender's keyboard/mouse;
  macOS routes the cursor across the virtual display natively.
- **No audio.** Video only.
- **Single display per Sender session.**
- **Lossy links → more I-frames.** Receiver requests a keyframe on packet
  loss, costing bandwidth. Wi-Fi is tolerable; TB Bridge is ideal.

## Contributing

Issues and PRs welcome. Please read [SECURITY.md](SECURITY.md) before
filing anything touching the wire protocol or authentication.

## License

Apache License 2.0. See [LICENSE](LICENSE).

MacAsDisplay is not affiliated with or endorsed by Apple Inc.
