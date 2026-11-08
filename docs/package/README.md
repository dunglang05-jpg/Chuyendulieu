# Phone Transfer Pro — Claude Code Project Package

**Phiên bản tài liệu:** 2.0  
**Mục tiêu:** Xây dựng ứng dụng chuyển dữ liệu trực tiếp giữa Android và iPhone theo cả bốn chiều:
- Android → Android
- Android → iPhone
- iPhone → Android
- iPhone → iPhone

Đây là bộ tài liệu triển khai và mã khung định hướng, **không phải ứng dụng hoàn chỉnh hoặc APK/IPA đã build**.

## Bắt đầu nhanh
1. Giải nén toàn bộ ZIP.
2. Mở thư mục `PhoneTransferPro_ClaudeCode_Full_Package_v2` trong Claude Code.
3. Yêu cầu Claude Code đọc `CLAUDE.md`, `START_HERE_VI.md`, rồi đọc toàn bộ `docs/` và `prompts/MASTER_PROMPT_CLAUDE_CODE.md`.
4. Yêu cầu Claude báo cáo môi trường, hiện trạng, rủi ro và kế hoạch trước khi sửa code.
5. Triển khai theo milestone, bắt đầu từ giao thức chung và POC Android ↔ Android, sau đó Android ↔ iPhone. Không được bỏ qua ba chiều còn lại trong kiến trúc.

## Nguyên tắc sản phẩm
- Không cần máy tính trung gian.
- Truyền P2P qua mạng nội bộ; Internet không bắt buộc cho truyền trực tiếp.
- QR pairing hai chiều; thiết bị nào cũng có thể gửi hoặc nhận.
- Không có phân Free/Pro và không cố tình giới hạn tốc độ.
- Ưu tiên độ ổn định, bảo mật, hiệu năng, khả năng tiếp tục sau gián đoạn.
- Tôn trọng giới hạn sandbox/API của Android và iOS; không root, jailbreak, exploit hoặc vượt quyền.
- Không hứa chuyển được dữ liệu riêng của ứng dụng khác nếu nền tảng không cấp API chính thức.

## Cấu trúc
- `CLAUDE.md`: quy tắc bắt buộc cho Claude Code.
- `START_HERE_VI.md`: hướng dẫn giao việc.
- `prompts/MASTER_PROMPT_CLAUDE_CODE.md`: prompt tổng thể.
- `docs/`: đặc tả, kiến trúc, platform matrix, giao thức, bảo mật, QA, roadmap.
- `contracts/`: JSON schema cho capability exchange và transfer manifest.
- `research/`: quyết định nghiên cứu repository, cần audit lại trước khi sao chép mã.
- `starter/`: cấu trúc module mẫu và checklist; không phải app production.
