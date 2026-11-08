# PTP/1 — Phone Transfer Pro wire protocol, version 1

Status: **draft, implemented by `tools/reference_peer` (tested on loopback) and `app/lib/core` (Dart, not yet compiled)**.
Platform-neutral. Nothing in this document depends on whether a peer is Android, iOS or the desktop reference peer.

## 1. Roles

Two independent role pairs are chosen per session:

| Pair | Values | Meaning |
|---|---|---|
| Pairing role | `host` / `joiner` | Host shows the QR and runs the TLS server. Joiner scans the QR and connects. |
| Data role | `sender` / `receiver` | Who exports data and who imports it. |

The QR states the host's data role; the joiner takes the opposite one. Either phone can therefore show the QR, regardless of the transfer direction (master prompt B.3 "có thể hỗ trợ chiều ngược lại"). All four directions (A→A, A→i, i→A, i→i) are the same protocol.

## 2. QR / session payload

`ptp://pair?d=<base64url(JSON), no padding>` — whole URI ≤ 1024 bytes.

```json
{"v":1,"sid":"<16 random bytes b64u>","exp":1767225600,
 "ep":["192.168.1.23:47321"],"fp":"<SHA-256 of host TLS cert DER, b64u>",
 "role":"receiver","pf":"android","f":[]}
```

| Field | Rule |
|---|---|
| `v` | protocol version the host speaks (int) |
| `sid` | exactly 16 bytes from a CSPRNG; single-use |
| `exp` | unix seconds; host sets now + 300 s; joiner and host both reject after it |
| `ep` | 1–8 `ipv4:port` / `[ipv6]:port` hints. Only private/link-local addresses are expected |
| `fp` | 32 bytes; the only trust anchor for the host's identity |
| `role` | `sender` or `receiver` (host's data role) |
| `pf` | `android`, `ios`, `desktop_reference` — display hint only, never used for capability decisions |
| `f` | non-sensitive feature flags (strings) |

Never in the QR: device name, file names, contacts, tokens, passwords, OTP, private keys.

## 3. Transport and channel security

* TCP. TLS **1.3 only** (`minimum_version = TLSv1.3`). Lower versions are a protocol error, not a fallback.
* Host generates a fresh ECDSA P-256 key and self-signed certificate **per session**. The key never leaves the device and is deleted when the session (including its resume window) ends.
* Joiner does not use a CA. It accepts the server certificate only if `SHA-256(DER) == fp` (constant-time compare). Any mismatch → `AUTHENTICATION_FAILED`, connection closed, nothing sent.
* Joiner authenticates to host by proving knowledge of `sid` (seen only via the QR) inside the pinned TLS channel, then **both users confirm** a 6-digit code and the peer device name.

## 4. Framing (inside TLS)

```
u32 BE length L  (= 1 + len(body))
u8  type         0x01 CONTROL | 0x02 DATA
body             L-1 bytes
```

* CONTROL body: UTF-8 JSON object with string field `t`. Max 64 KiB, except `manifest` and `manifest_resp` (size grows with file count; max 16 MiB, only accepted at the manifest step). Found by the 2 000-file test: a 64 KiB cap on `manifest_resp` breaks at ~1 500 files.
* DATA body: `u32 BE fileIndex | u64 BE offset | payload` with 1 ≤ payload ≤ 4 MiB.
* Before authentication completes the reader cap is 64 KiB. Unknown frame type or oversize length → `PROTOCOL_ERROR`, close.

## 5. Handshake

```
joiner → host   hello     {versions:[1], nonce:b64u(16), proof, device:{name,platform,model}, resume?}
host   → joiner welcome   {version:1, nonce:b64u(16), device:{...}}      | error {code}
both            confirm   {accepted:bool}            (skipped when resuming)
host   → joiner paired    {resumeToken:b64u(32), resumed:bool}
both            caps      {caps:<capability document>}
```

* `proof = HMAC-SHA256(key=sid, "ptp1/proof" ‖ fp ‖ nonceJ)`.
* `SAS = uint32_be(HMAC-SHA256(sid, "ptp1/sas" ‖ fp ‖ nonceJ ‖ nonceH)[0..4]) mod 10^6`, zero-padded to 6 digits. Shown on both screens with the peer device name; both users must accept.
* Resume: `resume = {transferId, proof: HMAC-SHA256(key=resumeToken, "ptp1/resume" ‖ fp ‖ nonceJ)}`. Valid only within the resume window (15 min after the last activity) and only for the session that issued the token. No QR re-scan, no re-confirmation.
* Host rules: `sid` is single-use (a second fresh `hello` after a successful pairing is rejected: replay protection); one active channel at a time; after 5 failed proofs the session is destroyed (rate limit); expired `exp` → `PAIRING_EXPIRED`; no common version → `PROTOCOL_VERSION_MISMATCH` (no silent downgrade).
* Timeouts: hello/welcome 20 s, confirmation 120 s.

## 6. Capability exchange

Each side sends `contracts/capability.schema.json` (v1.1): platform, OS/app/protocol versions, transports, per-category `export`/`import`/`status`, permission status, max file size, free storage, background constraints, crypto suites. **No PII.** Values come from runtime probing, never from the OS name alone.

Migration plan = categories where `sender.export && receiver.import && status != unsupported`.

## 7. Transfer

```
sender   → receiver manifest      {transferId, files:[{i,path,size,mime,mtime,category}], totalBytes}
receiver → sender   manifest_resp {accept:true, files:[{i,offset}]}  | {accept:false, error, needed, available}
sender   → receiver DATA*, file_end {i,size,sha256} | file_skip {i,reason}   (pipelined, file by file)
receiver → sender   ack {i,offset}  (durable bytes, after fsync)   file_result {i,status}
sender   → receiver done
receiver → sender   report {ok,failed,skipped}
either              cancel {reason} | error {code,message}
```

* `transferId`: 16 random bytes b64u. `i` = position in `files` (0..n-1).
* Manifest validation (receiver): ≤ 100 000 files; `size` 0..2^40; known `category`; unique `i`; paths per §8; no duplicate path (NFC + case-folded). Files whose category is not in the plan are omitted from `manifest_resp` (= skipped).
* Capacity: `free − reserve ≥ Σ(size − offset)`, reserve 256 MiB on phones, else `STORAGE_INSUFFICIENT`.
* `offset` in `manifest_resp` is the durable resume point (0 for new files).
* Ordering: v1 sends files sequentially and chunks of a file in order. A DATA frame whose offset is not exactly the receiver's expected offset → `RESUME_STATE_INVALID`.
* Flow control: sender keeps `sentBytes − ackedBytes ≤ 32 MiB`. Receiver fsyncs and sends `ack` at least every 8 MiB and at each file end. This bounds RAM on both sides regardless of file size.
* Integrity: sender hashes the bytes it actually read (re-hashing the prefix when resuming) and sends SHA-256 in `file_end`. Receiver hashes what it wrote (re-hashing its durable prefix when resuming). Match + `size` equal → fsync → atomic rename to the final name → `ack` + `file_result ok`. Mismatch → partial deleted → `file_result hash_mismatch`; sender retries that file once from offset 0.
* Source change: sender compares size+mtime before and after reading; on change sends `file_skip {reason:FILE_CHANGED}`.
* Receiver writes only to `<inbox>/.ptp-partial/<transferId>/<i>.part`; final files land under `<inbox>/<category>/<path>`; name collisions get ` (1)`, ` (2)`… suffixes. Import into Photos/MediaStore/Contacts happens after verification (state IMPORTING) through platform adapters.

## 8. Path rules (receiver must enforce; sender should pre-sanitise)

Separator `/`; Unicode NFC; not absolute; ≤ 1024 UTF-8 bytes; ≤ 32 segments; each segment 1..255 bytes, not `.`/`..`, no trailing space or dot, no control chars, none of `\ : * ? " < > |`. After joining with the destination root the resolved path must stay inside the root and no existing component may be a symlink.

## 9. Error codes

`PEER_TIMEOUT PAIRING_EXPIRED AUTHENTICATION_FAILED PROTOCOL_VERSION_MISMATCH PROTOCOL_ERROR MANIFEST_INVALID CAPABILITY_UNAVAILABLE PERMISSION_DENIED STORAGE_INSUFFICIENT FILE_CHANGED HASH_MISMATCH NETWORK_INTERRUPTED RESUME_STATE_INVALID IMPORT_REQUIRES_USER_ACTION PLATFORM_RESTRICTION SESSION_BUSY USER_CANCELLED INTERNAL_ERROR`

`PROTOCOL_ERROR`, `MANIFEST_INVALID` and `SESSION_BUSY` were added to the list in `docs/package/docs/04_PROTOCOL_AND_DATA_MODEL.md`.

## 10. Deliberate deviations from the package contracts

* `transfer_manifest.schema.json` required a whole-file `sha256` up front. Hashing a 5 GB video before the first byte moves doubles the reads and delays start, so v1 sends the hash in `file_end`; the manifest field is optional. The integrity guarantee is unchanged: no file is marked complete without a matching SHA-256.
* Capability schema bumped to 1.1: adds `permissions`, `maxFileSizeBytes`, `backgroundConstraints`, `cryptoSuites`, and `desktop_reference` platform (test tool only).
* Status enum keeps the package's values; mapping to master prompt C: `supported`=Supported, `permission_required`=SupportedWithPermission, `official_flow`=SupportedViaOfficialFlow, `partial`=Partial, `unsupported`=Unsupported, `oem_authorized`=RequiresOEMOrManagedDevice.

## 11. Known v1 limitations (to measure before changing)

* One file at a time; multi-file concurrency and adaptive chunk size are M6/M7 work, to be decided from device benchmarks.
* fsync per file end is costly for 10 000 small files; batching to be evaluated with real numbers.
* Host's ephemeral key must survive app restarts for resume; the app stores it in app-private storage for the POC — Keystore/Keychain wrapping is an M7 item.
