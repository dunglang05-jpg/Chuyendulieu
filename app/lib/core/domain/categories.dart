/// Data Category Registry (master prompt C). Static defaults describe what the platform API allows at best;
/// the runtime value always comes from probing (permissions, OS version) in the platform adapter.
library;

enum SupportStatus {
  supported('supported'),
  permissionRequired('permission_required'), // SupportedWithPermission
  officialFlow('official_flow'), // SupportedViaOfficialFlow
  partial('partial'),
  unsupported('unsupported'),
  oemAuthorized('oem_authorized'); // RequiresOEMOrManagedDevice

  const SupportStatus(this.wire);
  final String wire;
  static SupportStatus fromWire(Object? s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => SupportStatus.unsupported);
}

class PlatformSupport {
  const PlatformSupport(this.export, this.import, this.note);
  final SupportStatus export;
  final SupportStatus import;
  final String note; // Vietnamese, shown before transfer
}

class CategoryInfo {
  const CategoryInfo(this.id, this.titleVi, this.titleEn, this.android, this.ios);
  final String id;
  final String titleVi;
  final String titleEn;
  final PlatformSupport android;
  final PlatformSupport ios;

  PlatformSupport forPlatform(String platform) => platform == 'ios' ? ios : android;
}

/// Transferable categories. Order = display order.
const List<CategoryInfo> categoryRegistry = [
  CategoryInfo(
    'photos', 'Ảnh', 'Photos',
    PlatformSupport(SupportStatus.permissionRequired, SupportStatus.supported,
        'Cần quyền đọc ảnh (Android 14+ có thể chỉ cho phép ảnh được chọn). Ảnh nhận được lưu vào Pictures/PhoneTransferPro.'),
    PlatformSupport(SupportStatus.permissionRequired, SupportStatus.permissionRequired,
        'Cần quyền Ảnh. Ảnh iCloud chưa tải về sẽ được tải trước khi gửi. Live Photo chỉ gửi ảnh tĩnh. Album không được giữ.'),
  ),
  CategoryInfo(
    'videos', 'Video', 'Videos',
    PlatformSupport(SupportStatus.permissionRequired, SupportStatus.supported, 'Lưu vào Movies/PhoneTransferPro.'),
    PlatformSupport(SupportStatus.permissionRequired, SupportStatus.permissionRequired,
        'Định dạng iPhone không phát được sẽ được lưu trong ứng dụng Tệp thay vì Ảnh.'),
  ),
  CategoryInfo(
    'contacts', 'Danh bạ', 'Contacts',
    PlatformSupport(SupportStatus.permissionRequired, SupportStatus.officialFlow,
        'Xuất dạng vCard. Khi nhận, ứng dụng Danh bạ của máy sẽ mở để bạn xác nhận nhập.'),
    PlatformSupport(SupportStatus.permissionRequired, SupportStatus.permissionRequired,
        'Xuất/nhập vCard qua Contacts framework. Ghi chú (notes) của liên hệ không được iOS cho phép xuất.'),
  ),
  CategoryInfo(
    'documents', 'Tài liệu', 'Documents',
    PlatformSupport(SupportStatus.supported, SupportStatus.supported,
        'Chỉ các tệp bạn chọn qua trình chọn tệp. Nhận vào Download/PhoneTransferPro.'),
    PlatformSupport(SupportStatus.supported, SupportStatus.supported,
        'Chỉ các tệp bạn chọn. Nhận vào Tệp > Trên iPhone > Phone Transfer Pro.'),
  ),
  CategoryInfo(
    'audio', 'Âm thanh', 'Audio',
    PlatformSupport(SupportStatus.permissionRequired, SupportStatus.supported, 'Lưu vào Music/PhoneTransferPro.'),
    PlatformSupport(SupportStatus.partial, SupportStatus.partial,
        'iOS không cho ứng dụng khác đọc/ghi thư viện Nhạc. Chỉ gửi tệp bạn chọn; khi nhận, tệp nằm trong ứng dụng Tệp.'),
  ),
  CategoryInfo(
    'files', 'Toàn bộ tệp', 'All files',
    PlatformSupport(SupportStatus.permissionRequired, SupportStatus.supported,
        'Mọi tệp trong bộ nhớ chung (Download, Documents, tệp Zalo/WhatsApp lưu ra ngoài…), trừ ảnh/video/nhạc '
            '(đã có mục riêng). Cần bật “Quyền truy cập vào mọi tệp” (Android 11+). Không đọc được dữ liệu riêng '
            'của ứng dụng. Máy nhận lưu vào Download/PhoneTransferPro/Bộ nhớ. Thử nghiệm, chưa kiểm tra trên máy thật.'),
    PlatformSupport(SupportStatus.unsupported, SupportStatus.supported,
        'iPhone không cho đọc tệp của ứng dụng khác; khi nhận, tệp được lưu vào ứng dụng Tệp.'),
  ),
  CategoryInfo(
    'apps', 'Ứng dụng', 'Apps',
    PlatformSupport(SupportStatus.supported, SupportStatus.officialFlow,
        'Chỉ gửi tệp cài đặt (APK) của ứng dụng bạn đã cài — không có dữ liệu bên trong ứng dụng (tin nhắn, đăng nhập). '
            'Máy nhận hỏi "Cài đặt?" cho từng ứng dụng. Chỉ Android → Android. Thử nghiệm, chưa kiểm tra trên máy thật.'),
    PlatformSupport(SupportStatus.unsupported, SupportStatus.unsupported,
        'iPhone không cho ứng dụng khác cài hoặc xuất ứng dụng; hãy cài lại từ App Store.'),
  ),
  CategoryInfo(
    'calendar', 'Lịch', 'Calendar',
    PlatformSupport(SupportStatus.unsupported, SupportStatus.unsupported, 'Chưa triển khai trong phiên bản này.'),
    PlatformSupport(SupportStatus.unsupported, SupportStatus.unsupported, 'Chưa triển khai trong phiên bản này.'),
  ),
];

/// Shown in the "what can be transferred" screen; never transferred by this app.
const List<(String, String)> notTransferable = [
  ('Tin nhắn SMS/iMessage, nhật ký cuộc gọi',
      'Android chỉ cho ứng dụng SMS mặc định truy cập; iOS không có API cho ứng dụng bên thứ ba.'),
  ('Dữ liệu riêng của ứng dụng khác (Zalo, Messenger, Facebook, WhatsApp, ngân hàng…)',
      'Hệ điều hành cô lập dữ liệu mỗi ứng dụng. Hãy dùng sao lưu/khôi phục hoặc đăng nhập chính thức của từng ứng dụng.'),
  ('Cài ứng dụng im lặng; dữ liệu và đăng nhập bên trong ứng dụng',
      'Android → Android: chỉ chuyển tệp cài đặt và máy nhận hỏi "Cài đặt?" cho từng ứng dụng. Cài im lặng và dữ liệu '
          'riêng của ứng dụng chỉ ứng dụng hệ thống của hãng (Clone Phone, Smart Switch…) mới làm được.'),
  ('Mật khẩu, phiên đăng nhập, OTP, khóa', 'Không bao giờ được trích xuất. Đăng nhập lại trên máy mới.'),
  ('Ghi chú (Notes)', 'Chỉ qua chức năng xuất/chia sẻ của ứng dụng Ghi chú, lưu thành tài liệu rồi chuyển.'),
];

/// App-level migration support levels (master prompt I), shown honestly per app.
const Map<String, String> officialAppFlows = {
  'Zalo': 'L3 — Sao lưu & khôi phục tin nhắn trong Zalo (Cài đặt > Sao lưu và đồng bộ tin nhắn).',
  'WhatsApp': 'L4 — Android→iPhone dùng "Move to iOS"; iPhone→Android dùng công cụ chuyển của WhatsApp/nhà sản xuất; cùng nền tảng dùng Google Drive/iCloud backup.',
  'Messenger / Facebook': 'L3 — Đăng nhập lại; tin nhắn đồng bộ từ máy chủ (tin nhắn mã hóa đầu-cuối cần mã PIN khôi phục).',
};
