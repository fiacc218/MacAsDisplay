# MacAsDisplay

**English** | [中文](README.zh.md)

Second-display app for two Macs. The older Mac becomes an extra monitor
for the newer one over Wi-Fi or Thunderbolt Bridge.

> alpha · uses `CGVirtualDisplay` (private macOS API) · not App Store
> distributable · see [Limitations](#limitations)

```
┌──────────────┐   HEVC over UDP + HMAC   ┌──────────────┐
│   Main Mac   │ ───────────────────────▶ │  Secondary   │
│   (Sender)   │    Wi-Fi / Thunderbolt   │   Display    │
└──────────────┘                          └──────────────┘
```

## Highlights

- **HEVC hardware encode/decode** (VideoToolbox) · 30 fps · native retina
  resolution · ~1 frame latency on a good link
- **Single notarized DMG** · same `.app` on both Macs · pick role on first
  launch · Developer ID signed, no Gatekeeper prompt
- **Zero-config pairing** · built-in PSK · HMAC-SHA256 authenticated
  control channel with nonce replay protection
- **Auto-discovery** · Sender finds Receivers on the local network /
  Thunderbolt bridge via UDP broadcast
- **Universal binary** (arm64 + x86_64) · Apple Silicon and Intel (HEVC
  capable) supported on both sides
- **Localized** · English / 简体中文, follows system language
- **Free, open source** · Apache 2.0

## Requirements

| | |
|---|---|
| **Main Mac** | macOS 14+, HEVC hardware encoder (Apple Silicon / Intel 7th-gen+) |
| **Secondary Mac** | macOS 14+, HEVC hardware decoder (Apple Silicon / Intel 7th-gen+) |
| **Link** | Same Wi-Fi, or a Thunderbolt 3/4 cable |

## Install

1. Download **[MacAsDisplay.dmg](https://github.com/fiacc218/MacAsDisplay/releases/latest)**.
2. Open the DMG, drag `MacAsDisplay.app` to **Applications** on **both** Macs.
3. Double-click to launch.

## Usage

On each Mac, the app asks for a role on first launch:

- **Main Mac** — sends its screen (Sender). Lives in the menu bar.
- **Secondary Display** — receives and renders full-screen (Receiver).

Then:

1. Launch on the **Secondary** first — it goes full-screen, announces
   itself, and lists its own IPs on the idle screen.
2. Launch on the **Main** — the Secondary's IP auto-fills in `Target`
   (multi-interface: pick from the dropdown).
3. Grant **Screen Recording** permission when prompted.
4. Click **Start**. A new 30 fps virtual display appears — drag any
   window across.

Role changes later: menu-bar icon → **Switch Role…**, or on the
Receiver press **ESC** for the control bar.

## Network

Same Wi-Fi works out of the box — auto-discovery finds the Receiver. HEVC
at 30 fps retina is ~20–50 Mbps.

Thunderbolt Bridge (optional, for maximum bandwidth):

1. Connect both Macs with a TB3/TB4 cable.
2. **System Settings → Network → Thunderbolt Bridge → Details → TCP/IP →
   Using DHCP with manual address** — assign `169.254.0.1` / `169.254.0.2`
   (or any pair on the same /16).
3. `sudo ifconfig bridge0 mtu 9000` on both sides enables jumbo frames.

## Security model

- Control channel: HMAC-SHA256 + per-peer nonce high-water, replay-safe.
- Built-in default PSK for zero-config first install.
- Video payload is **not** encrypted — use Wi-Fi you trust or a direct TB
  cable. Don't run on public networks.
- Custom PSK: `head -c 32 /dev/urandom > ~/.config/macasdisplay/psk` on
  one Mac, `scp` to the other. See [SECURITY.md](SECURITY.md).

## Troubleshooting

**Secondary shows only black.** Click **Start** on the Main Mac. Check
both logs for `PSK fp=…` — the fingerprints must match.

**"User denied screen capture" even after granting it.** Stale TCC entry
from a previous signature:
```sh
tccutil reset ScreenCapture xyz.dashuo.macasdisplay
```
One-time after major-version installs; subsequent updates keep the grant.

**Screensaver on the Secondary interrupts playback.**
```sh
caffeinate -d -i -s -w $(pgrep MacAsDisplay)
```

**Menu-bar icon hidden behind the notch.** Use
[Bartender](https://www.macbartender.com/) /
[Hidden Bar](https://github.com/dwarvesf/hidden), or set
`VS_AUTOSTART=1` to run headless.

## Limitations

- `CGVirtualDisplay` is a private macOS API; Apple may change or remove
  it. Cannot ship to the App Store.
- No input forwarding — by design. Use the Main Mac's keyboard/mouse;
  macOS routes the cursor across the virtual display natively.
- No audio.
- One virtual display per Main Mac session.

## Build from source

```sh
git clone https://github.com/fiacc218/MacAsDisplay.git
cd MacAsDisplay
brew install xcodegen
./build.sh                    # → build/Build/Products/Debug/MacAsDisplay.app
```

`build.sh` regenerates the xcodeproj from `project.yml` when needed. Or
`xcodegen generate && open MacAsDisplay.xcodeproj` for the IDE.

See [SECURITY.md](SECURITY.md) before filing PRs that touch the wire
protocol or authentication.

## License

Apache License 2.0. See [LICENSE](LICENSE).

MacAsDisplay is not affiliated with or endorsed by Apple Inc.
