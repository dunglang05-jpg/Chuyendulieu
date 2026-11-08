# Device test matrix (release gate, CLAUDE.md §8)

Run every row for each direction: **A→A, A→i, i→A, i→i**. Fill one result line per run. Empty = not tested. No row may be filled from memory or estimates.

Result line format: `date | sender model/OS build | receiver model/OS build | app build | network (Wi-Fi band / hotspot) | file set | MB/s measured | peak RAM | battery Δ | thermal | PASS/FAIL | log path`

| # | Scenario | A→A | A→i | i→A | i→i |
|---|---|---|---|---|---|
| 1 | QR pairing, codes match, both accept | | | | |
| 2 | QR shown by the *sender* instead (reverse) | | | | |
| 3 | Expired QR / rescanned old QR / wrong peer rejects code | | | | |
| 4 | Capability mismatch (e.g. audio from iPhone) shown before transfer | | | | |
| 5 | Permission: granted / limited (Android 14+, iOS) / denied / revoked mid-session | | | | |
| 6 | Photos + videos mixed (HEIC, HEVC, MP4, JPG), metadata dates | | | | |
| 7 | Contacts vCard: Vietnamese names, duplicates, 1 000+ contacts | | | | |
| 8 | Documents via picker, Unicode/duplicate names | | | | |
| 9 | One file ≥ 5 GB (if storage allows) | | | | |
| 10 | 10 000 small files | | | | |
| 11 | Wi-Fi off mid-transfer → auto-resume within 15 min, bytes not resent | | | | |
| 12 | App killed on sender / receiver → reopen → resume | | | | |
| 13 | App backgrounded (iOS foreground-only warning) / screen off (Android FGS) | | | | |
| 14 | Pause / resume / cancel / delete partial data | | | | |
| 15 | Low storage on receiver → STORAGE_INSUFFICIENT before any data | | | | |
| 16 | Hotspot instead of router (each phone as hotspot) | | | | |
| 17 | Hot device / battery < 10 % → pause & warning | | | | |
| 18 | Import: Photos rejects a format → saved to Files and reported | | | | |
| 19 | Report correctness: OK / failed / skipped / needs action counts | | | | |
| 20 | Interop with `tools/reference_peer` both roles | | | | |

Metrics to record per run (master prompt J): throughput, time-to-pair, discovery latency (QR shown → connected), CPU, peak RAM, battery drain, thermal state, retry count, resume success, hash time. Set performance targets only **after** these baselines exist.
