# Báo cáo milestone M0 + M1 (và khung M2–M5) — 2026-11-08

## M0 — Kiểm tra repository và môi trường

**Repository đầu vào:** gói `PhoneTransferPro_ClaudeCode_Full_Package_v2.zip` chỉ gồm tài liệu (SRS, kiến trúc, ma trận nền tảng, giao thức, bảo mật, QA, roadmap), 2 JSON schema, prompt. `PACKAGE_MANIFEST.json` ghi `is_complete_application: false`. Không có mã nguồn → không có gì bị ghi đè. Tài liệu gốc giữ nguyên trong `docs/package/`.

**Toolchain (lệnh `command -v` thực tế):**

| Công cụ | Có? |
|---|---|
| flutter, dart | ❌ |
| Android SDK (adb, sdkmanager), kotlinc | ❌ (gradle 8 + Java có, nhưng Google Maven/Maven Central bị chặn) |
| xcodebuild, swift | ❌ (máy Linux — **không thể build iOS ở đây** dù có mạng) |
| python3 3.13.18, node 22, git | ✅ |

**Mạng:** chỉ npm, PyPI, crates.io, Go proxy. `pub.dev`, `storage.googleapis.com` (Flutter SDK), `dl.google.com`, `maven.google.com`, `repo.maven.apache.org`, `github.com` → 403/không kết nối được. Không có điện thoại/simulator.

**Hệ quả:** viết code thật cho Flutter/Kotlin/Swift nhưng không build được; bổ sung một reference peer Python chạy được để kiểm chứng giao thức thật.

## M1 — Giao thức và domain dùng chung

### Đã làm
* `docs/PROTOCOL_v1.md` — giao thức PTP/1 đầy đủ: vai trò host/joiner tách khỏi sender/receiver (QR hiển thị được trên máy nào cũng được), payload QR không PII, TLS 1.3 + ghim fingerprint, proof HMAC, mã xác nhận 6 số, capability, manifest, framing, flow control, SHA-256, checkpoint/resume, batch, mã lỗi.
* `contracts/` — capability schema v1.1, manifest schema PTP/1, schema QR, `test_vectors.json` dùng chung Python/Dart.
* `tools/reference_peer/` — bản cài đặt giao thức bằng Python + 45 test + benchmark + CLI để làm đối tác kiểm thử cho điện thoại.
* `app/lib/core/` — cùng giao thức bằng Dart: protocol, domain (registry 6 nhóm dữ liệu × 2 nền tảng, capability, state machine 15 trạng thái có timeout/retry/checkpoint/recovery), session (host/joiner), engine gửi/nhận, receiver store.
* `docs/THREAT_MODEL.md`, `docs/TEST_MATRIX.md`, `docs/BUILD_AND_TEST.md`, `docs/STATUS.md`.

### Lỗi thiết kế được test phát hiện và đã sửa
1. `manifest_resp` bị giới hạn 64 KiB như control frame thường → hỏng khi > ~1 500 file. Phát hiện bởi test 2 000 file. Sửa: cho `manifest_resp` cùng giới hạn với `manifest`.
2. `Host.close()` treo vì `Server.wait_closed()` (Python ≥ 3.12) chờ mọi kết nối; và tự khóa chết khi rate-limit gọi từ trong handler. Sửa: `destroy()` không chờ + `close_clients()`.
3. Kích thước ảnh iOS chỉ biết sau khi xuất → thêm cơ chế batch (`done.more`) vào giao thức, có test.

### Lệnh đã chạy và kết quả thực tế
```
$ cd tools/reference_peer && python3 -m pytest -q --timeout 60
45 passed in 30.49s

$ python3 bench/loopback_bench.py 1024
size=1024 MiB time=6.01s throughput=170.5 MiB/s (sender+receiver in one process, both hashing)
peak_rss_before=23 MiB peak_rss_after=48 MiB sha256_match=True
(lần chạy trước: 8.62s, 118.8 MiB/s, RSS 49 MiB — dao động giữa các lần chạy)

$ python3 tools/syntax_check.py app packages
checked 31 files, 0 with syntax issues
(đối chứng: 3 file lỗi cố ý → "3 with syntax issues")
```
Môi trường: Linux 6.18 x86_64, Python 3.13.18, OpenSSL 3.5.9, cryptography 50.0.1, loopback 127.0.0.1.

### Thiết bị đã test
**Không có.** Không có điện thoại hay simulator.

## Khung M2–M5 (code đã viết, chưa build)
* `packages/ptp_platform/` — plugin Flutter: Kotlin (MediaStore, SAF, xuất vCard qua Contacts Provider, nhập danh bạ qua ứng dụng hệ thống, foreground service + wake/Wi-Fi lock, nhiệt độ/pin) và Swift (PhotoKit kể cả quyền limited, xuất tài nguyên gốc kể cả từ iCloud, nhập vào Ảnh bằng move, Contacts framework có chống trùng, UIDocumentPicker, thư mục "Received" hiện trong ứng dụng Tệp, trạng thái nhiệt/pin).
* `app/lib/app/controller.dart` — điều phối: ghép đôi, kế hoạch theo capability, chọn dữ liệu, gửi theo lô, tự kết nối lại trong 15 phút, tạm dừng khi máy nóng, nhập dữ liệu song song với nhận, báo cáo, lịch sử SQLite.
* `app/lib/ui/` — Trang chủ (Gửi/Nhận), QR hiển thị/quét, xác nhận mã 6 số, chọn nhóm dữ liệu kèm giải thích giới hạn, duyệt dung lượng ở máy nhận, tiến trình (MB/s đo thật), báo cáo, "Dữ liệu nào chuyển được?", lịch sử. Tiếng Việt mặc định, có sẵn tiếng Anh.

## Giới hạn đã biết
Xem `docs/STATUS.md`. Quan trọng nhất: chưa build gì; API `basic_utils` cho chứng chỉ EC tự ký chưa được xác nhận; Dart không ép được TLS ≥ 1.3; khóa phiên chưa nằm trong Keystore/Keychain.

## Milestone tiếp theo và điều kiện chặn
**M2 (Android ↔ Android) cần:** máy có Flutter + Android SDK, 2 điện thoại Android.
1. `app/tool/bootstrap.sh` → `flutter analyze` → sửa toàn bộ lỗi kiểu/API.
2. `flutter test` (3 file test) — đặc biệt `protocol_vectors_test` phải khớp Python.
3. Interop điện thoại ↔ `tools/reference_peer` (BUILD_AND_TEST §4).
4. Chạy TEST_MATRIX cột A→A, ghi log thật.

**M3 (Android → iPhone) cần thêm:** máy Mac có Xcode 16+, tài khoản Apple Developer để ký, ≥ 1 iPhone thật.
