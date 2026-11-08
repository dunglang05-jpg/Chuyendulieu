# Bắt đầu với Claude Code

Mở thư mục dự án này trong Claude Code và gửi nguyên văn:

> Hãy đọc `CLAUDE.md`, `README.md`, `START_HERE_VI.md`, toàn bộ thư mục `docs/`, `contracts/`, `research/` và `prompts/MASTER_PROMPT_CLAUDE_CODE.md`.  
> Trước khi code, hãy kiểm tra repository hiện tại, môi trường Flutter/Android/iOS, các SDK và thiết bị/simulator khả dụng. Báo cáo những gì đã có, còn thiếu, rủi ro và kế hoạch theo milestone.  
> Không được chỉ làm Android. Kiến trúc phải hỗ trợ đủ bốn chiều Android→Android, Android→iPhone, iPhone→Android, iPhone→iPhone. Hãy triển khai tuần tự theo tài liệu, nhưng giữ đủ bốn chiều trong thiết kế, capability model, protocol và test plan.  
> Bắt đầu bằng thiết kế protocol/capability chung và POC Android↔Android để kiểm chứng engine; tiếp theo triển khai POC Android↔iPhone sớm nhất có thể, sau đó iPhone↔Android và iPhone↔iPhone. Không được đánh dấu một chiều là supported nếu chưa build và kiểm thử trên thiết bị thật.  
> Không tự ý xóa/ghi đè dữ liệu hoặc file hiện có. Không tuyên bố build/test/benchmark thành công nếu chưa chạy và có log.

## Khi Claude hỏi về ưu tiên
Ưu tiên:
1. Giao thức chung và capability negotiation.
2. POC Android↔Android để kiểm chứng transport engine.
3. Android↔iPhone là milestone liên nền tảng bắt buộc tiếp theo.
4. iPhone↔Android.
5. iPhone↔iPhone.
6. Hoàn thiện UX, phục hồi, báo cáo, tối ưu và compatibility.

## Quan trọng
Để build iOS cần macOS, Xcode, Apple toolchain và thiết bị/simulator phù hợp. Nếu môi trường hiện tại không có, Claude phải tạo phần Swift/iOS code và checklist, nhưng ghi rõ chưa thể build/test iOS. Không được giả vờ đã kiểm thử.
