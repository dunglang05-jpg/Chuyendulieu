# Threat model — PTP/1

Assets: user content in transit and at rest in the inbox; contacts; the pairing secret (`sid`); the host's ephemeral key; the resume token.
Trust anchor: the QR code, read optically from the other phone's screen.

| # | Threat | Control | Verified by |
|---|---|---|---|
| T1 | Nearby attacker impersonates the host (MITM) | Joiner pins SHA-256 of host cert from QR; no CA; mismatch aborts before any byte of hello is sent | `test_wrong_fingerprint_is_rejected_before_sending_anything` (py), `wrong fingerprint…` (dart, unrun) |
| T2 | Attacker connects to the host without the QR | HMAC proof over `sid` (128-bit) inside TLS; 5 failures destroy the session | `test_wrong_session_id_and_rate_limit` |
| T3 | QR photographed / screenshot replayed later | 5-min expiry checked by both sides; `sid` single-use after pairing; host shows peer name + 6-digit code and requires user confirmation on both screens | `test_qr_replay_after_pairing_is_rejected`, `test_expired_session_rejected_by_host`, `test_user_rejects_code` |
| T4 | Attacker races the legitimate joiner with a stolen QR | One active channel; user sees an unexpected device name/code and rejects; legitimate joiner gets `SESSION_BUSY`/`AUTHENTICATION_FAILED` | `test_second_peer_while_busy` |
| T5 | Hijack of a dropped session | Resume requires HMAC with a 256-bit token issued only after mutual confirmation, within 15 min | `test_resume_rejected_with_wrong_token` |
| T6 | Downgrade | Version list must contain 1, no fallback; Python host enforces TLS ≥ 1.3. **Gap:** Dart `SecureSocket` has no minimum-version API; mitigated by cert pinning (TLS 1.2 + pinned ECDHE cert is still not MITM-able). Revisit with native TLS in M7 | `test_tls12_client_is_refused` (py only) |
| T7 | Malicious sender: path traversal, absolute paths, symlinks, odd characters | §8 path rules + `resolve_inside` + symlink check + receiver writes only under its inbox | `test_path_rejected[*]`, `test_resolve_inside_refuses_symlink`, `test_path_traversal_manifest_rejected` |
| T8 | Resource exhaustion | Frame caps (64 KiB pre-auth, 4 MiB data, 16 MiB manifest), ≤ 100 000 files, ≤ 1 TiB/file, capacity check with reserve, 32 MiB send window, idle timeouts | `test_oversized_frame_before_auth_is_dropped`, `test_storage_insufficient`, bench RSS |
| T9 | Data tampering/corruption | TLS AEAD in transit; whole-file SHA-256 before commit; partial deleted on mismatch; out-of-order/oversize data rejected | `test_hash_mismatch_is_detected_and_retried`, `test_out_of_order_and_oversize_data_rejected` |
| T10 | Overwriting user files | Never overwrite: unique ` (n)` names; atomic rename from `.part` | `test_duplicate_destination_name_gets_suffix` |
| T11 | Log leakage | Adapters log/return only exception class names; no file names, contacts or keys in errors | code review (M7: automated log scan) |
| T12 | Key material at rest | Python host deletes PEM files right after loading. App keeps the key in memory; for resume across app restarts it must be stored — **M7: wrap with Android Keystore / iOS Keychain** | open item |
| T13 | Device theft after transfer | Inbox is app-private; iOS inbox excluded from backup; "delete partial data" action | open: retention timer (M7) |
| T14 | Scope creep into other apps' data | No root/jailbreak/exploit, no token/cookie extraction, no other-app sandbox access — not implemented by design; messaging apps routed to official backup flows | `CLAUDE.md`, registry text |

Open items for M7 security review: T6 (native TLS min version), T12 (Keystore/Keychain), log-scan test, fuzzing of manifest/frames (Dart + Python), external review of the pairing design.
