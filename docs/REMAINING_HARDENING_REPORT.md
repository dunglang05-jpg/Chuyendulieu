# Báo cáo xử lý P1/P2 còn lại — 2026-11-09

Nhánh `feature/usb-c-otg-transfer` (không sửa `main`, không merge).
Mọi số liệu bên dưới đến từ CI GitHub Actions (máy chủ Ubuntu / macOS), **không phải từ điện thoại**.
**Chưa có thử nghiệm nào trên thiết bị thật** cho các thay đổi trong báo cáo này.

## Tóm tắt

| ID | Trạng thái sau đợt này | Cần thiết bị thật để kết luận |
|---|---|---|
| P1-7 Android ghi 2 lần | **Đã sửa** (ghi thẳng vào MediaStore, 1 lần) | Có: đường `/proc/self/fd` của mục MediaStore đang chờ, máy gần đầy |
| P1-8 ML Kit / DataTransport | **Giảm một phần**: iOS hết ML Kit; Android **vẫn còn** | Có: so sánh độ chính xác/tốc độ quét |
| P1-9 Kotlin Gradle Plugin | **Đã sửa** cho `ptp_platform`; cảnh báo Flutter **đã hết** | Không (build CI là bằng chứng) |
| P1-10 Khôi phục sau khi tắt app | **Đã làm** (ghép đôi lại + xác minh, không khôi phục TLS) | Có: kill tiến trình thật, khởi động lại máy, Keystore/Keychain thật |
| P1-11 TLS | **Đã kiểm tra, giới hạn vẫn còn** (không ép được 1.3 trong Dart) | Không |
| P2-18 Kiểm tra sau khi ghi | **Đã làm** (luôn kiểm kích thước; chế độ đọc lại tùy chọn) | Có: chi phí trên điện thoại |
| Giao diện 2 màn hình | **Đã làm** theo phong cách Đất sét 3D | Có: xem trên máy |

## Kết quả CI cuối

Run [42567659181](https://github.com/dunglang05-jpg/Chuyendulieu/actions/runs/42567659181), commit `69ae8ef`, tất cả job **success**:

| Hạng mục | Trước đợt này (run 42561004021) | Sau |
|---|---|---|
| `flutter analyze` | No issues | No issues |
| Test Dart | 35/35 | **54/54** (thêm 19) |
| Test Python giao thức | 45/45 | 45/45 |
| Test JVM Kotlin (USB bridge) | BUILD SUCCESSFUL | BUILD SUCCESSFUL |
| APK release arm64 | 33,5 MB | **36,2 MB** (mobile_scanner 7.5, xem P1-8) |
| iOS (không ký) | Build OK | Build OK |
| Cảnh báo KGP của Flutter | Có (`mobile_scanner, ptp_platform`) | **Không còn** |

Không test nào bị xóa. Hai lần CI đỏ trong đợt này đều do chính test mới: một test bị quá thời gian 30 s (đã đặt thời hạn dài hơn), và một test dùng `transferId` không hợp lệ (22 ký tự `C` có bit đệm khác 0) khiến máy nhận từ chối manifest; đã sửa test, không sửa code để "cho qua".

---

## P1-7 — Máy nhận Android ghi dữ liệu hai lần

**Trước:** mỗi tệp được nhận vào thư mục riêng của app (`files/inbox/.ptp-partial/…`), kiểm SHA-256, đổi tên, rồi `MediaAdapter.importFile` **sao chép toàn bộ** sang MediaStore và xóa bản trong inbox. Mỗi byte ảnh/video bị ghi 2 lần và đọc thêm 1 lần; lúc nhập, tệp chiếm gấp đôi dung lượng. Kiểm tra dung lượng chỉ tính phần còn phải nhận, không tính bản sao. Hết dung lượng giữa chừng trả về `INTERNAL_ERROR` và máy gửi chỉ thấy mất kết nối.

**Nguyên nhân:** thiết kế "nhận vào inbox rồi nhập" dùng chung cho mọi nền tảng; trên Android việc nhập là sao chép (app không thể đổi tên tệp riêng vào bộ nhớ dùng chung).

**Cách sửa:**
- `ReceiverStore` có thêm `MediaSink`. Trên Android, ảnh/video/âm thanh/tài liệu được ghi **thẳng** vào một mục MediaStore tạo với `IS_PENDING=1` (ẩn khỏi thư viện). Sau khi SHA-256 khớp, mục được công bố (`IS_PENDING=0`) — không sao chép.
- Danh bạ vẫn đi qua inbox (nhập qua app Danh bạ). iOS giữ inbox vì Photos nhập bằng `shouldMoveFile` (di chuyển, không sao chép).
- Dung lượng cần = phần còn phải nhận + tệp lớn nhất **còn phải sao chép khi nhập** (chỉ khi có).
- Nối lại trong cùng phiên: checkpoint lưu `uri` của mục đang chờ và mở lại đúng mục đó, không tạo mục thứ hai.
- Nếu đường dẫn `/proc/self/fd/N` của mục không mở được bằng Dart trên một máy nào đó: xóa mục đang chờ, **tự chuyển về inbox** cho tệp đó, ghi log `media_sink_fallback`.
- `ENOSPC`/`EDQUOT` khi ghi → `STORAGE_INSUFFICIENT`, gửi khung lỗi cho máy gửi, checkpoint giữ nguyên để tiếp tục sau khi dọn bộ nhớ.
- Hủy, sai SHA-256, "Xóa dữ liệu tạm": xóa luôn các mục MediaStore đang chờ. MediaStore cũng tự dọn mục chờ bị bỏ quên.

**Tệp:** `app/lib/core/transfer/receiver_store.dart`, `engine.dart`, `core/worker/transfer_worker.dart`, `app/controller.dart`, `packages/ptp_platform/android/…/MediaAdapter.kt`, `PtpPlatformPlugin.kt`, `packages/ptp_platform/lib/ptp_platform.dart`.

**Test mới (`test/receiver_sink_test.dart`, 5):** tệp ảnh chỉ có đúng 1 bản trong "bộ nhớ dùng chung" và không có bản trong inbox; dung lượng xin đúng bằng dữ liệu (không cộng bản sao); khi không ghi thẳng thì cộng tệp lớn nhất; đường dẫn không mở được → về inbox, xóa mục chờ, vẫn khớp SHA-256; nối lại dùng lại mục chờ cũ từ checkpoint 8 MiB; `ENOSPC` → `STORAGE_INSUFFICIENT`. MediaStore thật được thay bằng thư mục.

**Hiệu năng:** về cấu trúc, bỏ được 1 lần ghi + 1 lần đọc toàn bộ mỗi tệp media và bỏ đỉnh 2× dung lượng. **Chưa đo trên điện thoại.**

## P1-8 — Thư viện quét QR: ML Kit và Google DataTransport

**Trước:** `mobile_scanner` 5.2.3 kéo Google ML Kit + Google DataTransport vào **cả Android và iOS**.

**Đã xác định (CI, `releaseRuntimeClasspath` + manifest gộp):** trên Android, tất cả đều đến từ `project :mobile_scanner`:
`com.google.mlkit:barcode-scanning:17.3.0`, `play-services-mlkit-barcode-scanning:18.3.1`, `com.google.mlkit:common`, `vision-common`, `com.google.android.datatransport:transport-api / transport-runtime / transport-backend-cct`, `firebase-components / encoders`. Thành phần trong manifest: `MlKitComponentDiscoveryService`, `MlKitInitProvider`, `GoogleApiActivity`, `TransportBackendDiscovery`, `JobInfoSchedulerService`, `AlarmManagerSchedulerBroadcastReceiver` (đều `exported=false`). Quyền `ACCESS_NETWORK_STATE` trong APK hiện đến từ các thư viện này (plugin của mình đã bỏ ở P2-17).

**Dữ liệu có thể gửi ra ngoài:** theo [trang công bố dữ liệu ML Kit cho Android](https://developers.google.com/ml-kit/android-data-disclosure) của Google, SDK thu thập thông tin thiết bị (hãng, model, phiên bản OS), thông tin ứng dụng và số liệu hiệu năng để chẩn đoán và thống kê sử dụng, mã hóa HTTPS, không chia sẻ bên thứ ba. Việc giải mã QR chạy trên máy. ML Kit không có API chính thức để tắt phần này. Chúng mình **chưa đo lưu lượng mạng thật** từ app.

**Đã làm:** nâng `mobile_scanner` 5.x → **7.5** (cùng thư viện, không thay thư viện khác). Bản 7 dùng Apple Vision trên iOS: CI xác nhận `ios/Podfile.lock` **không còn** pod ML Kit / DataTransport. Android vẫn dùng ML Kit bản đóng gói sẵn. Cách gọi trong `flow_screen.dart` (`MobileScanner(onDetect: …)`) không đổi. APK tăng 33,5 → 36,2 MB.

**Chưa làm và lý do:** chưa thay thư viện Android (ví dụ một bản ZXing chạy hoàn toàn trên máy), vì yêu cầu phải chứng minh tương đương về độ chính xác và tốc độ quét, mà việc đó cần camera thật. Đề xuất phép thử: cùng 2 máy, 50 lần quét mã QR ghép đôi trên màn hình máy kia ở 3 mức sáng, đo tỉ lệ thành công và thời gian đến khi nhận mã, so `mobile_scanner` với ứng viên ZXing; đồng thời ghi lưu lượng mạng của app khi quét.

**Cần thiết bị:** quét QR trên iPhone sau khi đổi sang Apple Vision (chưa thử), và phép so sánh trên.

## P1-9 — Kotlin Gradle Plugin

**Trước:** Flutter cảnh báo *"plugins that apply Kotlin Gradle Plugin (KGP): mobile_scanner, ptp_platform. Future versions of Flutter will fail to build…"*.

**Môi trường thật trên CI:** Flutter 3.47.9, project sinh bởi `flutter create` dùng AGP **9.1.0**, Kotlin **2.4.0**, Gradle 9.3.1, `android.builtInKotlin=false`, `android.newDsl=false`.

**Cách sửa (theo [hướng dẫn chính thức cho tác giả plugin](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors)):** `ptp_platform/android/build.gradle` bỏ `apply plugin: 'kotlin-android'` và `kotlinOptions`, thêm `kotlin { compilerOptions { jvmTarget = JVM_17 } }`; classpath AGP 9.1.0, bỏ classpath KGP 1.9.24; plugin yêu cầu Flutter ≥ 3.44 (app nâng theo). `mobile_scanner` 7.5 chỉ áp KGP khi built-in Kotlin tắt. Không nâng dependency nào khác.

**Kết quả:** debug APK, release arm64 APK và test JVM Kotlin đều build được; cảnh báo KGP của Flutter **không còn** trong log. Gradle vẫn in một dòng thông tin rằng plugin `org.jetbrains.kotlin.android` trong `:mobile_scanner` "không còn cần thiết từ AGP 9" — đó là phần của thư viện, không phải lỗi.

**Còn lại:** iOS báo `ptp_platform` chưa hỗ trợ Swift Package Manager ("sẽ thành lỗi trong bản Flutter sau") — ngoài phạm vi đợt này, cần làm tiếp.

## P1-10 — Tiếp tục sau khi app bị đóng / máy khởi động lại

**Trước:** khóa phiên, chứng chỉ tạm và resume token chỉ ở RAM; tắt app là mất khả năng tiếp tục. Checkpoint JSON vẫn trên đĩa nhưng không được bảo vệ, và **bất kỳ** máy gửi nào gửi đúng `transferId` cũng được ghi tiếp vào dữ liệu dở.

**Thiết kế (không khôi phục TLS từ JSON):**
1. Sau khi tắt app, hai máy **ghép đôi lại như lần đầu**: QR mới, chứng chỉ mới, người dùng xác nhận mã 6 số.
2. Ở lần ghép đôi đầu tiên, hai máy cùng tạo một khóa tiếp tục K 32 byte từ số ngẫu nhiên của **cả hai** bên, gắn với phiên đó. K chỉ lưu trong **Android Keystore** (AES-256-GCM, khóa không xuất được, tệp mã hóa trong `noBackupFilesDir`, tên mục làm dữ liệu xác thực) hoặc **iOS Keychain** (`AfterFirstUnlockThisDeviceOnly`: không đồng bộ iCloud, không theo bản sao lưu sang máy khác, đọc được sau lần mở khóa đầu tiên kể cả sau khi khởi động lại). Tệp mô tả (không chứa K) có HMAC bằng K.
3. Sau khi ghép đôi lại, mỗi máy chứng minh biết K bằng HMAC **gắn với phiên mới** (băm của session id, chứng chỉ ghim, hai nonce bắt tay) → bằng chứng cũ không dùng lại được (chống replay). Hai máy phải **cùng xác nhận một id**; nếu không thống nhất, không tiếp tục gì cả và chuyển lại từ đầu.
4. Máy nhận chỉ dùng lại dữ liệu dở cho các `transferId` mà cả hai đã thống nhất; checkpoint có HMAC bằng K, checkpoint bị sửa, hỏng hoặc của khóa khác → bỏ qua, tệp đó chuyển lại từ 0. Dữ liệu dở vẫn được băm lại khi nối và SHA-256 cuối cùng của máy gửi vẫn là chốt chặn cuối.
5. Máy gửi lưu kế hoạch gửi (danh sách mục đã chọn, `transferId` từng lô, lô kế tiếp) và gửi tiếp phần còn lại; máy nhận vẫn phải đồng ý manifest.
6. Bản ghi hết hạn sau 24 giờ; xóa khi chuyển xong hoặc khi người dùng hủy. Trang chủ hiện thẻ "Có lần chuyển chưa xong".
7. Tương thích ngược: khả năng `cont1` khai báo trong capabilities (schema đã cập nhật); bên không khai báo (bản cũ, peer Python) thì bỏ qua bước này.

**Tệp:** `core/session/continuation.dart` (mới), `app/continuation_repo.dart` (mới), `core/session/session.dart`, `core/domain/capabilities.dart`, `core/worker/transfer_worker.dart`, `core/transfer/receiver_store.dart`, `app/controller.dart`, `ui/home_screen.dart`, `ui/flow_screen.dart`, `contracts/capability.schema.json`, `…/SecureVault.kt` (mới), `ios/Classes/PtpPlatformPlugin.swift` (`Vault`), `lib/ptp_platform.dart`.

**Test mới (`test/continuation_test.dart`, 10):** hai bên cùng giữ bản ghi → cùng tiếp tục; không ai giữ → cùng sinh khóa và id mới giống nhau; chỉ một bên giữ → không tiếp tục; cùng id khác khóa (giả mạo) → từ chối; bản ghi > 24 giờ không được đưa ra; khác vai trò không khớp; bằng chứng của phiên này sai ở phiên khác; checkpoint bị sửa / hỏng / khác khóa bị bỏ qua; dữ liệu dở của lần chuyển không được thống nhất **không** được dùng lại (bắt đầu từ 0, SHA-256 khớp); kho bản ghi: khóa không nằm trong JSON, bản ghi bị sửa / mất khóa / hết hạn bị xóa.

**Giới hạn:** các test dùng hai phiên TLS thật trên cùng một máy và thư mục tạm; **không** chứng minh hành vi khi Android/iOS thật sự kill tiến trình, khi máy khởi động lại, hay Keystore/Keychain trên máy thật. Tài liệu chọn qua trình chọn tệp có thể mất quyền đọc sau khi app khởi động lại → các tệp đó sẽ báo lỗi, không làm hỏng phần khác.

## P1-11 — TLS

**Đo thật trên CI** (`openssl s_client` nối vào `PtpHost` thật, test `verify_tls_test.dart`):

| Client | Kết quả |
|---|---|
| Mặc định (mọi phiên bản) | **TLSv1.3** |
| Chỉ TLS 1.1 | Bị từ chối |
| Chỉ TLS 1.2 | **Vẫn được chấp nhận (TLSv1.2)** |

**Kết luận:** API `SecureServerSocket`/`SecureSocket` của Dart không có tùy chọn phiên bản tối thiểu, nên **không ép được TLS 1.3**. Ghim chứng chỉ qua QR **không thay thế** chính sách phiên bản: nó chống giả mạo máy kia, không chống việc bắt tay ở 1.2. Hai app thật cùng dùng BoringSSL nên giữa hai điện thoại phiên bản là 1.3; một client chỉ hỗ trợ 1.2 vẫn phải vượt qua ghim chứng chỉ, bằng chứng HMAC của session id và mã 6 số mới vào được. Test được viết để **thất bại** nếu một bản Dart sau này bắt đầu từ chối 1.2, khi đó cần cập nhật tài liệu. Con đường ép 1.3 thật sự là đưa TLS xuống native (Conscrypt / Network.framework) — chưa làm, thay đổi lớn.

## P2-18 — Kiểm tra tệp sau khi ghi

**Trước:** máy nhận băm dữ liệu trong lúc nhận, không kiểm lại gì trên đĩa.

**Đã làm:**
- Luôn bật: trước khi công bố/đổi tên, kích thước tệp **trên đĩa** phải đúng kích thước khai báo (một lệnh stat, không thêm I/O). Phát hiện tệp bị cắt cụt.
- Chế độ tăng cường `VerifyMode.full` (cờ `strictVerify` trong controller, **mặc định tắt**): đọc lại toàn bộ tệp ở đích cuối và so SHA-256 với giá trị máy gửi; khác → không công bố, báo `hash_mismatch`. Không tạo bản sao nào.

**Chi phí đo trên CI (không phải điện thoại), 32 MiB qua TLS loopback:**

| Run | Chỉ kiểm kích thước | Đọc lại toàn bộ | Phần đọc lại |
|---|---|---|---|
| 42566724932 | 3 282 ms | 3 331 ms | 381 ms, +32 MiB đọc |
| 42567659181 | 2 599 ms | 2 895 ms | 419 ms, +32 MiB đọc |

**Lưu ý trung thực:** ngay sau `fsync`, lần đọc lại thường lấy từ bộ nhớ đệm của hệ điều hành chứ không từ chip nhớ, nên chế độ này bắt được lỗi đường ghi (sai vị trí, cắt cụt, fd hỏng) hơn là lỗi phần cứng. App không có quyền bỏ qua bộ nhớ đệm.

**Test mới (`test/verify_tls_test.dart`, 3 cho P2-18):** đọc lại băm đúng số byte và báo chi phí; tệp bị thay đổi sau khi băm bị từ chối, không xuất hiện ở đích; tệp bị cắt cụt bị bắt bởi kiểm tra kích thước.

## Giao diện

`ui/info_screens.dart`: "Dữ liệu nào chuyển được?" (thẻ nổi cho từng nhóm, nhãn trạng thái có chữ + màu cho Android/iPhone, phần không chuyển được trong khung lõm, cách chính thức của app chat) và "Lịch sử chuyển" (thẻ cho từng lần, ngày giờ, dung lượng, số thành công/lỗi, nhãn trạng thái; màn hình trống có hình). Không đổi logic truyền.

## Ngoài phạm vi ban đầu nhưng bạn yêu cầu trong lúc làm

Icon ứng dụng (commit `901e129`): hai điện thoại + mũi tên hai chiều trên nền gradient lavender; Android adaptive icon + bộ AppIcon iOS sinh bởi `flutter_launcher_icons` trong `tool/bootstrap.sh`; ảnh gốc vẽ bằng `tool/make_icon.py`.

## Kiểm tra Git diff và bí mật

Đã xem diff `99e7500..HEAD`. Không có khóa ký, token, mật khẩu hay khóa riêng nào được commit. APK release vẫn ký bằng khóa debug (P2-16 chưa làm). Khóa tiếp tục chỉ tồn tại lúc chạy trong Keystore/Keychain; test dùng khóa ngẫu nhiên sinh trong lúc chạy.

## Những phần cần thiết bị thật

1. P1-7: nhận ảnh/video lớn trên Android 10, 13, 14, 15 — kiểm tra ảnh xuất hiện trong Thư viện đúng một bản, không có tệp `.pending-*` sót lại, log không có `media_sink_fallback`; nhận khi máy gần đầy bộ nhớ.
2. P1-8: quét QR trên iPhone (Apple Vision) và Android; phép so sánh với ứng viên ZXing; đo lưu lượng mạng của app.
3. P1-10: đang chuyển thì vuốt tắt app, mở lại, ghép đôi lại → phải tiếp tục từ checkpoint; khởi động lại máy rồi làm lại; cài lại app ở một bên → phải chuyển lại từ đầu.
4. P2-18: thời gian đọc lại trên điện thoại với video vài GB trước khi cân nhắc bật mặc định.
5. Giao diện mới và icon trên màn hình thật.
