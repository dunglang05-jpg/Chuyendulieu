# 06 — QA and Acceptance Plan

## Directional release gates
All four directions require independent tests:
- Android→Android
- Android→iPhone
- iPhone→Android
- iPhone→iPhone

A direction is not supported until sender and receiver builds run on physical devices and pass all critical tests.

## Test scenarios
1. QR pairing success, expired QR, wrong peer, replay attempt.
2. Capability mismatch and protocol version mismatch.
3. Permission granted, limited, denied and revoked mid-session.
4. One large file (target 5 GB where device storage allows).
5. 10,000 small files.
6. Mixed photos/videos/documents.
7. Duplicate names and Unicode filenames.
8. Low storage and file-system errors.
9. Wi-Fi loss, network switch, app background/foreground.
10. Sender/receiver process killed and restarted.
11. Pause/resume/cancel.
12. Hash mismatch and changed source file.
13. Thermal throttling and low battery.
14. Import flow cancelled by user.
15. Partial completion and report correctness.

## Metrics
- Pairing time
- Discovery time
- Throughput MB/s
- CPU and peak RAM
- Battery consumption
- Thermal state
- Retry and resume success
- Hash verification duration
- Crash-free sessions

## Test report must include
Device model, OS version/build, app build, network type, file set and size, test steps, raw logs, observed result, pass/fail, known limitation. No fabricated results.
