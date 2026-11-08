# MASTER PROMPT — PHONE TRANSFER PRO
## Cross-platform direct migration: Android ↔ Android, Android ↔ iPhone, iPhone ↔ Android, iPhone ↔ iPhone

Bạn là Principal Mobile Architect, Senior Flutter Engineer, Senior Android Engineer (Kotlin), Senior iOS Engineer (Swift), Security Engineer và QA Lead. Hãy triển khai sản phẩm theo tiêu chuẩn production, nhưng không được tuyên bố production-ready nếu chưa có bằng chứng build/test thực tế.

# A. Sứ mệnh sản phẩm

Xây dựng Phone Transfer Pro — ứng dụng chuyển dữ liệu trực tiếp giữa hai điện thoại, không cần máy tính trung gian. Hệ thống phải hỗ trợ cả bốn hướng:

1. Android → Android
2. Android → iPhone
3. iPhone → Android
4. iPhone → iPhone

Thiết kế theo mô hình peer-to-peer đối xứng: mỗi thiết bị đều có thể là Sender hoặc Receiver. Không tạo kiến trúc chỉ có Android làm nguồn hoặc chỉ iPhone làm đích.

Không bắt buộc Internet khi truyền nội bộ. Internet chỉ cần khi người dùng chủ động chọn tải ứng dụng, khôi phục từ cloud hoặc dùng dịch vụ bên ngoài.

# B. Trải nghiệm người dùng

Luồng chung:
1. Mở app trên cả hai thiết bị.
2. Chọn "Gửi dữ liệu" hoặc "Nhận dữ liệu".
3. Máy nhận hiển thị QR/session code; máy gửi quét QR (có thể hỗ trợ chiều ngược lại).
4. Hai thiết bị xác nhận tên/loại thiết bị và mã xác thực.
5. Trao đổi protocol version và capability matrix.
6. Máy gửi quét dữ liệu trong phạm vi được phép.
7. Người dùng xem trước, chọn nhóm dữ liệu và dung lượng.
8. Máy nhận xác nhận dung lượng đích và quyền cần thiết.
9. Truyền dữ liệu với tiến trình theo nhóm/file.
10. Xác minh SHA-256, tổng kết thành công/một phần/thất bại.
11. Hỗ trợ tiếp tục phiên truyền nếu kết nối bị gián đoạn.

UX phải giải thích rõ dữ liệu nào có thể chuyển, dữ liệu nào cần thao tác trên hệ điều hành/ứng dụng chính thức, dữ liệu nào không được nền tảng cho phép.

# C. Phạm vi dữ liệu

Thiết kế Data Category Registry có trạng thái per-platform:
- Supported
- SupportedWithPermission
- SupportedViaOfficialFlow
- Partial
- Unsupported
- RequiresOEMOrManagedDevice

Các nhóm cần khảo sát và triển khai trong giới hạn API:
- Danh bạ
- Ảnh và video
- Tệp/tài liệu và thư mục người dùng được cấp quyền
- Âm thanh/nhạc được phép truy cập
- Lịch và nhắc việc nếu API/quyền cho phép
- Ghi chú chỉ qua export/import hoặc API chính thức phù hợp
- Danh sách ứng dụng và deep link cài đặt khi nền tảng cho phép
- Dữ liệu ứng dụng qua backup/restore chính thức hoặc app-specific flow
- WhatsApp/Zalo/Messenger/Facebook: chỉ dùng luồng chính thức; hướng dẫn đăng nhập/backup/restore; không trích xuất session/token/cookie.

Không được ghi "chuyển toàn bộ điện thoại" nếu chưa có bằng chứng. Tên nhóm dữ liệu và mô tả phải phản ánh giới hạn thực tế.

# D. Kiến trúc bắt buộc

## D1. Shared Flutter/Dart
- Presentation/UI
- Migration Orchestrator state machine
- Capability negotiation model
- Transfer session model
- Data category registry
- Transfer queue and progress aggregation
- Error mapping and recovery UX
- Local persistence abstraction

## D2. Android native Kotlin
- Runtime permission handling
- MediaStore, SAF, Contacts Provider, Calendar Provider theo quyền/API
- Android network/discovery adapters
- Storage capacity and destination validation
- App inventory only through permitted package visibility mechanisms
- Native bridge qua Pigeon/MethodChannel hoặc FFI đã chuẩn hóa

## D3. iOS native Swift
- Photos framework với quyền phù hợp
- Contacts framework với quyền phù hợp
- UIDocumentPicker/document access và security-scoped URLs
- EventKit khi được cấp quyền
- Local network permission and networking APIs
- Background execution limitations handling
- Native bridge qua Pigeon/MethodChannel
- Import/export flow qua Files/Photos/Contacts APIs đúng khả năng thực tế

## D4. Transfer Engine
- Streaming file I/O; không load file lớn vào RAM.
- Bounded queues và backpressure.
- Adaptive chunk size và concurrency.
- File manifest, metadata normalization.
- SHA-256 file verification.
- Chunk checkpoints, retry, resume.
- Atomic writes và cleanup.
- Pause/resume/cancel.
- Transfer report.

## D5. Connectivity adapters
Ưu tiên theo thứ tự:
1. LAN TCP/TLS baseline.
2. Google Nearby Connections adapter cho POC Android, đánh giá khả năng tương thích iOS cụ thể trước khi chọn.
3. Wi-Fi Direct/local hotspot adapters theo OS.
4. QUIC/HTTP3 (ví dụ Quinn) chỉ là nhánh benchmark.
5. USB-C/OTG/USB Host/Accessory/MTP nghiên cứu độc lập; không suy luận rằng cắm cáp là app-to-app channel.
6. Hybrid multi-link chỉ khi benchmark chứng minh có lợi và đảm bảo deduplication, ordering, integrity.

Mỗi adapter phải implement cùng interface và capability contract. Có fallback và timeout.

# E. Pairing và bảo mật

QR/session payload chỉ chứa:
- Protocol version
- Random session ID
- Expiry timestamp
- Endpoint/discovery hints cần thiết
- Ephemeral public key/fingerprint
- Non-sensitive feature flags

Không chứa danh bạ, ảnh, tên tệp riêng tư, access token, mật khẩu, OTP hay khóa bí mật.

Bắt buộc:
- QR hết hạn ngắn; chống replay.
- Peer authentication và mutual confirmation.
- Hiển thị tên thiết bị và confirmation code trên cả hai máy.
- TLS 1.3 hoặc thiết kế AEAD đã review.
- Ephemeral key agreement, key rotation theo phiên.
- Rate limiting và giới hạn kích thước manifest.
- Validate path; không cho path traversal.
- Không ghi dữ liệu nhạy cảm vào log.
- Threat model và security tests.

# F. Migration state machine

Định nghĩa state machine:
IDLE → DISCOVERING → PAIRING → AUTHENTICATING → CAPABILITY_EXCHANGE → SCANNING → PREVIEW → PREPARING → TRANSFERRING → VERIFYING → IMPORTING → COMPLETED / PARTIAL / FAILED / CANCELLED.

Mỗi transition cần:
- Preconditions
- Timeout
- Retry policy
- Persisted checkpoint
- User-facing error
- Recovery action

# G. Capability negotiation

Mỗi thiết bị gửi:
- platform + OS version
- app version + protocol version
- available transports
- permission status
- supported categories
- max file size/available storage
- background constraints
- encryption suites

Không gửi PII trong capability exchange. Hai bên tính giao của capabilities để tạo migration plan. Không được giả định capability chỉ từ tên hệ điều hành; cần probe runtime.

# H. Bốn hướng chuyển — acceptance criteria riêng

## H1 Android → Android
- QR pairing hai chiều.
- Danh bạ/media/files theo permission.
- Tệp lớn, nhiều file nhỏ.
- Resume sau ngắt kết nối.
- Storage low, permission denied, cancel, device sleep.
- SHA-256 match.

## H2 Android → iPhone — bắt buộc milestone sớm
- Android Sender và iOS Receiver hoạt động.
- QR/session pairing.
- iOS nhận file vào vùng app hoặc import qua API chính thức.
- Ảnh/video: hỗ trợ luồng import phù hợp với Photos permission/API và UX xác nhận.
- Danh bạ: export vCard hoặc luồng import được iOS hỗ trợ; kiểm thử trùng lặp và encoding.
- Files: import vào app container/Files theo quyền và document picker.
- Không tuyên bố ghi trực tiếp vào private container của app khác.
- Resume, integrity, low-storage, permission-denied tests.
- Build và test trên iPhone thật là release gate.

## H3 iPhone → Android
- iOS Sender truy cập Photos/Contacts/Documents theo permission và user selection.
- Android Receiver lưu vào MediaStore/SAF/Contacts Provider theo permission.
- Giữ metadata trong phạm vi API.
- Resume và integrity.
- Không hứa truy cập toàn bộ filesystem iPhone.

## H4 iPhone → iPhone
- Cả hai phía iOS có Sender/Receiver native adapters.
- Photos, contacts, files theo API/permission.
- Import UX phù hợp với giới hạn iOS.
- Network/local discovery permission.
- Kiểm thử iPhone thật, nhiều phiên bản iOS.

# I. App migration — nói thật về giới hạn

Thiết kế mức hỗ trợ:
- L0: discover app/list metadata
- L1: dẫn tới cài app từ store chính thức
- L2: chuyển public/exported files
- L3: official backup/restore
- L4: app-specific official migration
- L5: OEM documented/licensed API
- L6: system-signed/managed-device privileged capability (chỉ khi có authorization chính thức)

App bên thứ ba không thể tự đọc/ghi tùy ý dữ liệu private của ứng dụng khác. Không sử dụng root/jailbreak/exploit hoặc trích xuất session token. Facebook/Messenger/Zalo/WhatsApp phải dùng backup/restore, đồng bộ và account recovery chính thức. Ghi rõ từng app hỗ trợ ở mức nào.

# J. Hiệu năng

Đo thực tế:
- Throughput MB/s
- Time-to-pair
- Discovery latency
- CPU/RAM
- Battery drain
- Thermal state
- Retry rate
- Resume success rate
- Hash verification time

Test:
- Một file lớn (>= 5 GB nếu thiết bị đủ dung lượng)
- 10,000 file nhỏ
- Ảnh/video mixed
- Wi-Fi yếu/roaming
- Mất mạng giữa phiên
- App background/foreground
- Thiết bị nóng/low battery
- Low storage

Không tự đặt mục tiêu benchmark thành kết quả. Đặt target sau baseline measurement. Không ép concurrency gây crash/OOM.

# K. Repository research / license

Các repository từng được đưa vào shortlist nghiên cứu:
- LocalSend: tham khảo kiến trúc local-network transfer; audit code/dependencies/license trước khi reuse.
- Google Nearby: P2P adapter POC; xác minh platform support và build thực tế.
- Quinn: QUIC benchmark, không mặc định nhanh hơn TCP.
- Seedvault: tham khảo Android backup/system integration; không coi là thư viện app thông thường.
- Neo Backup: không tích hợp nếu yêu cầu license không phù hợp và cần root.
- Snapdrop: không chọn làm dependency nếu license không đáp ứng policy.

Không copy/paste code trước khi:
- Kiểm tra license từng repository và từng dependency.
- Kiểm tra license của file/module được dùng.
- Lưu NOTICE/SBOM.
- Security review và version pinning.
- Chạy build/test độc lập.

# L. Milestones

M0 — Repository/environment audit:
- Inspect project; Flutter, Dart, Android SDK, Xcode availability.
- Build baseline; record exact versions and blockers.

M1 — Domain/protocol foundation:
- Shared capability model, manifest, session, state machine, errors.
- Threat model and protocol tests.
- No platform-specific assumptions.

M2 — Android ↔ Android POC:
- LAN transport baseline, QR pairing, transfer, hash, resume.
- Device tests.

M3 — Android ↔ iPhone POC:
- iOS receiver native adapter; Android sender.
- Contacts vCard, selected photos/videos, documents.
- Import flow and iPhone real-device tests.

M4 — iPhone ↔ Android:
- iOS sender + Android receiver; permission/import tests.

M5 — iPhone ↔ iPhone:
- Native sender/receiver on both iOS devices.

M6 — Additional transports:
- Nearby, Wi-Fi Direct/hotspot, QUIC, USB investigation.
- Compare measured results.

M7 — Hardening:
- Security, compatibility, accessibility, localization, performance, crash recovery.

M8 — Release candidate:
- Full test matrix, signed builds, privacy disclosures, release checklist.

At the end of each milestone, report:
- Files changed
- Implementation summary
- Commands run
- Actual build/test output
- Device/OS tested
- Known limitations
- Next milestone and blockers

# M. First response required before coding

Before editing code, report:
1. Repository structure and current implementation status.
2. Toolchain availability (Flutter/Dart/Android SDK/Xcode).
3. Whether iOS can be built in current environment.
4. Gaps against four-way requirement.
5. Risks, especially iOS APIs, permissions, import UX and app-private data.
6. Proposed milestone plan.
7. Exact commands to validate baseline.

Then wait for approval if destructive changes or major architecture replacement are required. Otherwise proceed with safe, incremental work.

# N. Definition of done

A direction is not "supported" until both endpoints build and pass real-device integration tests for pairing, capability negotiation, representative data categories, large files, interruption/resume, hash verification, cancellation, permission denial, low storage and device loss. Simulator-only testing is not enough for release claims.

Do not call a scaffold, mock, prototype UI, or unbuilt code a completed product.
