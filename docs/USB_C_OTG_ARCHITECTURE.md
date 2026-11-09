# Kiến trúc USB-C (Android ↔ Android, AOA) — POC

Nhánh `feature/usb-c-otg-transfer`. Trạng thái: **đã build và test tự động trên CI; CHƯA thử trên thiết bị (NOT_TESTED)**.
Nghiên cứu nền: `USB_C_OTG_RESEARCH.md`.

## 1. Nguyên tắc
* **Một engine, một giao thức.** Cáp USB chỉ là đường ống byte. TLS 1.3, ghim fingerprint bằng QR, mã 6 số, manifest, SHA-256 và truyền tiếp của PTP/1 giữ nguyên, không sửa dòng nào.
* **Cáp không được tin.** Vẫn phải quét QR và xác nhận mã như Wi-Fi.
* **Wi-Fi là mặc định.** Chế độ cáp chỉ bật khi người dùng chọn. Khi đã chọn cáp thì **không bao giờ** tự chuyển sang Wi-Fi.
* **Chỉ API công khai của Android** (`android.hardware.usb`). Không root, không quyền hệ thống. iOS báo `IOS_NO_USB_API`.

## 2. Sơ đồ

```
 Máy hiện QR (PtpHost, chỉ nghe 127.0.0.1)              Máy quét QR (joiner)
 ┌───────────────────────────────┐                     ┌───────────────────────────────┐
 │ Worker isolate: TLS server     │                     │ Worker isolate: TLS client    │
 │ 127.0.0.1:hostPort             │                     │ → 127.0.0.1:bridgePort        │
 └──────────────▲────────────────┘                     └──────────────▲────────────────┘
                │ TCP loopback                                        │ TCP loopback
 ┌──────────────┴────────────────┐   cáp USB-C có dữ liệu ┌──────────────┴────────────────┐
 │ UsbBridge mode CONNECT          │◄══ 2 endpoint bulk ══►│ UsbBridge mode LISTEN          │
 │ UsbTransport: host HOẶC acc.    │   khung mux 9 byte    │ UsbTransport: vai trò còn lại  │
 └────────────────────────────────┘                      └────────────────────────────────┘
```

Vai trò USB (máy nào là USB host) **độc lập** với vai trò QR. Máy nào thấy `UsbDevice` thì làm host, gửi lệnh AOA để máy kia chuyển sang chế độ accessory. Vai trò này do USB-C tự thương lượng, hoặc do người dùng chọn trong mục "USB do … điều khiển".

## 3. Thành phần

| File | Vai trò |
|---|---|
| `packages/ptp_platform/android/.../usb/UsbBridge.kt` | Kotlin thuần (không dùng API Android): khung mux `HELLO/OPEN/DATA/CLOSE` (`u8 type · u32 connId · u32 len · payload ≤ 16375`), bơm byte giữa USB và socket loopback, backpressure bằng ghi chặn, đóng mọi socket app khi mất cáp, mở lại cùng cổng khi cắm lại |
| `.../usb/UsbTransport.kt` | Phát hiện vai trò; xin quyền USB (PendingIntent tường minh, mutable); bắt tay AOA (`GET_PROTOCOL 51`, `SEND_STRING 52` × 6 chuỗi, `START 53`); mở endpoint bulk (host) hoặc file descriptor accessory; từ chối accessory có chuỗi nhận dạng lạ |
| `.../PtpPlatformPlugin.kt` | Lệnh `usbStatus` / `usbStart(mode, port)` / `usbStop` |
| `.../AndroidManifest.xml` (plugin) | `uses-feature usb.host` và `usb.accessory` với `required="false"`, để CH Play không ẩn app; **không** khai báo intent filter, nên cắm cáp không tự mở app |
| `ios/Classes/PtpPlatformPlugin.swift` | `usbStatus` luôn trả `supported:false, IOS_NO_USB_API` |
| `app/lib/core/session/session.dart` | `PtpHost(loopbackOnly, flags)`: chế độ cáp chỉ nghe 127.0.0.1, QR mang cờ `usb` |
| `app/lib/app/controller.dart` | Luồng cáp: kiểm tra hỗ trợ → `usbStart` → chờ kết nối → đổi endpoint QR thành `127.0.0.1:bridgePort` → ghép đôi bình thường. Hỏi trạng thái mỗi 500 ms; cắm lại cáp giữa phiên thì mở lại liên kết trên cùng cổng để resume tự chạy |
| `app/lib/ui/flow_screen.dart` | Chọn "Wi-Fi / Cáp USB-C (thử nghiệm)" (chỉ Android), trạng thái cáp thật, hướng dẫn khi lỗi |

## 4. Các điểm kỹ thuật dễ sai (đã xử lý, cần xác nhận trên máy)
* **Gói ngắn (short packet):** Android không cho app gửi gói độ dài 0 (ZLP). Một lần ghi dài đúng bội số kích thước gói (64/512/1024) sẽ khiến bên đọc chờ mãi. `ShortPacketSafeOutputStream` tách byte cuối ra, nên mọi lần ghi đều kết thúc bằng một gói ngắn. Có test.
* **Đọc trọn lần truyền:** mỗi lần đọc bulk luôn xin bộ đệm 16 KiB (`BufferedInputStream`). Đọc nhỏ hơn lần truyền đến có thể mất byte. Chưa thể test điểm này trên máy chủ.
* **Kích thước truyền tối đa 16 KiB** (header + payload) cho mọi lần ghi.
* **Mất cáp:** bridge đóng mọi socket app → isolate nền thấy `NETWORK_INTERRUPTED` → chạy logic resume sẵn có. Controller khởi động lại `usbStart` cùng cổng; máy quét QR thử kết nối lại mỗi 3 giây trong 15 phút.

## 5. Bảo mật
* AOA chỉ chuyển byte. Nội dung đi trong TLS 1.3 đầu–cuối, ghim fingerprint từ QR; bridge không đọc được và không cần đọc dữ liệu.
* Host ở chế độ cáp chỉ nghe `127.0.0.1`; có test chứng minh kết nối từ interface mạng thật bị từ chối.
* Bên accessory chỉ mở accessory có `manufacturer=PhoneTransferPro`, `model=ChuyenDuLieu`. Đây chỉ là bộ lọc tiện dụng, không phải cơ chế xác thực; xác thực thật là TLS + QR + mã 6 số.
* Không thêm quyền runtime nào; quyền USB do hệ thống hỏi cho từng thiết bị.
* Log chỉ ghi `state`, `role`, mã lỗi (đã lọc theo whitelist).

## 6. Chế độ "Tự động" (Wi-Fi → cáp giữa chừng) — NOT_TESTED trên máy thật

Ba lựa chọn trên màn kết nối (chỉ Android): **Wi-Fi** (mặc định), **Tự động** (thử nghiệm), **Chỉ cáp** (thử nghiệm).
Máy hiện QR quyết định chế độ; QR mang cờ `usbauto` (hoặc `usb` với Chỉ cáp).

1. Phiên bắt đầu qua Wi-Fi như bình thường. Sau khi ghép đôi, nếu **cả hai máy là Android** và có hỗ trợ USB, cả hai
   bắt đầu chờ cáp ở chế độ nền (tối đa 6 giờ, kiểm tra mỗi 1 giây để tiết kiệm pin). Máy host chuyển kết nối từ cáp
   vào đúng cổng TLS của nó; máy joiner mở cổng cáp trên `127.0.0.1`.
2. Khi người dùng cắm cáp và đồng ý quyền USB, liên kết AOA được lập. **Chỉ khi đang truyền dữ liệu** (không trong lúc
   chọn dữ liệu, duyệt, tạm dừng hay đang kết nối lại), máy joiner ghi lại tốc độ Wi-Fi đo được 5 giây gần nhất rồi đóng
   socket Wi-Fi và kết nối lại qua cáp bằng **PTP/1 resume**: cùng phiên, ghim lại chứng chỉ theo QR, bằng chứng resume,
   máy nhận tiếp tục từ checkpoint. Cáp không được tin tưởng hơn Wi-Fi.
3. Bỏ qua 3 giây đầu, đo 8 giây trên cáp. Nếu cáp **< 85%** tốc độ Wi-Fi vừa đo → quay lại Wi-Fi và không thử lại cho
   tới khi rút/cắm lại cáp. Nếu chưa đo được Wi-Fi (cắm cáp ngay từ đầu) → giữ cáp, không so với số đoán.
4. Rút cáp khi đang chạy trên cáp → quay về Wi-Fi qua cùng cơ chế resume; tiếp tục chờ cáp cắm lại.
5. Lỗi quyền USB / thiết bị lạ / máy không hỗ trợ → dừng thử cáp, ở lại Wi-Fi, không hỏi lại.

Mã: `core/transfer/path_policy.dart` (quyết định, thuần logic), `MigrationController._armUsbAuto/_pathTick`,
lệnh worker `dial`. Log: `path_switch from/to/reason/wifiMbps/cableMbps` (không có dữ liệu cá nhân).
Test: `path_policy_test.dart` (6 quyết định), `path_handover_test.dart` (đổi đường giữa một tệp 24 MB qua hai bộ
chuyển tiếp TCP cục bộ — chứng minh cơ chế resume, **không** chứng minh tốc độ cáp hay phần cứng USB).

Giới hạn: kênh AOA là USB 2.0, có thể chậm hơn Wi-Fi 5 GHz tốt — vì vậy quyết định dựa trên số đo, không mặc định
"cáp nhanh hơn". Mỗi lần đổi đường mất vài giây kết nối lại và có thể gửi lại tối đa phần chưa checkpoint (≤ 8 MiB).
Không áp dụng khi có iPhone.

## 7. Chưa làm (sau khi POC chạy được trên máy thật)
* Ethernet có dây (W2) và nhập ảnh qua PTP từ iPhone (W3) — xem tài liệu nghiên cứu.
* Đo hiệu năng: tốc độ, CPU, RAM, nhiệt độ, pin, thời gian thiết lập (chỉ sau khi có thiết bị).
