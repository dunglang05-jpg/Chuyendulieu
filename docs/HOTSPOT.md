# "Điểm phát" — direct phone-to-phone Wi-Fi (no router)

Status: **IMPLEMENTED, NOT TESTED ON DEVICES.** Do not describe it as supported until the device tests below pass.

## Why

Device test 2026-11-09 (logs from both phones, same transfer of 89 files / 2.90 GB):

- The sender (Wi-Fi link 866 Mbps) spent 857 s blocked writing to the socket. The receiver (realme RMX5268, Android 16, Wi-Fi link **54 Mbps at 5 GHz**) spent 772 s waiting for network data. Disk work on the receiver (open + write + sync + commit) was about 52 s in total.
- The measured transfer rate (~3.0–3.6 MB/s) matches what a 54 Mbps Wi-Fi link can carry. The bottleneck was the receiver's link to the router, not the app.

Taking the router out of the path (like OPPO Clone Phone / Samsung Smart Switch) avoids a weak router link. How much faster it actually is must be **measured** on the phones; no speed figure is claimed here.

## How it works

Default mode on Android since 2026-11-09 (user request: "no shared Wi-Fi, use 5 GHz when both phones can").

| Step | Android host (shows the QR) | Android joiner | iPhone joiner |
|---|---|---|---|
| 0 | Wi-Fi must be **on**. It does not need to be connected to any network | same | same |
| 1 | Asks for "Nearby devices" (Android 13+) or Location (Android 10–12), in context | same permission | — |
| 2 | **Wi-Fi Direct group** (`WifiP2pManager.createGroup`) with a random name `DIRECT-xy-ChuyenDL` and a 16-character password: 5 GHz (`GROUP_OWNER_BAND_5GHZ`) if this phone supports 5 GHz, otherwise any band. If the 5 GHz group cannot be created, it retries on any band, then falls back to `LocalOnlyHotspot` | — | — |
| 3 | The QR carries `ap: {s, k, sec, m, b}` (mode `p2p`/`ap`, band `5`/`2`/`a`). The group owner address is listed first | scans | scans |
| 4 | — | Wi-Fi Direct: `WifiP2pManager.connect` with name and password. No pairing dialog is expected, because both sides already know the credentials. Hotspot fallback: `WifiNetworkSpecifier` (system dialog) + `bindProcessToNetwork` | `NEHotspotConfiguration` (joinOnce) to the same name and password, as an ordinary WPA2 network |
| 5 | Same TLS pairing as before: certificate pin from the QR, 6-digit code, HMAC proofs | | |
| 6 | The group or hotspot is closed when the session ends | group left | configuration removed |

**5 GHz "only when both phones support it":**
- The host picks 5 GHz only when its own radio supports it.
- An Android joiner checks its own support (`is5GHzBandSupported`). If the QR says 5 GHz and the joiner has no 5 GHz radio, it shows "use 2.4 GHz". The host's QR screen has a "Dùng 2,4 GHz" button that recreates the group on 2.4 GHz.
- An iPhone cannot report its band support to the app. All current iPhones have 5 GHz.

- **An iPhone cannot be the host.** iOS gives apps no API to create a hotspot. For i→A and A→i, the Android phone must show the QR.
- **i→i is not possible in this mode.** Use normal Wi-Fi instead.
- **iPhone joining needs the "Hotspot Configuration" capability** (entitlement `com.apple.developer.networking.HotspotConfiguration`) on the Runner target and its provisioning profile.
  - Add it in Xcode: Runner → Signing & Capabilities → + Hotspot Configuration.
  - Without it, the join fails and the app shows the network name and password. The user joins in Settings › Wi-Fi and taps "Đã vào mạng, tiếp tục".

## Security notes

- The hotspot name and password are created by the OS for this session only and vanish when the hotspot closes. They are shown only inside the QR on the host's screen, and in the manual iPhone fallback. They are never logged: the diagnostic log records only `hotspot state=started|joined|failed code=…`, and `HotspotInfo.toString()` is redacted.
- Joining the hotspot does not add trust. The TLS certificate pin, SAS confirmation and HMAC proofs are unchanged. Someone else on the hotspot would still fail authentication.
- No Internet is shared, and no location is used. `NEARBY_WIFI_DEVICES` is declared `neverForLocation`. Android 10–12 still require the location permission for these Wi-Fi APIs.

## Known limitations / risks to check on devices

- **Shared phone hotspot:** if the phone's own hotspot is already on, the LocalOnlyHotspot fallback fails with `HOTSPOT_INCOMPATIBLE_MODE`. The app asks the user to turn it off.
- **Wi-Fi Direct busy:** screen casting or another Wi-Fi Direct session can make group creation fail (`HOTSPOT_BUSY`).
- **Concurrent router + 5 GHz group:** on single-radio phones that are connected to a 2.4 GHz router, a 5 GHz group may be refused. The app then retries on any band, and the log records the band actually used (`status=p2p_5|p2p_2|p2p_a|ap_a`).
- **Single radio:** on phones that cannot do router Wi-Fi and hotspot at the same time, the host or joiner leaves the router network during the transfer. This is expected.
- **Band:** the system chooses the hotspot band (not exposed to apps). A 2.4 GHz hotspot may be slower than a good router link.
- **Joiner link drop:** the binding to the hotspot network is kept, so the existing resume logic redials over the same link.
- **No auto cable switch:** the automatic Wi-Fi → cable switch is not combined with this mode.

## Device test plan (must pass before calling it supported)

1. A→A: host Android 13+ and Android 10–12. Check that the permission dialog, the system join dialog, the transfer and the hotspot shutdown all work.
2. A→i and i→A with the Android phone as host: with the entitlement (automatic join) and without it (manual join).
3. Measure MB/s for the same files over the router and over "Điểm phát" on the same phones. Record the band from the log (`hotspot … status=`). Record the link rates from both phones' Wi-Fi settings.
4. Interrupt the transfer: move the phones apart, turn the screen off, deny the join dialog, or have the phone's own hotspot already on. Check that the transfer resumes or that a clear error is shown.
5. After the transfer: confirm that both phones are back on their normal Wi-Fi and that no hotspot is still running.
