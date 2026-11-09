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

**Cập nhật — chế độ Tự động (commit d67f54f), CI run 42555105872, tất cả job success:** `flutter analyze` No issues
found; test Dart **34/34 pass** (thêm 7 test quyết định đổi đường và 1 test đổi đường giữa một tệp 24 MB qua hai bộ
chuyển tiếp TCP cục bộ, SHA-256 khớp, không phải xác nhận mã 6 số lần hai); JVM Kotlin BUILD SUCCESSFUL; iOS build OK.
Vẫn **không** chứng minh tốc độ cáp hay phần cứng USB.

## 2. Ma trận thiết bị

| Chiều | Phương thức | Trạng thái |
|---|---|---|
| Android → Android | AOA, cáp USB-C ↔ USB-C | **NOT_TESTED** (có code + build + test JVM) |
| Android → Android | Tự động: Wi-Fi → cáp giữa chừng | **NOT_TESTED** (có code + test Dart mô phỏng đổi đường; chưa chạy trên máy) |
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

### 3b. Thử chế độ Tự động (Wi-Fi → cáp)

1. Hai máy Android, **chưa cắm cáp**. Máy nhận: **Nhận dữ liệu** → **Tự động** → **Hiện mã QR**; máy gửi quét mã, so mã 6 số.
2. Chọn một video lớn (≥ 2 GB nếu có) → **Bắt đầu chuyển**. Màn hình phải ghi "Đang truyền qua Wi-Fi".
3. Sau khoảng 20 giây, cắm cáp USB-C, bấm **Cho phép** nếu được hỏi. Ghi lại: màn hình có đổi sang "Đang truyền qua cáp
   USB-C" không, hay báo "Cáp đo được … chậm hơn Wi-Fi"; tốc độ trước và sau.
4. Rút cáp giữa chừng → phải tự quay lại Wi-Fi và tiếp tục. Cắm lại → thử cáp lần nữa.
5. Tắt Wi-Fi một máy khi đang chạy trên cáp → phải vẫn chạy tiếp qua cáp.
6. Kết thúc: SHA-256 khớp (màn kết quả không có tệp lỗi), xuất log chẩn đoán cả hai máy.

## 4. Mẫu ghi kết quả (mỗi lần thử một dòng)

`ngày | máy gửi (hãng/model/Android) | máy nhận | cáp | máy nào làm USB host | số file / tổng MB | thời gian | MB/s app hiển thị | SHA-256 khớp? | rút cáp → tiếp tục? | hủy OK? | lỗi (nếu có) | file log`

Một chiều chỉ được đánh dấu **SUPPORTED** khi có dòng PASS cho: kết nối, xác thực, truyền thật, SHA-256 khớp, hủy, rút cáp không hỏng dữ liệu, Wi-Fi vẫn hoạt động — trên ít nhất 2 cặp máy khác hãng.

## 2026-11-09 — device report: "cable mode does not work, no USB permission dialog"

Reported on a real phone (Xiaomi 2406APNFAG, Android 16). No cable log was captured.

**Analysis (from the code, not measured):**
- The USB permission dialog only appears after this phone's `UsbManager` reports a `UsbDevice`, which happens only when this phone is the USB **host**, or a `UsbAccessory`, which happens only after the peer, acting as host, switched us into accessory mode.
- With two phones, USB-C role negotiation usually leaves **both phones as device/sink** unless one of them has OTG enabled or "USB controlled by: This device" selected. In that case neither phone sees anything, `establish()` keeps polling in state `waiting`, and no dialog ever appears. This matches the report.
- Other causes that give the same symptom: a charge-only cable, or a locked screen.

**Change:**
- `usbStatus` now reports `seen` (`none | device | not_android | accessory`) and the device count. The diagnostic log records them with each state change (`usb … status=none count=0`).
- After 8 s of `waiting` with `seen=none`, the UI shows how to make one phone the USB host: the OTG toggle on OPPO/realme/OnePlus, "USB controlled by → This device", a data cable, and flipping the cable ends.

**Still to verify on devices:** whether the switch to AOA works once one phone is host. The next cable log will show it: `seen=device`, then `switching`, `permission`, `connected`.

## 2026-11-09 (evening) — second device report: cable plugged in during a Wi-Fi transfer, nothing happened

Screenshots from the device test:
- The transfer ran over Wi-Fi at about 9–11 MB/s, as shown in the app.
- One phone showed the system sheet "Chọn ứng dụng cho thiết bị USB" offering only "Máy chủ MTP" and "Photos". The other phone showed "Chuyển tập tin USB bật".
- So the cable did negotiate host and device roles.

Causes found in the code:
1. **"Điểm phát" never armed the cable.** Only `auto` waited for a cable, and "Điểm phát" became the default that afternoon. **Fixed:** `autoCable` covers `auto` and `hotspot`, and the QR carries the `usbauto` flag in both modes.
2. **A missed permission dialog disabled the cable for the whole session.** The system app sheet can hide our `requestPermission` dialog. An unanswered AOA-device request threw `USB_PERMISSION_DENIED`, and auto mode then stopped trying. A non-AOA device was never asked again. **Fixed:** a refused or unanswered request is asked again after 15 s, and `seen=denied` is logged and shown with a hint.
3. **The app was missing from the system sheet.** **Added:** `UsbAttachActivity` with device filters (AOA ids, MTP/PTP class 6, vendor class 255/255) and an accessory filter (our manufacturer/model). Picking "Chuyển dữ liệu" in that sheet grants the permission without a second dialog.

Still not tested on devices.
