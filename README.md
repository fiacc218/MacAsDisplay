# MacAsDisplay

**English** | [中文](README.zh.md)

Turn an older Mac into a second display for your newer Mac over Thunderbolt
Bridge or Wi-Fi. HEVC hardware-encoded, 30 fps at native retina resolution,
~1 frame of latency on a good link.

> Status: **alpha / daily-driver for the author**. Uses a private macOS API
> (`CGVirtualDisplay`) — not shippable to the App Store, may break in future
> macOS versions. See [Limitations](#limitations).

```
┌──────────────┐  HEVC/UDP + HMAC ctrl   ┌──────────────┐
│   Main Mac   │──────────────────────▶  │  Secondary   │
│  (Sender)    │    Thunderbolt / Wi-Fi  │   Display    │
└──────────────┘                         └──────────────┘
```

One `.app`, two roles. Install the same DMG on both Macs, pick a role on
first launch.

Works over Wi-Fi (auto-discovery on the local network) or Thunderbolt
Bridge (higher throughput, sub-ms RTT).

## Why not just use…

| Tool | Why it doesn't fit |
|---|---|
| **Sidecar** | iPad only. |
| **Universal Control** | Cursor sharing, not a second display. |
| **AirPlay to Mac** | 1080p cap, higher latency. |
| **Luna / Duet** | Commercial, subscription. |

## Requirements

| | |
|---|---|
| **Main Mac** | macOS 14+, Apple Silicon or Intel with HEVC hardware encoder |
| **Secondary Mac** | macOS 14+, any Mac with HEVC hardware decoder (Intel 7th-gen+ / Apple Silicon) |
| **Link** | Shared Wi-Fi (easiest), or Thunderbolt Bridge cable |

## Install

1. Download **[MacAsDisplay.dmg](https://github.com/fiacc218/MacAsDisplay/releases/latest)**
2. Open the DMG, drag `MacAsDisplay.app` to **Applications** — on **both** Macs
3. Double-click to launch. Notarized + Developer ID signed — no Gatekeeper warning.

## First launch

On **each** Mac, the app asks for a role:

- **Main Mac** — this Mac will send its screen (Sender)
- **Secondary Display** — this Mac becomes the extra screen (Receiver)

You can switch later from the menu-bar icon (**Switch Role…**) or on the
Receiver by pressing **ESC** to exit full-screen and using the control bar.

### Main Mac extras

- Grant **Screen Recording** when prompted (or via the yellow banner in the
  menu-bar popover → *Open Screen Recording settings*).
- A menu-bar icon appears. Click for status, target host, Start/Stop.
- Receivers on the same LAN / TB bridge are **auto-discovered** — click the
  dropdown next to `Target` and pick one.

## Network

Both Macs on the same Wi-Fi works out of the box — just launch the
Receiver, the Sender auto-discovers it, IPs appear in the `Target`
dropdown. HEVC at 30 fps retina is ~20–50 Mbps, well within Wi-Fi 5+
on a reasonable network.

### Thunderbolt Bridge (optional, for max throughput)

Point-to-point cable, 10+ Gbps, sub-ms RTT, no Wi-Fi contention.

1. Connect both Macs with a TB3/TB4 cable.
2. **System Settings → Network → Thunderbolt Bridge → Details → TCP/IP →
   Configure IPv4: Using DHCP with manual address** — assign
   `169.254.0.1` / `169.254.0.2` (or any pair on the same /16).
3. `sudo ifconfig bridge0 mtu 9000` on both sides enables jumbo frames
   (avoids IP fragmentation on large I-frames).

## Using it

1. Launch MacAsDisplay on the **Secondary Display** Mac first — it goes
   full-screen black and starts announcing itself.
2. Launch on the **Main Mac**. `Target` auto-fills; if multiple interfaces,
   pick from the dropdown.
3. Click **Start**. A new 30 fps virtual display appears — drag any window
   across and it lights up on the other Mac.

On the Receiver, press **ESC** anytime to exit full-screen and reveal a
control bar (**Return to Fullscreen** / **Switch Role…** / **Quit**).

## Security model

- Control channel authenticated with HMAC-SHA256 + nonce replay protection.
- Ships with a built-in default PSK — zero-config on first install.
- Video payload **is not encrypted.** Don't run this on an untrusted
  network. Use Thunderbolt Bridge or a private LAN.
- Want your own PSK? `head -c 32 /dev/urandom > ~/.config/macasdisplay/psk`
  on one Mac, `scp` to the other. Details in [SECURITY.md](SECURITY.md).

## Troubleshooting

**Secondary Mac shows only black.** Click **Start** on the Main Mac — the
Secondary alone doesn't trigger streaming. Check both logs for `PSK fp=...`:
fingerprints must match.

**"User denied screen capture" even after granting.** A stale TCC entry
from a previous version's signature. Clear it:
```sh
tccutil reset ScreenCapture xyz.dashuo.macasdisplay
```
then re-grant. One-time after major-version installs; subsequent updates
preserve the grant.

**Secondary Mac screensaver interrupts playback.**
```sh
caffeinate -d -i -s -w $(pgrep MacAsDisplay)
```

**Menu-bar icon invisible on notched MBPs.** The notch crowds right-side
icons. Use [Bartender](https://www.macbartender.com/) /
[Hidden Bar](https://github.com/dwarvesf/hidden), or set
`VS_AUTOSTART=1` to run headless.

## Limitations

- **`CGVirtualDisplay` is a private macOS API.** Apple may break it; not
  App-Store-distributable.
- **No input forwarding** — by design. Use the Main Mac's keyboard/mouse;
  macOS routes the cursor across the virtual display natively.
- **No audio.** Video only.
- **Single display per Main Mac session.**

## Build from source

For contributors. End users should just grab the DMG above.

```sh
git clone https://github.com/fiacc218/MacAsDisplay.git
cd MacAsDisplay
brew install xcodegen
./build.sh                    # → build/Build/Products/Debug/MacAsDisplay.app
```

`build.sh` regenerates the xcodeproj from `project.yml` when needed. Prefer
the IDE? `xcodegen generate && open MacAsDisplay.xcodeproj`.

See [SECURITY.md](SECURITY.md) before filing PRs that touch the wire
protocol or authentication.

## License

Apache License 2.0. See [LICENSE](LICENSE).

MacAsDisplay is not affiliated with or endorsed by Apple Inc.
