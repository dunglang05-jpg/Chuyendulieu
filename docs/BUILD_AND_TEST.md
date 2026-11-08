# Build & test — exact commands

Nothing below has been run in the authoring environment except section 1. Record the real output of every command in the milestone report; do not summarise failures away.

## 0. Toolchain

| Tool | Needed for | Version to record |
|---|---|---|
| Flutter (stable, ≥ 3.22) + Dart ≥ 3.4 | app, Dart tests | `flutter --version` |
| Android SDK 34, JDK 17 | Android build | `sdkmanager --list_installed`, `java -version` |
| macOS + Xcode 16+ + CocoaPods | iOS build (Xcode 16 SDK needed for the iOS 18 `.limited` contacts check) | `xcodebuild -version`, `pod --version` |
| Python 3.10+ | reference peer | `python3 --version` |
| 2 Android phones (Android 10–15, ideally 2 OEMs) + 2 iPhones (iOS 16–18) | release gate | model, OS build |

## 1. Reference peer (runs anywhere, already verified)

```bash
cd tools/reference_peer
python3 -m pip install cryptography pytest pytest-asyncio pytest-timeout
python3 -m pytest -q --timeout 60            # expected: 45 passed
python3 bench/loopback_bench.py 1024          # loopback only; NOT a phone number
python3 ../syntax_check.py ../../app ../../packages   # syntax only
```

## 2. Generate runner projects and fetch packages

```bash
cd app
./tool/bootstrap.sh          # flutter create (adds missing files only), minSdk 29, iOS Info.plist keys, Podfile 14.0
flutter pub get
flutter analyze              # must be clean before M2 sign-off
```

## 3. Dart tests (VM, no phone needed)

```bash
cd app
flutter test test/protocol_vectors_test.dart   # Dart == Python on proofs, SAS, QR, paths, frame bytes
flutter test test/domain_test.dart             # plan intersection for all 4 directions, state machine
flutter test test/loopback_transfer_test.dart  # real TLS on 127.0.0.1: both QR directions, resume, wrong fp, traversal
```

## 4. Cross-implementation interop (Dart app ↔ Python peer, same LAN)

```bash
# Desktop shows the QR, phone scans it and sends (phone = Android or iPhone):
cd tools/reference_peer
python3 -m ptp_ref host receive --dir ./inbox --bind 0.0.0.0 --advertise <desktop-LAN-IP>
# Phone shows the QR, desktop sends to the phone:
python3 -m ptp_ref join send --uri 'ptp://pair?d=…' ./sample/*.jpg ./sample/contacts.vcf
```
Paste the QR URI via any QR-to-text app, or add a "copy QR link" debug button.

## 5. Device builds

```bash
cd app
flutter build apk --release        # unsigned → sign before distribution
flutter run -d <android-id>
flutter build ios --release        # macOS only; set signing team in Xcode first
flutter run -d <iphone-id>
```

## 6. Device test matrix

Run `docs/TEST_MATRIX.md` for each of the four directions. A direction moves to "supported" in `docs/STATUS.md` only with a filled-in row per scenario (device, OS build, app build, network, file set, raw log, result).
