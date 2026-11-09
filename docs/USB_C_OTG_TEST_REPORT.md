# Báo cáo kiểm thử USB-C / OTG

Nhánh `feature/usb-c-otg-transfer` · Cập nhật 2026-11-09

## 1. Kết quả đã có (tự động, trên máy chủ GitHub — KHÔNG phải điện thoại)

CI run **42550215224** (commit sửa mã lỗi bridge), tất cả job **success**:

| Hạng mục | Kết quả | Ghi chú |
|---|---|---|
| `flutter analyze` | No issues found | |
| Test Dart | **26/26 pass** (23 cũ + 3 mới của chế độ cáp) | Host chỉ-loopback quảng bá `127.0.0.1` + cờ `usb`, ghép đôi qua loopback; **kết nối từ interface mạng thật bị từ chối**; host Wi-Fi mặc định vẫn nghe mọi interface |
| Test JVM Kotlin (`:ptp_platform:testDebugUnitTest`) | **7/7 pass** | Qua một cặp socket giả lập cáp: 5 MB hai chiều khớp SHA-256; kết nối thứ 2–3 sau khi đóng (giống resume); rút cáp → socket app nhận EOF; sai phiên bản bị từ chối; frame quá lớn làm đóng liên kết với mã `PROTOCOL_ERROR`; tách gói ngắn; cắm lại giữ nguyên cổng |
| Test Python giao thức | 45/45 pass | Không đổi |
| APK release arm64 | Build OK, 33,4 MB | Artifact `chuyen-du-lieu-release-arm64-apk` |
| iOS (không ký) | Build OK | iOS không có chế độ cáp |

Lỗi thật được test bắt và đã sửa: bridge ghi tên lớp exception thay vì mã lỗi, nên giao diện không hiện được nguyên nhân (CI run 42549561206 → sửa ở commit kế tiếp).

**Những gì test tự động KHÔNG chứng minh:** bắt tay AOA, quyền USB, endpoint bulk thật, hành vi gói ngắn trên phần cứng, tốc độ, pin, nhiệt độ, chạy khi tắt màn hình.

## 2. Ma trận thiết bị

| Chiều | Phương thức | Trạng thái |
|---|---|---|
| Android → Android | AOA, cáp USB-C ↔ USB-C | **NOT_TESTED** (có code + build + test JVM) |
| Android → iPhone | — | **UNSUPPORTED** (không có API USB cho app trên iPhone); dùng Wi-Fi |
| iPhone → Android | PTP nhập ảnh/video (chỉ đọc) | **RESTRICTED** — chưa triển khai trong POC này |
| iPhone → iPhone | — | **UNSUPPORTED** (không có API USB cho app trên iPhone) |

## 3. Hướng dẫn thử trên 2 điện thoại Android (khi bạn có máy)

**Chuẩn bị:** 2 máy Android 10+ (ghi lại hãng, model, phiên bản Android), 1 cáp USB-C ↔ USB-C **có dữ liệu**, APK `chuyen-du-lieu-release-arm64-apk` từ CI mới nhất của nhánh này, cài lên cả hai máy.

1. Mở khóa cả hai máy, mở app ở cả hai.
2. Máy nhận: **Nhận dữ liệu** → chọn **Cáp USB-C (thử nghiệm)** → **Hiện mã QR**.
3. Cắm cáp. Nếu hệ thống hỏi quyền USB, chọn **Cho phép** (có thể hỏi 2 lần, vì máy kia khởi động lại USB ở chế độ phụ kiện).
4. Máy gửi: **Gửi dữ liệu** → **Quét mã QR** → quét mã trên máy nhận. App tự nhận ra chế độ cáp từ QR.
5. So mã 6 số trên hai máy → **Đồng ý** cả hai.
6. Chọn vài ảnh, 1 video lớn, 1 tài liệu tên tiếng Việt → **Bắt đầu chuyển**.
7. Kiểm tra thêm: hủy giữa chừng; **rút cáp giữa chừng rồi cắm lại** (phải chuyển tiếp, không chạy lại từ đầu); tắt màn hình máy gửi trong 1 phút.
8. Trên mỗi máy, ở màn kết quả: **Xuất log chẩn đoán** → gửi cho mình 2 file log và ảnh chụp màn hình kết quả.

**Nếu không kết nối được**, chụp màn hình thông báo lỗi và thử:
- Một máy vào thông báo USB → **USB do … điều khiển** → đổi sang máy kia.
- Đổi cáp khác (rất nhiều cáp chỉ sạc).

## 4. Mẫu ghi kết quả (mỗi lần thử một dòng)

`ngày | máy gửi (hãng/model/Android) | máy nhận | cáp | máy nào làm USB host | số file / tổng MB | thời gian | MB/s app hiển thị | SHA-256 khớp? | rút cáp → tiếp tục? | hủy OK? | lỗi (nếu có) | file log`

Một chiều chỉ được đánh dấu **SUPPORTED** khi có dòng PASS cho: kết nối, xác thực, truyền thật, SHA-256 khớp, hủy, rút cáp không hỏng dữ liệu, Wi-Fi vẫn hoạt động — trên ít nhất 2 cặp máy khác hãng.
