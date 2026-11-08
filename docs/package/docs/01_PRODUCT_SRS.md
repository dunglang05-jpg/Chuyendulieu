# 01 — Product Requirements (SRS)

## Product statement
Phone Transfer Pro transfers user-selected data directly between two mobile devices, without a computer intermediary. It is a symmetric peer-to-peer migration product supporting Android and iOS in both sender and receiver roles.

## Supported directions
| Direction | Required endpoint roles | Priority |
|---|---|---|
| Android → Android | Android Sender + Android Receiver | POC baseline |
| Android → iPhone | Android Sender + iOS Receiver | Mandatory early cross-platform POC |
| iPhone → Android | iOS Sender + Android Receiver | Required |
| iPhone → iPhone | iOS Sender + iOS Receiver | Required |

## User goals
- Understand what can and cannot be migrated before starting.
- Pair devices simply with QR.
- Select categories and preview estimated size.
- Transfer without Internet when local network is available.
- See accurate progress and per-file status.
- Resume safely after interruptions.
- Verify data integrity.
- Receive a truthful completion report including partial/unsupported categories.

## Functional requirements
FR-01 Both devices can act as sender or receiver.
FR-02 QR pairing and manual session-code fallback.
FR-03 Mutual peer confirmation.
FR-04 Capability exchange before scanning.
FR-05 Per-platform data category availability.
FR-06 Preview selected categories, item count and estimated size.
FR-07 Check destination capacity before transfer.
FR-08 Stream files with bounded memory.
FR-09 Pause, resume and cancel.
FR-10 SHA-256 verification.
FR-11 Safe import using platform APIs.
FR-12 Detailed transfer report.
FR-13 Localization-ready Vietnamese/English UI.
FR-14 Diagnostics without sensitive content.

## Non-functional requirements
- Security by default.
- No private app-data extraction.
- Bounded RAM and concurrency.
- Robust error handling and recovery.
- Accessible UI and clear permission explanations.
- Platform-specific limitations visible before transfer.

## Out of scope unless officially authorized
- Reading another app's private sandbox.
- Moving login sessions/tokens/cookies/passwords/OTP.
- Installing arbitrary iOS apps or silently restoring app containers.
- Root/jailbreak/exploit or security bypass.
- Full-device clone guarantees.
