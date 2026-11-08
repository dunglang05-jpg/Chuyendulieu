/// Localization-ready strings (FR-13). Vietnamese is the default; English kept in sync.
library;

class S {
  static String lang = 'vi';

  static String t(String key, [Map<String, Object> args = const {}]) {
    var s = (_s[key]?[lang]) ?? (_s[key]?['en']) ?? key;
    args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
    return s;
  }

  static const Map<String, Map<String, String>> _s = {
    'app_title': {'vi': 'Phone Transfer Pro', 'en': 'Phone Transfer Pro'},
    'send': {'vi': 'Gửi dữ liệu', 'en': 'Send data'},
    'send_sub': {'vi': 'Máy này là máy cũ', 'en': 'This is the old phone'},
    'receive': {'vi': 'Nhận dữ liệu', 'en': 'Receive data'},
    'receive_sub': {'vi': 'Máy này là máy mới', 'en': 'This is the new phone'},
    'what_moves': {'vi': 'Dữ liệu nào chuyển được?', 'en': 'What can be transferred?'},
    'history': {'vi': 'Lịch sử chuyển', 'en': 'Transfer history'},
    'same_wifi': {
      'vi': 'Kết nối hai máy vào cùng một mạng Wi-Fi, hoặc bật điểm phát (hotspot) trên một máy và cho máy kia kết nối vào. Không cần Internet.',
      'en': 'Put both phones on the same Wi-Fi, or turn on a hotspot on one phone and join it from the other. No Internet needed.'
    },
    'show_qr': {'vi': 'Hiện mã QR trên máy này', 'en': 'Show QR on this phone'},
    'scan_qr': {'vi': 'Quét mã QR của máy kia', 'en': 'Scan the other phone\'s QR'},
    'qr_hint': {'vi': 'Dùng Phone Transfer Pro trên máy kia để quét mã này.', 'en': 'Scan this with Phone Transfer Pro on the other phone.'},
    'qr_expires': {'vi': 'Mã hết hạn sau {s} giây', 'en': 'Code expires in {s}s'},
    'qr_new': {'vi': 'Tạo mã mới', 'en': 'New code'},
    'no_wifi_ip': {
      'vi': 'Không tìm thấy địa chỉ Wi-Fi/hotspot. Hãy bật Wi-Fi hoặc điểm phát.',
      'en': 'No Wi-Fi/hotspot address found. Turn on Wi-Fi or a hotspot.'
    },
    'confirm_title': {'vi': 'Xác nhận thiết bị', 'en': 'Confirm device'},
    'confirm_body': {
      'vi': 'Kết nối với "{name}" ({platform}).\nChỉ đồng ý nếu mã dưới đây giống hệt mã trên máy kia:',
      'en': 'Connect to "{name}" ({platform}).\nAccept only if this code matches the other phone exactly:'
    },
    'accept': {'vi': 'Đồng ý', 'en': 'Accept'},
    'reject': {'vi': 'Từ chối', 'en': 'Reject'},
    'choose_data': {'vi': 'Chọn dữ liệu cần chuyển', 'en': 'Choose what to transfer'},
    'pick_files': {'vi': 'Chọn tệp…', 'en': 'Choose files…'},
    'not_in_plan': {'vi': 'Máy nhận không hỗ trợ nhóm này', 'en': 'Not supported by the receiving phone'},
    'grant': {'vi': 'Cấp quyền', 'en': 'Allow access'},
    'open_settings': {'vi': 'Mở Cài đặt', 'en': 'Open Settings'},
    'perm_denied': {
      'vi': 'Chưa có quyền. Bạn có thể cấp quyền trong Cài đặt; các nhóm khác vẫn chuyển được.',
      'en': 'Access not granted. You can allow it in Settings; other categories still work.'
    },
    'perm_limited': {'vi': 'Chỉ truy cập các mục bạn đã chọn', 'en': 'Only the items you selected'},
    'items': {'vi': '{n} mục', 'en': '{n} items'},
    'start': {'vi': 'Bắt đầu chuyển', 'en': 'Start transfer'},
    'waiting_sender': {'vi': 'Đang chờ máy gửi chọn dữ liệu…', 'en': 'Waiting for the sender to choose data…'},
    'approve_title': {'vi': 'Nhận dữ liệu?', 'en': 'Receive data?'},
    'approve_body': {'vi': '{n} tệp, cần {size} dung lượng trống.', 'en': '{n} files, needs {size} free space.'},
    'preparing': {'vi': 'Đang chuẩn bị…', 'en': 'Preparing…'},
    'transferring': {'vi': 'Đang chuyển', 'en': 'Transferring'},
    'speed': {'vi': '{mbps} MB/s (đo thực tế)', 'en': '{mbps} MB/s (measured)'},
    'keep_open_ios': {
      'vi': 'Giữ ứng dụng mở trên iPhone trong khi chuyển. iOS sẽ tạm dừng ứng dụng nếu bạn chuyển sang ứng dụng khác.',
      'en': 'Keep the app open on the iPhone. iOS suspends apps in the background.'
    },
    'pause': {'vi': 'Tạm dừng', 'en': 'Pause'},
    'resume': {'vi': 'Tiếp tục', 'en': 'Resume'},
    'cancel': {'vi': 'Hủy', 'en': 'Cancel'},
    'reconnecting': {'vi': 'Mất kết nối — đang kết nối lại…', 'en': 'Connection lost — reconnecting…'},
    'reconnect': {'vi': 'Kết nối lại', 'en': 'Reconnect'},
    'thermal_pause': {'vi': 'Máy đang nóng — tạm dừng để hạ nhiệt.', 'en': 'Phone is hot — paused to cool down.'},
    'battery_low': {'vi': 'Pin yếu — hãy cắm sạc.', 'en': 'Battery low — please plug in.'},
    'importing': {'vi': 'Đang lưu vào Ảnh/Danh bạ/Tệp…', 'en': 'Saving to Photos/Contacts/Files…'},
    'done_ok': {'vi': 'Hoàn tất', 'en': 'Completed'},
    'done_partial': {'vi': 'Hoàn tất một phần', 'en': 'Partially completed'},
    'done_failed': {'vi': 'Không thành công', 'en': 'Failed'},
    'done_cancelled': {'vi': 'Đã hủy', 'en': 'Cancelled'},
    'report_ok': {'vi': '{n} tệp thành công (đã kiểm tra SHA-256)', 'en': '{n} files OK (SHA-256 verified)'},
    'report_failed': {'vi': '{n} tệp lỗi', 'en': '{n} files failed'},
    'report_skipped': {'vi': '{n} tệp bỏ qua (máy nhận không hỗ trợ)', 'en': '{n} files skipped (unsupported on receiver)'},
    'report_action': {'vi': '{n} mục cần bạn thao tác', 'en': '{n} items need your action'},
    'delete_partial': {'vi': 'Xóa dữ liệu tạm', 'en': 'Delete partial data'},
    'finish': {'vi': 'Xong', 'en': 'Done'},
    'not_transferable': {'vi': 'Không chuyển được bằng ứng dụng này', 'en': 'Not transferable by this app'},
    'official_flows': {'vi': 'Ứng dụng nhắn tin — dùng cách chính thức', 'en': 'Messaging apps — use official methods'},
    'err_qr_expired': {'vi': 'Mã QR đã hết hạn. Tạo mã mới và quét lại.', 'en': 'QR expired. Create a new one and scan again.'},
    'err_connect': {
      'vi': 'Không kết nối được. Kiểm tra hai máy cùng Wi-Fi/hotspot (và quyền Mạng cục bộ trên iPhone).',
      'en': 'Could not connect. Check both phones are on the same Wi-Fi/hotspot (and Local Network permission on iPhone).'
    },
    'err_auth': {'vi': 'Không xác thực được thiết bị. Hãy quét lại mã QR trực tiếp từ máy kia.', 'en': 'Device could not be verified. Scan the QR directly from the other phone again.'},
    'err_code_rejected': {'vi': 'Kết nối bị từ chối.', 'en': 'Pairing was rejected.'},
    'err_version': {'vi': 'Phiên bản ứng dụng hai máy không tương thích. Hãy cập nhật cả hai.', 'en': 'App versions are incompatible. Update both.'},
    'err_peer_timeout': {'vi': 'Máy kia không phản hồi.', 'en': 'The other phone is not responding.'},
    'err_permission': {'vi': 'Thiếu quyền truy cập.', 'en': 'Permission missing.'},
    'err_storage': {'vi': 'Máy nhận không đủ dung lượng trống.', 'en': 'Not enough free space on the receiving phone.'},
    'err_network': {'vi': 'Mất kết nối mạng.', 'en': 'Network connection lost.'},
    'err_hash': {'vi': 'Dữ liệu không khớp mã kiểm tra.', 'en': 'Data failed the integrity check.'},
    'err_resume_expired': {'vi': 'Phiên đã hết hạn, hãy bắt đầu lại.', 'en': 'Session expired; please start again.'},
    'err_cancelled': {'vi': 'Đã hủy.', 'en': 'Cancelled.'},
    'err_internal': {'vi': 'Lỗi không mong muốn.', 'en': 'Unexpected error.'},
  };
}
