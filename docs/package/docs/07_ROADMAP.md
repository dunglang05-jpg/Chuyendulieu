# 07 — Implementation Roadmap

## M0: Audit
Inspect repository, toolchain, dependencies, current code, signing setup and test hardware. Build baseline where possible.

## M1: Shared protocol and domain
Create symmetric peer model, capability schema, data category registry, manifest, state machine, error model, threat model and protocol tests.

## M2: Android ↔ Android POC
LAN TCP/TLS baseline, QR pairing, transfer engine, progress, SHA-256, interruption/resume and physical-device tests.

## M3: Android → iPhone POC
Implement iOS receiver and Android sender. Start with documents, vCard contacts and user-selected photos/videos. Build on macOS/Xcode and test on a physical iPhone. This is an early mandatory cross-platform milestone, not a deferred optional feature.

## M4: iPhone → Android
Implement iOS sender and Android receiver, with user-selected data and correct import APIs.

## M5: iPhone → iPhone
Implement and test both iOS roles.

## M6: Connectivity expansion
Evaluate Nearby, Wi-Fi Direct/hotspot, QUIC and USB independently. Do not promote experimental transport without real-device evidence.

## M7: Hardening
Security review, compatibility, accessibility, localization, performance, crash recovery and privacy disclosures.

## M8: Release candidate
Signed builds, full four-direction matrix, support documentation, privacy policy and release checklist.
