# 05 — Security and Privacy

## Threat model
Consider malicious nearby peer, QR screenshot/replay, session hijacking, downgrade, malformed manifests, path traversal, symlink abuse, oversized files, resource exhaustion, network interception, partial-file tampering, log leakage and device theft.

## Required controls
- Short-lived random session IDs and one-time nonces.
- Mutual peer confirmation with matching code/fingerprint.
- Authenticated encryption; prefer TLS 1.3 with validated peer identity or a reviewed equivalent.
- Key material in platform secure storage where persistence is required.
- Strict protocol version negotiation; reject unsafe downgrade.
- Validate all manifest fields and normalize paths.
- Enforce file count, file size, total size and queue limits.
- Backpressure and bounded memory.
- SHA-256 verification.
- Safe temporary files and atomic destination commit.
- Redacted logs and opt-in diagnostic export.
- Clear session data after retention period.

## Forbidden
No root, jailbreak, exploit, sandbox bypass, credential extraction, session token/cookie scraping, OTP interception, private key extraction or covert access to another app's data.

## Privacy UX
- Explain each permission at the moment it is needed.
- Let users choose data categories.
- Show destination and approximate size.
- Provide cancel and delete-partial-data controls.
- Never upload transfer content to a server by default.
- Disclose any optional telemetry; default to data minimization.
