# 08 — Repository Research Notes

Previously shortlisted projects (re-check current branch, license, dependencies and activity before use):
- LocalSend: https://github.com/localsend/localsend — useful reference for local-network file transfer and Flutter/Rust architecture. Do not assume its full app is a drop-in migration engine.
- Google Nearby: https://github.com/google/nearby — investigate Connections for P2P adapter; verify iOS support and actual API/build compatibility.
- Quinn: https://github.com/quinn-rs/quinn — Rust QUIC implementation; benchmark only, not automatically faster than TCP.
- Seedvault: https://github.com/seedvault-app/seedvault — reference for Android backup/system integration, not a general third-party app library.
- Neo Backup: https://github.com/NeoApplications/Neo-Backup — root-dependent use case and license may not fit; do not integrate without legal/security review.
- Snapdrop: https://github.com/RobinLinus/snapdrop — check license compatibility before reuse.

## Reuse policy
Before copying any code:
1. Inspect repository license and individual file headers.
2. Inspect transitive dependencies and licenses.
3. Pin exact versions/commits.
4. Create SBOM and NOTICE.
5. Run security review and tests.
6. Keep adapters isolated so a dependency can be replaced.

No repository provides the complete cross-platform Phone Transfer Pro product. Build the migration orchestrator, capability model, platform adapters and policy layer as first-party modules.
