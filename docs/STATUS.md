# Trạng thái dự án — cập nhật 2026-11-09

> **Chưa có chiều chuyển nào được công bố là "supported".** Theo `CLAUDE.md` §8, một chiều chỉ được coi là hỗ trợ khi cả hai đầu build được và qua kiểm thử tích hợp trên điện thoại thật. Build đã có (CI); kiểm thử trên điện thoại thật thì chưa.

## Bốn chiều chuyển

| Chiều | Thiết kế/giao thức | Code gửi | Code nhận | Build | Test máy thật | Trạng thái |
|---|---|---|---|---|---|---|
| Android → Android | ✅ PTP/1 | ✅ (Kotlin + Dart) | ✅ | ✅ APK (CI) | ❌ chưa | **Chưa hỗ trợ** |
| Android → iPhone | ✅ PTP/1 | ✅ | ✅ (Swift + Dart) | ✅ APK + iOS chưa ký (CI) | ❌ chưa | **Chưa hỗ trợ** |
| iPhone → Android | ✅ PTP/1 | ✅ (Swift + Dart) | ✅ | ✅ iOS chưa ký + APK (CI) | ❌ chưa | **Chưa hỗ trợ** |
| iPhone → iPhone | ✅ PTP/1 | ✅ | ✅ | ✅ iOS chưa ký (CI) | ❌ chưa | **Chưa hỗ trợ** |

Cả bốn chiều dùng **cùng một giao thức và cùng engine Dart**; chỉ adapter nền tảng (đọc ảnh/danh bạ/tệp, nhập vào Ảnh/MediaStore/Danh bạ/Tệp) khác nhau. Không có chỗ nào mã hóa cứng Android là nguồn hay iPhone là đích.

## Cái gì đã được kiểm chứng thật (có log)

| Hạng mục | Bằng chứng | Môi trường |
|---|---|---|
| **CI nhánh `feature/usb-c-otg-transfer` (run 42567659181, commit 69ae8ef)**: analyze *No issues*; **54/54 test Dart**, 45/45 Python, test JVM Kotlin; APK release arm64 36,2 MB; iOS chưa ký build OK | Log CI | Ubuntu (Flutter 3.47.9), macOS — không phải điện thoại |
| **CI GitHub Actions (run 42543205544, commit 3a1db79, nhánh main)**: `flutter analyze` → *No issues found*; **23/23 test Dart pass** (vector chéo Python↔Dart, domain, log không lộ dữ liệu cá nhân, TLS loopback cả 2 hướng QR, resume, sai fingerprint, path traversal, thiếu dung lượng, hủy, **2 worker isolate thật ghép đôi và truyền**); APK debug + **APK release arm64 33,4 MB** + iOS chưa ký build thành công | Log CI trên repo | Ubuntu (Flutter 3.47.9), macOS (Xcode 26.6) — không phải điện thoại |
| Giao thức PTP/1 (ghép đôi, TLS 1.3 ghim fingerprint, xác nhận mã 6 số, capability, manifest, chunk, ack, SHA-256, resume, batch) | 45/45 test pytest pass (`tools/reference_peer`) | Linux x86_64, Python 3.13.18, OpenSSL 3.5.9, loopback 127.0.0.1 |
| Chống path traversal, symlink, replay QR, sai fingerprint, sai session id + rate limit, QR hết hạn, frame quá lớn trước xác thực, TLS 1.2 bị từ chối | Có test riêng cho từng trường hợp | như trên |
| Bộ nhớ có giới hạn | 1 GiB truyền xong với RSS đỉnh 48–49 MiB, SHA-256 khớp | như trên, **không phải số liệu điện thoại** |
| Cú pháp Dart/Kotlin/Swift | 31/31 file parse sạch bằng tree-sitter (`tools/syntax_check.py`); bộ kiểm tra đã được thử với file lỗi cố ý và bắt đúng | Chỉ là kiểm tra cú pháp — **không** kiểm tra kiểu, import hay API |

Thông lượng loopback đo được dao động 118–170 MiB/s giữa các lần chạy trên cùng máy chủ. Con số này **không** nói gì về tốc độ Wi-Fi giữa hai điện thoại.

## Danh sách lỗi rà soát P0–P2 (cập nhật 2026-11-09, nhánh `feature/usb-c-otg-transfer`)

| ID | Trạng thái | Ghi chú |
|---|---|---|
| P0-1 quyền ghi ở máy nhận | ✅ Đã sửa | |
| P0-2 isolate nền | ✅ Đã sửa | |
| P0-3 log chẩn đoán | ✅ Đã sửa | |
| P1-4 quyền thông báo + `onTimeout` | ✅ Đã sửa | |
| P1-5 rò rỉ host khi tạo QR mới | ✅ Đã sửa | |
| P1-6 nút mở Cài đặt | ✅ Đã sửa | |
| P1-7 Android ghi 2 lần | ✅ Đã sửa | Ghi thẳng vào MediaStore; chưa thử trên máy |
| P1-8 ML Kit / DataTransport | ◐ Một phần | iOS hết ML Kit (mobile_scanner 7.5); Android vẫn còn — cần so sánh trên máy trước khi thay |
| P1-9 Kotlin Gradle Plugin | ✅ Đã sửa | Built-in Kotlin; cảnh báo KGP hết trên CI |
| P1-10 khôi phục sau khi tắt app | ✅ Đã làm | Ghép đôi lại + Keystore/Keychain; chưa thử kill tiến trình thật |
| P1-11 TLS ≥ 1.3 | ◐ Giới hạn còn | Đo được: mặc định 1.3, 1.1 bị từ chối, 1.2-only vẫn vào được; Dart không có API ép |
| P2-12 tiến trình máy nhận | ✅ Đã sửa | |
| P2-13 iOS xuất cả lô trước khi gửi | ☐ Chưa làm | |
| P2-15 dọn file tạm | ✅ Đã sửa | |
| P2-16 khóa ký / chính sách riêng tư | ☐ Chưa làm | Cần khóa ký của bạn |
| P2-17 quyền thừa | ✅ Đã sửa | `ACCESS_NETWORK_STATE` trong APK hiện đến từ ML Kit/DataTransport |
| P2-18 kiểm tra sau khi ghi | ✅ Đã làm | Luôn kiểm kích thước; đọc lại toàn bộ là tùy chọn |

Chi tiết từng mục: `docs/REMAINING_HARDENING_REPORT.md`. Mới phát hiện: `ptp_platform` chưa hỗ trợ Swift Package Manager trên iOS (Flutter cảnh báo sẽ thành lỗi ở bản sau).

## Cái gì chưa được kiểm chứng

* Build và test đã chạy trên CI (máy chủ GitHub), **chưa** chạy trên điện thoại thật: adapter Kotlin/Swift mới được biên dịch, chưa được gọi lần nào trên thiết bị.
* Sinh chứng chỉ EC bằng `basic_utils` đã chạy thật trong test Dart trên CI (ghép đôi TLS loopback pass).
* Bản iOS chưa ký nên chưa cài được lên iPhone (cần tài khoản Apple Developer).
* CI lần 1 tìm ra lỗi thật: `PtpHost.close()` có thể treo — đã sửa.

## Thay đổi kiến trúc 2026-11-09 (audit P0-2)

Socket TLS, phiên PTP/1, engine gửi/nhận và SHA-256 chạy trong **isolate nền** (`app/lib/core/worker/transfer_worker.dart`). Luồng giao diện chỉ nhận sự kiện (QR, mã xác nhận, tiến trình ≤ 10 lần/giây, báo cáo lô, lỗi). Các lệnh native mà engine cần (đóng file nguồn, hỏi dung lượng trống) được gửi ngược về luồng giao diện qua `rpc`, nên không plugin nào phải chạy trong isolate nền. Checkpoint tiếp tục truyền chuyển từ SQLite sang file JSON ghi nguyên tử (fsync + rename) trong thư mục riêng của app, vì sqflite là plugin; lịch sử vẫn ở SQLite. **Chưa đo trên máy thật** xem giao diện có còn giật hay không.

## Giới hạn đã biết (thiết kế, không phải lỗi)

* iOS: ứng dụng phải ở foreground khi chuyển; iOS tạm dừng ứng dụng nền.
* iOS Photos: kích thước chính xác chỉ có sau khi xuất file → gửi theo lô (≤ 1000 mục hoặc ≤ 25% dung lượng trống). Live Photo chỉ gửi ảnh tĩnh; album không giữ.
* iOS: không đọc/ghi được thư viện Nhạc; âm thanh chỉ qua tệp người dùng chọn, nhận vào ứng dụng Tệp.
* iOS danh bạ: trường ghi chú không được xuất cho ứng dụng bên thứ ba.
* Android nhận danh bạ: qua ứng dụng Danh bạ hệ thống (người dùng xác nhận), không ghi trực tiếp.
* Lịch, SMS, nhật ký cuộc gọi, dữ liệu riêng của Zalo/Messenger/WhatsApp…, mật khẩu/phiên đăng nhập: **không chuyển**; UI giải thích và chỉ cách chính thức.
* Dart `SecureSocket` không cho đặt TLS tối thiểu = 1.3. Hai bản app đều dùng BoringSSL nên thực tế bắt tay 1.3; chứng chỉ được ghim qua QR nên kể cả TLS 1.2 cũng không bị MITM. Bản Python thì ép 1.3. Xem `THREAT_MODEL.md`.
* v1 gửi tuần tự từng file; chạy song song và chunk thích ứng chờ số đo thật trên máy (M6/M7).
* USB-C/OTG, Wi-Fi Direct, Nearby, QUIC: chưa làm (M6), sẽ không được quảng cáo khi chưa có bằng chứng trên thiết bị.
* Android minSdk 29 (Android 10+).
