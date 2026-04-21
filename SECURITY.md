# Security Model

MacAsDisplay is designed for **trusted, short-haul links between two of
your own machines** — Thunderbolt Bridge direct-cable or a private LAN you
control. It is not a general-purpose screen-sharing tool, and **must not be
exposed to the public internet or to networks with untrusted peers**.

## Threat model

### In scope
- **Passive eavesdroppers on the control channel.** Control packets (Hello,
  Capability, KeyframeRequest) carry an HMAC-SHA256 tag keyed with a
  pre-shared 32-byte secret. A listener without the PSK cannot forge
  accepted packets.
- **Active replay.** Each control packet carries a monotonically increasing
  8-byte nonce; the receiver tracks the high-water nonce per peer and
  drops anything ≤. Replayed packets are rejected silently.
- **Active injection.** Without the PSK, an attacker cannot construct a
  packet that verifies, so they cannot force unwanted keyframe requests or
  announce fake capabilities.

### Out of scope
- **Confidentiality of video.** Video payload is plaintext UDP. A passive
  attacker on your link can reconstruct the pixel stream. **If that
  matters, use MacAsDisplay only over a direct Thunderbolt Bridge cable
  or a physically-private LAN** — or do not use MacAsDisplay at all.
- **PSK leakage.** The PSK lives at `~/.config/macasdisplay/psk` with mode
  0600. Anyone with read access to that file on either machine (or a
  backup of it) can impersonate the peer.
- **Traffic analysis / timing side-channels.** Packet sizes and timing
  leak what kind of content is on-screen (UI vs. video vs. text).
- **Denial of service from an on-link attacker.** Flooding the Receiver
  with packets will still waste CPU on HMAC verification even if all are
  rejected.
- **Compromise of either endpoint.** If the Sender is compromised, the
  attacker has access to the display frame buffer anyway; MacAsDisplay
  does not defend against this.

## What the authentication does and doesn't do

It is there to make sure a **random device on your Wi-Fi can't** send
`KeyframeRequest` storms, spoof Capability, or trick your Sender into
binding a virtual display at the wrong resolution. It is **not** there to
make MacAsDisplay safe on public networks — the lack of video encryption
alone disqualifies that use.

## Recommendations

- **Prefer Thunderbolt Bridge.** It is a point-to-point cable; there is no
  "link" to share with attackers.
- **Rotate the PSK** by deleting the file on both ends and re-copying when
  you have reason to suspect it leaked (e.g. shared machine, stolen backup).
- **Never commit the PSK** to git. It is in `.gitignore`; if you see it
  tracked, revoke it immediately.
- **Check the fingerprint.** Both apps log `PSK fp=<first 16 hex>` at
  startup. If the fingerprints don't match, the apps will not be able to
  talk.

## Reporting a vulnerability

Please open a private security advisory on GitHub. For now there is no
dedicated email; the maintainers will respond via GitHub.

Please **do not** file public issues for anything that looks like a
practical attack against the auth protocol, the PSK storage, or the C++
packet-reassembly code — those are the surfaces worth disclosing
privately.
