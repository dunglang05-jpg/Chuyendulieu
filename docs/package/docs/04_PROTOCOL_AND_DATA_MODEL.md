# 04 — Protocol and Data Model

## Protocol goals
- Platform-neutral and versioned.
- Sender/receiver symmetric.
- Secure, resumable, bounded and testable.
- Capability negotiation precedes transfer.

## QR payload
Include only protocol version, random session ID, short expiry, endpoint hints, ephemeral public key/fingerprint and non-sensitive feature flags. Do not embed PII or credentials.

## Handshake
1. Discovery/session creation.
2. Exchange protocol versions and nonces.
3. Authenticate peer fingerprints and confirm on both screens.
4. Establish encrypted channel.
5. Exchange capability documents.
6. Compute intersection and migration plan.
7. Approve manifest and destination capacity.
8. Transfer and verify.

## File manifest fields
- transfer_id
- relative_path (normalized and validated)
- display_name
- size_bytes
- mime_type
- modified_time (optional)
- source_category
- metadata (allowlisted only)
- whole_file_sha256
- chunk_size
- chunk_hashes (optional)
- destination_import_strategy

## Chunk protocol
Each chunk has transfer_id, file_id, chunk_index, byte_offset, length, payload and integrity metadata. Receiver acknowledges only durable writes. Checkpoints are persisted after successful flush. Resume revalidates file identity and chunk state.

## Error codes
- PEER_TIMEOUT
- PAIRING_EXPIRED
- AUTHENTICATION_FAILED
- PROTOCOL_VERSION_MISMATCH
- CAPABILITY_UNAVAILABLE
- PERMISSION_DENIED
- STORAGE_INSUFFICIENT
- FILE_CHANGED
- HASH_MISMATCH
- NETWORK_INTERRUPTED
- RESUME_STATE_INVALID
- IMPORT_REQUIRES_USER_ACTION
- PLATFORM_RESTRICTION
- USER_CANCELLED
- INTERNAL_ERROR

## Schema files
See `contracts/capability.schema.json` and `contracts/transfer_manifest.schema.json`.
