# 02 — System Architecture

## High-level layers
1. Presentation: Flutter screens, accessibility, progress.
2. Domain: migration orchestration, capability intersection, category registry.
3. Application services: scan, plan, transfer, verify, import, report.
4. Shared transfer core: manifest, streaming, chunks, retry, resume, hash.
5. Platform adapters: Kotlin Android and Swift iOS.
6. Connectivity adapters: LAN TCP/TLS baseline; optional Nearby/Wi-Fi Direct/QUIC/USB.
7. Persistence: session DB, manifest, checkpoints, reports.

## Symmetric peer model
`PeerRole = Sender | Receiver | Both`
A device role is selected per session. Never encode Android as source-only or iOS as destination-only.

## Suggested module boundaries
- `app_flutter/`: shared UI and orchestration
- `core/domain/`: platform-neutral entities and state machine
- `core/protocol/`: handshake, capability negotiation, manifest
- `core/transfer/`: chunking, queue, backpressure, hash, resume
- `platform/android/`: Kotlin adapters
- `platform/ios/`: Swift adapters
- `connectivity/lan/`: TCP/TLS baseline
- `connectivity/nearby/`: experimental adapter
- `connectivity/quic/`: benchmark adapter
- `connectivity/usb/`: investigation only
- `storage/`: durable session state and transfer reports
- `qa/`: unit, integration, device test plans

## State machine
IDLE → DISCOVERING → PAIRING → AUTHENTICATING → CAPABILITY_EXCHANGE → SCANNING → PREVIEW → PREPARING → TRANSFERRING → VERIFYING → IMPORTING → COMPLETED / PARTIAL / FAILED / CANCELLED.

Every transition must define timeout, persisted state, retryability, user-facing error and recovery.

## Capability negotiation
The peers exchange non-sensitive runtime facts: platform, OS/app/protocol versions, permissions, supported categories, transport options, free storage, background constraints and crypto suites. The agreed migration plan is the intersection of source export capabilities and destination import capabilities.

## Persistence
Persist session ID, peer fingerprint, protocol version, selected categories, manifest, per-file state, chunk checkpoints, hash results, timestamps and final report. Never persist secret keys in plaintext or sensitive content in diagnostic logs.
