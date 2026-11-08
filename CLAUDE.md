# CLAUDE.md — Mandatory Engineering Rules

## 1. Product scope is four-way, not Android-only
Phone Transfer Pro must be architected for:
- Android → Android
- Android → iPhone
- iPhone → Android
- iPhone → iPhone

Every architecture decision, capability schema, session model, transfer manifest, UI flow, and test plan must account for both sender and receiver roles on both platforms. A milestone may implement one path first, but must not hard-code Android as the only source or destination.

## 2. Platform truthfulness
- Android and iOS expose different APIs and permissions.
- iOS third-party apps cannot freely read/write another app's private container, install arbitrary apps, restore arbitrary app data, or access all system databases.
- Android third-party apps also cannot freely access another app's private data without authorized system/OEM/managed-device capabilities.
- Use documented public APIs, user-granted permissions, official app backup/transfer flows, and OEM-authorized interfaces only.
- Never promise complete migration of every app's private data or preservation of login sessions.
- Mark unsupported or partially supported data categories explicitly in the UI.

## 3. Security
- No root, jailbreak, exploit, privilege escalation, sandbox bypass, session-token extraction, cookie/password/OTP/private-key/biometric extraction.
- Pairing must use short-lived session identifiers and ephemeral cryptographic keys.
- Authenticate both peers; show device identity and require user confirmation.
- Encrypt transport (TLS or an audited authenticated encryption design).
- Protect against replay, downgrade, unauthorized peer, path traversal, symlink attacks, malformed manifests, oversized files and resource exhaustion.
- Never log secrets or personal content.

## 4. Data integrity and resilience
- Streaming I/O; bounded buffers; backpressure.
- Per-file size, type, metadata and hash.
- SHA-256 verification before marking a file complete.
- Chunk-level checkpointing where practical; retry with bounded exponential backoff.
- Atomic destination writes; safe cleanup of partial files.
- Resume must verify session identity, file identity, size and chunk hashes.
- Cancellation must stop workers and close sockets/files safely.
- Never load an entire large file into RAM.

## 5. Performance
- Measure throughput, latency, CPU, memory, battery and thermal state.
- Adaptive chunk size and concurrency based on measured device capability.
- Avoid unbounded task queues and parallelism.
- Do not claim USB is faster or available without proving the actual device/OS/cable/role path.
- LAN TCP/TLS is the reliable baseline. Nearby, Wi-Fi Direct, hotspot, QUIC and USB are adapters/experiments gated by real-device tests.
- Hybrid multi-link is optional and must be enabled only if benchmarks prove net benefit without duplicate/corrupt data.

## 6. Architecture
- Flutter/Dart: shared UX and orchestration.
- Kotlin: Android platform adapter, permissions, discovery and transport APIs.
- Swift: iOS platform adapter, permissions, document/photo/contact APIs and native networking integration.
- Shared protocol and capability model independent of platform.
- SQLite or an equivalent durable local store for sessions, manifests, checkpoints and reports.
- Clear interfaces; no platform-specific assumptions in shared domain logic.

## 7. Development process
- Inspect existing repository before changing it.
- Preserve user code and data; do not overwrite without explanation and approval.
- Work in small commits/patches where possible.
- For every milestone: implementation, unit tests, integration tests, static analysis, build, device test plan, known limitations.
- If a command cannot be run, state why and provide the exact command needed.
- Never fabricate test logs, benchmark numbers, supported device lists or successful builds.
- Do not silently downgrade requirements to make tests pass.

## 8. Release gate
A transfer direction is not "supported" until:
1. Sender and receiver builds are available.
2. Pairing and capability negotiation work.
3. Representative data categories transfer correctly.
4. Large-file transfer and interruption/resume are tested.
5. Hash verification passes.
6. Permission-denied, low-storage, cancellation and device-loss cases are tested.
7. The exact OS/device test matrix and limitations are documented.
