# Third-party dependencies — license audit status

No third-party source code was copied into this repository (LocalSend, Nearby, Quinn, Seedvault, Neo Backup, Snapdrop were **not** used; see `docs/package/docs/08_REPOSITORY_RESEARCH.md`). All protocol, engine and adapter code is first-party.

Declared package dependencies — licenses **not yet verified** (pub.dev/Maven were unreachable). Before M8: check each license file at the pinned version, record it here, generate an SBOM, add NOTICE.

| Package | Where | Purpose | License (to verify) |
|---|---|---|---|
| crypto | app | SHA-256, HMAC | |
| basic_utils, pointycastle | app | EC key + self-signed cert | |
| unorm_dart | app | Unicode NFC | |
| path | app | path joins | |
| sqflite | app | history, checkpoints | |
| qr_flutter | app | display QR | |
| mobile_scanner | app | scan QR — check which barcode engine it bundles per platform and that engine's terms; must work offline | |
| kotlinx-coroutines-android, androidx.core | plugin (Android) | async, FileProvider | |
| cryptography, pytest, pytest-asyncio, pytest-timeout | reference peer (dev only) | TLS cert, tests | |
| tree-sitter + grammars | tools (dev only) | syntax check | |
