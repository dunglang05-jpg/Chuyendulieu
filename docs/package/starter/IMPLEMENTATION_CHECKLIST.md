# Starter implementation checklist

This package intentionally avoids shipping fake platform implementations. Claude Code must inspect the existing repository and implement real adapters.

- [ ] Shared `PeerRole` and platform-neutral domain models
- [ ] Capability registry and JSON serialization tests
- [ ] Protocol version negotiation
- [ ] QR/session creation and expiry
- [ ] Mutual peer authentication
- [ ] LAN TCP/TLS transport interface
- [ ] Android Kotlin sender adapter
- [ ] Android Kotlin receiver adapter
- [ ] iOS Swift sender adapter
- [ ] iOS Swift receiver adapter
- [ ] File manifest validation
- [ ] Bounded streaming and backpressure
- [ ] SHA-256 verification
- [ ] Durable checkpoints and resume
- [ ] Platform-specific import workflows
- [ ] Four-direction integration tests
- [ ] Physical-device test matrix
- [ ] Security/privacy review
