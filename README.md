# Phone Transfer Pro

Chuyển dữ liệu trực tiếp giữa hai điện thoại qua Wi-Fi/điểm phát nội bộ, không cần máy tính, không cần Internet — thiết kế cho cả bốn chiều **Android→Android, Android→iPhone, iPhone→Android, iPhone→iPhone**.

> **Trạng thái: chưa build, chưa kiểm thử trên điện thoại.** Giao thức đã được kiểm chứng bằng bản tham chiếu Python (45/45 test). Xem [`docs/STATUS.md`](docs/STATUS.md) trước khi dùng bất kỳ phần nào.

## Cấu trúc

| Thư mục | Nội dung |
|---|---|
| `app/` | Ứng dụng Flutter: `lib/core` (giao thức, domain, engine — không phụ thuộc nền tảng), `lib/app` (điều phối), `lib/ui`, `lib/data` (SQLite), `test/` |
| `packages/ptp_platform/` | Adapter nền tảng: Kotlin (`android/`) và Swift (`ios/`), cùng một MethodChannel |
| `tools/reference_peer/` | Bản cài đặt giao thức bằng Python: test tuân thủ, benchmark, CLI làm máy đối tác khi test điện thoại |
| `contracts/` | JSON schema + test vector dùng chung giữa Python và Dart |
| `docs/` | Giao thức, trạng thái, threat model, ma trận test thiết bị, lệnh build/test, báo cáo milestone; `docs/package/` là tài liệu gốc |

## Bắt đầu

```bash
# Kiểm chứng giao thức (chạy được ở mọi máy có Python)
cd tools/reference_peer && pip install cryptography pytest pytest-asyncio pytest-timeout && python3 -m pytest -q

# Ứng dụng (cần Flutter; iOS cần macOS + Xcode)
cd app && ./tool/bootstrap.sh && flutter analyze && flutter test
```

Chi tiết: [`docs/BUILD_AND_TEST.md`](docs/BUILD_AND_TEST.md).

## Nguyên tắc
Không root/jailbreak, không vượt quyền hệ điều hành, không trích xuất dữ liệu riêng của ứng dụng khác hay phiên đăng nhập. Mọi giới hạn được hiển thị cho người dùng trước khi chuyển. Không có kết quả test hay tốc độ nào được ghi nếu chưa đo thật. Quy tắc đầy đủ: [`CLAUDE.md`](CLAUDE.md).
