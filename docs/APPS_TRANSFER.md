# Category "Ứng dụng" — move installed apps (Android → Android)

Status: **IMPLEMENTED, NOT TESTED ON DEVICES.**

## What it does
- **Sender (Android):**
  - Lists the apps the user installed (not system apps, not this app) using `QUERY_ALL_PACKAGES`.
  - Packs each app's APK files (base plus split APKs) into one uncompressed ZIP, `Apps/<package>.apks`, then transfers it like any other file: TLS, SHA-256, resume.
  - The user picks the apps in a list. All apps are selected by default.
- **Receiver (Android):**
  - Installs each package with `PackageInstaller`. **Android shows its own "Install?" dialog for every app**, and the user taps it.
  - The first time, the system asks to allow "Install unknown apps" for Chuyển dữ liệu.
  - Apps that are already installed are skipped.

## What it does not do (platform limits, not bugs)
- **No silent install.** Only OEM system apps (Clone Phone, Smart Switch on Samsung, Mi Mover) or device-owner/root setups can install without a prompt. On non-Samsung phones Smart Switch has the same limits as this app (device check 2026-11-13).
- **No app data:** no chats, logins or settings. `/data/data/<pkg>` is private to each app. Device-to-device backup is only available to privileged system apps, and apps can exclude data from it.
- **iPhone:** no export and no install of other apps (App Store only).
- **Banking/wallet apps** may refuse to run when not installed from Google Play (Play Integrity). The UI tells users to reinstall those from Play.
- `QUERY_ALL_PACKAGES` and `REQUEST_INSTALL_PACKAGES` are policy-restricted on Google Play. A Play build would need a declaration or would have to drop this category. Sideloaded builds are unaffected.

## Error codes shown to the user
`INSTALL_CANCELLED`, `INSTALL_PERMISSION`, `INSTALL_CONFLICT` (a copy with a different signature is installed), `INSTALL_INCOMPATIBLE`, `INSTALL_STORAGE`, `INSTALL_BLOCKED`, `INSTALL_TIMEOUT`, `NO_APK`.

## Device test plan
1. A→A with 3 apps: one single-APK app, one split-APK app (most Play apps), and one that is already installed on the receiver.
2. Cancel one install dialog. Then deny "Install unknown apps", grant it, and retry.
3. Check that the installed apps open, and record which ones refuse (Play Integrity).
4. iPhone as receiver: "Ứng dụng" must not be offered.
