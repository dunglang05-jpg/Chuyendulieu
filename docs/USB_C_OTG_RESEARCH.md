# Nghiên cứu kết nối USB-C / OTG — Phone Transfer Pro

Nhánh: `feature/usb-c-otg-transfer` · Ngày: 2026-11-09 · Trạng thái: **nghiên cứu xong; POC AOA Android ↔ Android đã có code và qua CI (xem `USB_C_OTG_ARCHITECTURE.md`, `USB_C_OTG_TEST_REPORT.md`); chưa thử trên thiết bị**

> Mọi kết luận "khả thi" dưới đây là **khả thi theo tài liệu/API công khai**, chưa phải đã chứng minh. Mọi chiều đều là **NOT_TESTED** cho tới khi có thiết bị thật, log và SHA-256.

---

## 1. Kiến trúc hiện tại và chỗ gắn USB

| Thành phần | Hiện trạng | Liên quan đến USB |
|---|---|---|
| Giao thức PTP/1 (`app/lib/core/protocol`) | Khung truyền (`FrameReader` đọc từ `Stream<Uint8List>`, `FrameWriter` ghi vào `IOSink`), manifest, SHA-256, resume | **Không phụ thuộc TCP**: chỉ cần một luồng byte hai chiều tin cậy, có thứ tự |
| Phiên (`core/session/session.dart`) | `SecureServerSocket.bind` / `SecureSocket.connect` — TLS 1.3, ghim fingerprint từ QR | TLS của Dart (`SecureSocket`) **chỉ chạy trên Socket TCP**, không chạy trực tiếp trên file descriptor USB |
| Engine (`core/transfer/engine.dart`) | Streaming, cửa sổ 32 MiB, ack 8 MiB, checkpoint, retry hash | Dùng lại nguyên vẹn |
| Isolate nền (`core/worker/transfer_worker.dart`) | Sở hữu socket + engine | Dùng lại nguyên vẹn |
| Native (`packages/ptp_platform`) | 12 lệnh MethodChannel (probe, quyền, quét, mở/đóng file, nhập, dịch vụ nền…) | Thêm lệnh USB ở đây (Kotlin), iOS không có gì để thêm (mục 3) |
| Chọn địa chỉ (`localEndpoints`) | Lấy IPv4 riêng (10/172.16/192.168) của mọi interface | Interface Ethernet qua USB **đã được lấy tự động** nếu có IP riêng |

**Kết luận kiến trúc:** cách ít rủi ro nhất là coi USB là **một "đường ống byte"** và cho TLS + PTP/1 chạy qua nó y như hiện nay. Không cần engine thứ hai, không đổi giao thức (chi tiết mục 6).

---

## 2. Khái niệm — tránh nhầm lẫn

| Khái niệm | Nghĩa | Không có nghĩa là |
|---|---|---|
| USB Host | Bên điều khiển bus, cấp nguồn, liệt kê thiết bị | — |
| USB Device / Peripheral | Bên bị điều khiển (điện thoại cắm vào máy tính) | — |
| USB Accessory (Android, AOA) | Android đóng vai *device*, bên kia (host) nói giao thức AOA | Không phải "phụ kiện MFi" của Apple |
| OTG / USB-C Dual-Role (DRP) | Cổng có thể làm host hoặc device; USB-C thương lượng vai trò khi cắm | Không đảm bảo app có API dùng vai trò đó |
| USB-C Power Delivery | Thương lượng **nguồn** (ai sạc ai) | **Không** liên quan đến truyền dữ liệu |
| Cáp USB-C → USB-C | Có cáp chỉ sạc (không có dây dữ liệu), cáp USB 2.0 (480 Mbit/s lý thuyết), cáp USB 3.x | Cắm được và sạc được **không** chứng minh có kênh dữ liệu app-to-app |
| "Nhận diện được thiết bị USB" | Hệ điều hành thấy thiết bị | **Không** có nghĩa app của mình nói chuyện được với app bên kia |

Quy tắc USB: mỗi liên kết chỉ có **một host**. Hai điện thoại nối trực tiếp thì một máy phải làm host, máy kia làm device.

---

## 3. Giới hạn API theo nền tảng (đã tra cứu)

### Android
* Có API công khai cho cả hai vai trò từ Android 3.1: **USB Host** (`UsbManager`, `UsbDevice`, bulk transfer) và **USB Accessory** (`UsbAccessory`, `openAccessory` → file descriptor). Theo tài liệu Android, ở chế độ accessory thì phần cứng bên ngoài làm host và cấp nguồn.
* **AOA (Android Open Accessory)**: host gửi các lệnh điều khiển (`GET_PROTOCOL`, `SEND_STRING`, `START`), máy kia khởi động lại USB ở chế độ accessory với VID/PID cố định, sau đó hai bên trao đổi qua **hai endpoint bulk**. Về lý thuyết, bên host có thể là **một điện thoại Android khác** dùng USB Host API. Cách nối điện thoại–điện thoại này được mô tả trong cộng đồng lập trình (máy A làm host, máy B chuyển sang chức năng accessory), nhưng **chưa có tài liệu chính thức nào bảo đảm nó chạy trên mọi máy** — phải thử.
* Điện thoại USB-C có mục **"USB do … điều khiển" (USB controlled by: This device / Connected device)** để chọn ai làm host. Một số máy khóa mục này ("can't switch").
* **MTP/PTP host**: `android.mtp.MtpDevice` (API 12) đọc được thiết bị PTP/MTP (máy ảnh, iPhone ở chế độ ảnh). API này **chỉ đọc** (không ghi được lên thiết bị).
* **Ethernet**: Android nhận USB-Ethernet (tùy driver/OEM). **Android 11+ có "Chia sẻ Internet qua Ethernet"**: điện thoại cấp mạng (DHCP) cho thiết bị cắm qua adapter Ethernet.
* **Android 16 Advanced Protection** (tùy chọn người dùng bật): khi máy **khóa**, kết nối USB mới chỉ được sạc, bị chặn dữ liệu; kết nối đã có từ trước không bị ngắt.

### iOS (iPhone)
* **Không có API USB tổng quát cho app bên thứ ba trên iPhone.** Apple DTS xác nhận DriverKit **chỉ có trên iPadOS** (iPad chip M), không có trên iOS. IOKit/IOUSBHost không có trên iOS.
* **ExternalAccessory** chỉ dành cho **phụ kiện MFi** dùng giao thức iAP2; không dùng cho giao tiếp USB tổng quát. Một điện thoại Android **không phải** phụ kiện MFi → không thể là đối tác EA.
* iPhone ở vai trò **device** (cắm vào host): phơi ra **PTP (ảnh/video)** sau khi người dùng bấm "Tin cậy". Đây là cách Samsung Smart Switch bắt đầu kết nối có dây (iPhone hỏi "Trust this computer?"). Phần dữ liệu ngoài ảnh mà Smart Switch lấy qua cáp dùng giao thức riêng của Apple (không có tài liệu công khai) → **chúng ta không dùng** (vi phạm `CLAUDE.md` §2).
* iPhone **hỗ trợ adapter USB-Ethernet**: iPhone 15+ qua USB-C. iPhone Lightning qua *Lightning to USB 3 Camera Adapter*, có danh sách adapter Ethernet được Apple nêu. iPhone 15/15 Plus chỉ có tốc độ USB 2.0; bản Pro có USB 3.
* iPhone → iPhone qua cáp: **Apple có hỗ trợ chính thức** (Quick Start có dây, cáp USB-C ↔ USB-C hoặc USB-C ↔ Lightning). Đây là chức năng **của hệ thống khi thiết lập máy**, không mở cho app bên thứ ba.

---

## 4. Ba cách "dùng dây" khả dĩ (không vi phạm quy tắc)

| Mã | Cách | Bản chất | Dùng cho chiều |
|---|---|---|---|
| **W1 — AOA** | Cáp USB-C ↔ USB-C nối thẳng 2 Android; máy A làm USB Host, máy B ở chế độ Accessory | Đường ống byte USB do app hai bên điều khiển | A→A (cả hai hướng dữ liệu) |
| **W2 — Ethernet có dây** | Mỗi điện thoại một adapter USB-C/Lightning → RJ45, nối bằng cáp mạng vào **một router nhỏ có DHCP**, hoặc vào điện thoại Android đang bật **chia sẻ Internet qua Ethernet** | Mạng LAN có dây — PTP/1 hiện tại chạy **không cần sửa giao thức** | **Cả 4 chiều** (lý thuyết) |
| **W3 — PTP nhập ảnh** | Cắm iPhone vào Android (Android làm host), iPhone bấm "Tin cậy/Cho phép" | Android đọc ảnh/video bằng `MtpDevice`; **không có app nào chạy trên iPhone** | i→A, **chỉ ảnh/video** |

Không có cách nào dùng **một sợi cáp duy nhất nối thẳng app–app** khi một bên là iPhone.

---

## 5. Ma trận khả năng (mọi chiều: NOT_TESTED)

| Chiều | Khả năng kỹ thuật | API cần dùng | Thiết bị thử | Trạng thái |
|---|---|---|---|---|
| Android → Android | **Khả thi theo tài liệu** (W1 nối thẳng; W2 Ethernet) | Kotlin `UsbManager` Host + Accessory (AOA); hoặc chỉ cần LAN hiện có | 2 Android (khác hãng) | NOT_TESTED |
| Android → iPhone | **RESTRICTED**: không có cáp nối thẳng app–app. Chỉ có W2 (Ethernet + router/tethering) | Không cần API USB; chỉ là LAN | 1 Android + 1 iPhone | NOT_TESTED |
| iPhone → Android | **RESTRICTED**: W2 cho mọi loại dữ liệu app hỗ trợ; W3 nối thẳng nhưng **chỉ ảnh/video, chỉ đọc** | W2: LAN · W3: `android.mtp.MtpDevice` | 1 iPhone + 1 Android | NOT_TESTED |
| iPhone → iPhone | **RESTRICTED**: app không có kênh USB nào; chỉ W2 (cần router có DHCP, vì iPhone không cấp DHCP qua Ethernet). Nên giới thiệu Quick Start có dây của Apple | LAN | 2 iPhone | NOT_TESTED |

Không chiều nào được xếp **UNSUPPORTED** hoàn toàn vì W2 có thể dùng được. Nhưng phương án **"cáp USB nối thẳng app–app"** thì **UNSUPPORTED** với mọi chiều có iPhone, theo API công khai hiện tại.

### Trả lời 9 câu hỏi cho từng chiều

| Câu hỏi | A → A (W1 AOA) | A → iPhone (W2) | iPhone → A (W2 / W3) | iPhone → iPhone (W2) |
|---|---|---|---|---|
| 1. Nối thẳng bằng cáp? | Có, 1 cáp C↔C (theo tài liệu) | **Không** nối thẳng; cần 2 adapter Ethernet + cáp mạng + router hoặc tethering | W2: không nối thẳng · W3: có, 1 cáp | **Không**; cần 2 adapter + router |
| 2. Ai là USB Host? | Máy chọn "USB do máy này điều khiển" | Mỗi điện thoại là host của adapter Ethernet của nó | W3: Android | Mỗi iPhone là host của adapter của nó |
| 3. Ai là Device/Accessory? | Máy kia, ở chế độ AOA | Adapter Ethernet | W3: iPhone (PTP) | Adapter Ethernet |
| 4. Cần adapter/phụ kiện chứng nhận? | Không (cáp có dây dữ liệu) | Không cần MFi; adapter USB-C Ethernet thông dụng; iPhone Lightning cần Camera Adapter của Apple | W3: không | Như cột 2 |
| 5. iOS cần app đặc biệt? | — | App này, chạy LAN như hiện tại | W2: app này · W3: **không cần app** trên iPhone | App này trên cả hai |
| 6. Truyền hai chiều? | Có (2 endpoint bulk) | Có (TCP) | W2: có · W3: **chỉ iPhone → Android** | Có |
| 7. Chạy khi tắt màn hình? | Android: có thể, nhờ foreground service (chưa thử). Advanced Protection chặn kết nối **mới** khi khóa | iPhone: **không**, iOS chỉ chạy foreground (giống Wi-Fi) | W3: iPhone phải mở khóa lúc cấp quyền | Không (iOS foreground) |
| 8. Giới hạn kích thước/thời gian? | Không do giao thức; giới hạn dataSync ~6 giờ/ngày trên Android 15+ | Như Wi-Fi hiện tại | W3: file > 4 GB phụ thuộc thiết bị có hỗ trợ đọc 64-bit; chưa rõ với iPhone | Như Wi-Fi |
| 9. Phương án thay thế? | Wi-Fi/hotspot hiện có | Wi-Fi/hotspot hiện có | Wi-Fi/hotspot hiện có | Wi-Fi hiện có; **Quick Start có dây của Apple** khi thiết lập máy mới |

---

## 6. Kiến trúc USB transport đề xuất (chưa triển khai)

**Nguyên tắc:** một engine, một giao thức. USB chỉ cung cấp đường ống byte; TLS 1.3 + ghim fingerprint + mã 6 số **vẫn bắt buộc** vì cáp không được coi là kênh tin cậy.

```
 Máy H (hiện QR, TLS server)                         Máy J (quét QR, TLS client)
 ┌──────────────────────────┐                        ┌──────────────────────────┐
 │ Worker isolate           │                        │ Worker isolate           │
 │  PtpHost ─ TLS server    │                        │  joinSession ─ TLS client│
 │  127.0.0.1:hostPort      │                        │  → 127.0.0.1:bridgePort  │
 └──────────▲───────────────┘                        └──────────▲───────────────┘
            │ TCP loopback                                      │ TCP loopback
 ┌──────────┴───────────────┐   cáp USB-C (AOA)     ┌──────────┴───────────────┐
 │ Kotlin UsbPipe           │◄═════ 2 bulk endpoint ═►│ Kotlin UsbPipe           │
 │ (host HOẶC accessory)    │   khung mux tối giản   │ (vai trò còn lại)        │
 └──────────────────────────┘                        └──────────────────────────┘
```

* **Kotlin `UsbPipe`** (mới): ở máy USB-host, liệt kê thiết bị, xin quyền, gửi lệnh AOA, mở endpoint bulk. Ở máy accessory, nhận `USB_ACCESSORY_ATTACHED` rồi gọi `openAccessory`. Cả hai bơm byte giữa USB và một **socket loopback 127.0.0.1**, với khung mux 5 byte (`OPEN`/`DATA`/`CLOSE`) để hỗ trợ kết nối lại khi resume.
* **Dart:** không đổi giao thức. Bổ sung khái niệm `TransportKind { wifiLan, wiredEthernet, usbAoa }` và một bộ chọn: *Tự động / Ưu tiên USB / Chỉ USB / Không dây*. Với "Chỉ USB", không bao giờ thử địa chỉ Wi-Fi. QR vẫn dùng để ghép đôi: máy quét thay endpoint bằng `127.0.0.1:bridgePort` khi đi USB.
* **Lý do không chạy TLS thẳng trên USB:** `SecureSocket` của Dart chỉ nhận TCP Socket. Cầu nối loopback giữ nguyên toàn bộ phần đã được kiểm thử (TLS, ghim, resume, SHA-256).
* **W2 (Ethernet):** gần như không cần code. Chỉ cần (a) hiển thị loại interface (Wi-Fi / Ethernet) trong màn QR, (b) ưu tiên endpoint Ethernet khi người dùng chọn có dây, (c) tùy chọn hỗ trợ địa chỉ link-local `169.254.x` khi không có DHCP. Mục (c) cần thử, vì Android có thể không tự gán địa chỉ này.
* **W3 (PTP nhập ảnh từ iPhone):** là một **nguồn dữ liệu cục bộ** trên Android, không đi qua PTP/1. Kotlin `MtpDevice` liệt kê và đọc theo luồng vào inbox, tính SHA-256 khi đọc, rồi dùng lại luồng nhập vào MediaStore hiện có. PTP không cung cấp hash gốc, nên chỉ kiểm tra được kích thước và tính toàn vẹn của lần đọc (đọc lại để so sánh là tùy chọn). Đây phải là chế độ riêng, ghi rõ "chỉ ảnh/video".
* **Bảo mật:** kênh USB vẫn phải ghép đôi bằng QR (hoặc mã), dùng TLS và xác nhận mã 6 số. Bên accessory chỉ chấp nhận AOA khi app đang ở màn "Nhận qua cáp". Không có quyền mới ngoài USB (quyền USB do hệ thống hỏi mỗi thiết bị). Log chỉ ghi loại transport, vai trò, mã lỗi.
* **Kiểm thử không cần phần cứng:** tách `UsbPipe` thành lớp bơm byte có thể test bằng cặp socket giả trên JVM. Lớp mux có test đơn vị. Phần Dart đã có test loopback.

---

## 7. Rủi ro ảnh hưởng ứng dụng hiện tại

| Rủi ro | Mức | Giảm thiểu |
|---|---|---|
| Khai báo `<uses-feature android:name="android.hardware.usb.host">` bắt buộc làm CH Play ẩn app trên máy không có USB host | Cao | Khai báo `required="false"`; kiểm tra lúc chạy |
| Intent filter `USB_ACCESSORY_ATTACHED` làm hệ thống tự mở app khi cắm cáp | Trung bình | Chỉ xử lý khi đang ở màn "Nhận qua cáp"; còn lại bỏ qua |
| Thay đổi chọn endpoint làm hỏng Wi-Fi hiện tại | Cao | Mặc định giữ hành vi cũ; chỉ khác khi người dùng chọn chế độ có dây; test hồi quy loopback giữ nguyên |
| OEM khóa "USB do … điều khiển", hoặc kernel không bật USB gadget accessory | Trung bình | Phát hiện và báo rõ, chuyển sang Wi-Fi (trừ khi chọn "Chỉ USB") |
| Advanced Protection (Android 16) chặn kết nối khi máy khóa | Thấp–TB | Hướng dẫn mở khóa trước khi cắm |
| Máy host phải cấp nguồn cho máy kia → hao pin máy host | Trung bình | Hướng dẫn chọn máy pin nhiều làm host; hiển thị pin |
| Cáp chỉ sạc, không có dây dữ liệu | Cao (hay gặp) | Phát hiện "không thấy thiết bị" → hướng dẫn đổi cáp |
| Tăng dung lượng APK, độ phức tạp | Thấp | Phần Kotlin nhỏ, không thêm thư viện |
| W3 có vẻ như "chuyển toàn bộ iPhone" | Cao (kỳ vọng) | UI ghi rõ "chỉ ảnh và video, chỉ đọc" |

---

## 8. Thiết bị và phụ kiện cần để kiểm thử

| Mục | Số lượng | Dùng cho | Ghi chú |
|---|---|---|---|
| Điện thoại Android 11+ hãng A (vd. Samsung) | 1 | Tất cả | Có mục "USB do … điều khiển" |
| Điện thoại Android 11+ hãng B (vd. Xiaomi/OPPO) | 1 | W1, W2 | Khác hãng để thử khác kernel/OEM |
| Điện thoại Pixel Android 16 | 1 (nếu có) | Advanced Protection | Tùy chọn |
| iPhone 15 trở lên (USB-C) | 1 | W2, W3 | Bản thường là USB 2.0; bản Pro là USB 3 |
| iPhone 14 trở xuống (Lightning) | 1 (nếu có) | W2, W3 | Để thử nhánh Lightning |
| Cáp USB-C ↔ USB-C **có dữ liệu** | 2 | W1, W3 | 1 cáp USB 2.0 thường + 1 cáp USB 3.x (10 Gbps) để so sánh |
| Cáp Lightning ↔ USB-C | 1 | W3 với iPhone Lightning | Cáp Apple hoặc MFi |
| Adapter USB-C → Ethernet Gigabit | 2 | W2 | Chip phổ biến như RTL8153/AX88179; ưu tiên loại có cổng sạc PD |
| Apple Lightning to USB 3 Camera Adapter + adapter USB-A Ethernet + củ sạc | 1 bộ | W2 với iPhone Lightning | Adapter USB-A nên thuộc danh sách Apple nêu |
| Cáp mạng Cat6 ngắn | 2 | W2 | |
| Router du lịch nhỏ có DHCP | 1 | W2 khi không dùng tethering (bắt buộc cho iPhone → iPhone) | Không cần Internet |
| Adapter OTG USB-C (đực) → USB-A (cái) | 1 | Máy cũ / cáp USB-A | |

---

## 9. Đề xuất thứ tự POC (chờ duyệt)

1. **W2 — Ethernet có dây** cho cả 4 chiều. Ít code nhất, rủi ro thấp nhất, cùng giao thức. Việc cần làm: nhận diện interface Ethernet, chọn chế độ "Có dây", thử Android Ethernet tethering, thử link-local.
2. **W1 — AOA Android ↔ Android**: Kotlin `UsbPipe` + cầu nối loopback + mux, test JVM, thử trên 2 máy.
3. **W3 — Nhập ảnh/video từ iPhone qua PTP** (chế độ riêng, chỉ đọc).
4. Bộ chọn kết nối (Tự động / Ưu tiên USB / Chỉ USB / Không dây) và giao diện trạng thái cáp.

Mỗi POC sẽ có sơ đồ, danh sách thiết bị, phiên bản OS, cáp/adapter, log đã lọc, SHA-256 và giới hạn phát hiện được. Không công bố tốc độ nào khi chưa đo.

---

## Nguồn tham khảo

* Android — USB host and accessory overview: https://developer.android.com/develop/connectivity/usb
* Android Open Accessory 2.0: https://source.android.com/accessories/aoa2.html
* Android Developers Blog — Android Open Accessories: https://android-developers.googleblog.com/2011/05/bright-idea-android-open-accessories.html
* `android.mtp` package (PTP/MTP host, API 12): https://stuff.mit.edu/afs/sipb/project/android/docs/reference/android/mtp/package-summary.html
* Apple Developer Forums — DriverKit chỉ có trên iPadOS: https://developer.apple.com/forums/thread/801333 , https://developer.apple.com/forums/thread/804601
* Apple Developer Forums — iPhone không giao tiếp USB tổng quát được; EA chỉ dành cho MFi/iAP2: https://developer.apple.com/forums/thread/834899 , https://developer.apple.com/forums/thread/790192
* Apple — ExternalAccessory framework: https://developer.apple.com/tutorials/data/documentation/externalaccessory.md
* Apple — Use a wired connection to transfer data to a new iPhone: https://support.apple.com/en-md/117383
* Apple — USB-A camera adapters, adapter Ethernet được hỗ trợ: https://support.apple.com/en-afri/111811
* MacRumors — iPhone 15 hỗ trợ USB-C Ethernet: https://macrumors.com/2023/09/22/iphone-15-usb-c-to-ethernet
* Notebookcheck — iPhone 15/15 Plus chỉ USB 2.0: https://www.notebookcheck.com/Apples-iPhone-15-unterstuetzt-jetzt-auch-Netzwerkkabel-per-Adapter.750420.0.html
* Samsung — Smart Switch iPhone → Galaxy qua cáp, "Trust this computer": https://www.samsung.com/uk/support/mobile-devices/what-to-do-if-your-samsung-galaxy-phone-folder-does-not-appear-on-pc-connection/
* Android Police — Android 11 Ethernet tethering: https://www.androidpolice.com/2020/04/23/ethernet-tethering-arrives-in-latest-android-11-developer-preview
* Android Authority — Android 16 Advanced Protection chặn dữ liệu USB khi khóa: https://www.androidauthority.com/android-16-usb-data-advanced-protection-3548018
* Sony Xperia help — mục "USB controlled by": https://helpguide.sony.net/mobile/xperia-10/v1/en-us/contents/connecting-your-device-to-usb-accessories.html
