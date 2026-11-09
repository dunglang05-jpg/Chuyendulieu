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
    'app_title': {'vi': 'Chuyển dữ liệu', 'en': 'Chuyển dữ liệu'},
    'send': {'vi': 'Gửi dữ liệu', 'en': 'Send data'},
    'apps_title': {'vi': 'Chuyển ứng dụng', 'en': 'Move apps'},
    'apps_tile': {'vi': 'Chuyển ứng dụng', 'en': 'Move apps'},
    'apps_tile_sub': {'vi': 'Bằng công cụ chính thức của Google / Apple', 'en': 'With Google\'s / Apple\'s official tool'},
    'apps_why': {
      'vi': 'Chỉ ứng dụng hệ thống của hãng (như Smart Switch) mới tự cài app không cần hỏi. Cách chính thức và tự động nhất là công cụ của Google/Apple lúc thiết lập máy mới — hướng dẫn bên dưới. Sau đó dùng Chuyển dữ liệu cho tài liệu và phần còn lại.',
      'en': 'Only the phone maker\'s system apps (like Smart Switch) can install apps without asking. The official, automatic way is Google\'s / Apple\'s tool during the new phone\'s setup — steps below. Then use Chuyển dữ liệu for documents and the rest.'
    },
    'apps_moves': {'vi': 'Chuyển được', 'en': 'Moves'},
    'apps_not_moves': {'vi': 'Không chuyển được', 'en': 'Does not move'},
    'apps_after_setup': {
      'vi': 'Máy mới đã thiết lập xong rồi? Các công cụ này thường chỉ chạy lúc thiết lập ban đầu (một số máy cho phép trong vài ngày đầu). Nếu không, phải khôi phục cài đặt gốc máy mới — hãy sao lưu trước — hoặc cài lại từng app từ CH Play / App Store.',
      'en': 'Already set up the new phone? These tools usually run only during first setup (some phones allow it for a few days). Otherwise the new phone must be reset — back it up first — or reinstall apps one by one from the store.'
    },
    'bg_restricted': {
      'vi': 'Ứng dụng chưa được phép chạy nền không giới hạn: khi tắt màn hình, máy có thể ngắt kết nối. Hãy cho phép, và trên Xiaomi/OPPO/vivo/Realme bật thêm "Tự khởi chạy" / "Cho phép chạy nền" cho Chuyển dữ liệu.',
      'en': 'The app is not allowed to run unrestricted in the background: with the screen off the phone may drop the connection. Allow it, and on Xiaomi/OPPO/vivo/Realme also enable "Autostart" / "Allow background activity".'
    },
    'bg_open_settings': {'vi': 'Mở cài đặt pin', 'en': 'Open battery settings'},
    'history_empty': {'vi': 'Chưa có lần chuyển nào', 'en': 'No transfers yet'},
    'cont_banner_title': {'vi': 'Có lần chuyển chưa xong', 'en': 'An unfinished transfer'},
    'cont_banner_body': {
      'vi': '{role} với {name}, bắt đầu lúc {time}. Mở lại {action}, ghép đôi với đúng máy đó và xác nhận mã 6 số: hai máy sẽ tự kiểm tra và chuyển tiếp phần còn lại. Giữ được 24 giờ.',
      'en': '{role} with {name}, started at {time}. Open {action} again, pair with the same phone and confirm the 6-digit code: both phones check and continue the rest. Kept for 24 hours.'
    },
    'cont_role_sender': {'vi': 'Gửi', 'en': 'Sending'},
    'cont_role_receiver': {'vi': 'Nhận', 'en': 'Receiving'},
    'cont_resumed': {'vi': 'Đang tiếp tục lần chuyển trước (hai máy đã xác minh).', 'en': 'Continuing the earlier transfer (verified by both phones).'},
    'home_question': {'vi': 'Bạn muốn làm gì\ntrên máy này?', 'en': 'What do you want\nto do on this phone?'},
    'home_sub': {'vi': 'Chuyển trực tiếp giữa hai điện thoại.', 'en': 'Direct transfer between two phones.'},
    'home_footer': {'vi': 'Mã hóa TLS · Xác thực bằng mã QR', 'en': 'TLS encryption · QR authentication'},
    'step_connect': {'vi': 'Bước 1 / 4 · Kết nối', 'en': 'Step 1 / 4 · Connect'},
    'step_confirm': {'vi': 'Bước 2 / 4 · Chống kết nối nhầm', 'en': 'Step 2 / 4 · Avoid the wrong phone'},
    'step_select': {'vi': 'Bước 3 / 4 · Gửi tới {name}', 'en': 'Step 3 / 4 · Sending to {name}'},
    'step_transfer': {'vi': 'Bước 4 / 4 · Giữ hai máy gần nhau', 'en': 'Step 4 / 4 · Keep the phones close'},
    'confirm_code': {'vi': 'MÃ XÁC NHẬN', 'en': 'CONFIRMATION CODE'},
    'confirm_warn': {'vi': 'Nếu mã khác nhau, có thể bạn đang kết nối nhầm máy. Hãy từ chối.', 'en': 'If the codes differ you may be connecting to the wrong phone. Reject.'},
    'accept_same': {'vi': 'Mã giống nhau — Đồng ý', 'en': 'Codes match — Accept'},
    'reject_diff': {'vi': 'Không khớp — Từ chối', 'en': 'No match — Reject'},
    'remaining': {'vi': 'Còn khoảng', 'en': 'About'},
    'speed_label': {'vi': 'Tốc độ đo được', 'en': 'Measured speed'},
    'now_sending': {'vi': 'Đang gửi: {name}', 'en': 'Sending: {name}'},
    'stat_ok': {'vi': 'Thành công', 'en': 'Succeeded'},
    'stat_failed': {'vi': 'Lỗi', 'en': 'Failed'},
    'stat_skipped': {'vi': 'Bỏ qua', 'en': 'Skipped'},
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
    'qr_hint': {'vi': 'Dùng ứng dụng Chuyển dữ liệu trên máy kia để quét mã này.', 'en': 'Scan this with Chuyển dữ liệu on the other phone.'},
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
    'transport_wifi': {'vi': 'Wi-Fi / mạng', 'en': 'Wi-Fi / LAN'},
    'transport_usb': {'vi': 'Chỉ cáp', 'en': 'Cable only'},
    'transport_auto': {'vi': 'Tự động', 'en': 'Auto'},
    'auto_hint': {
      'vi': 'Thử nghiệm, chỉ Android ↔ Android. Bắt đầu bằng Wi-Fi. Nếu bạn cắm cáp USB-C trong lúc chuyển, ứng dụng thử chuyển sang cáp, đo tốc độ thật và chỉ giữ cáp nếu cáp nhanh hơn. Rút cáp thì tự quay lại Wi-Fi. Lần đầu cắm cáp, hãy bấm Cho phép trên màn hình.',
      'en': 'Experimental, Android ↔ Android only. Starts on Wi-Fi. If you plug in a USB-C cable during the transfer, the app tries the cable, measures the real speed and keeps it only if it is faster. Unplugging returns to Wi-Fi. Tap Allow the first time you plug in.'
    },
    'path_on_wifi': {'vi': 'Đang truyền qua Wi-Fi', 'en': 'Transferring over Wi-Fi'},
    'path_on_cable': {'vi': 'Đang truyền qua cáp USB-C', 'en': 'Transferring over the USB-C cable'},
    'path_plug_hint': {'vi': 'Cắm cáp USB-C giữa hai máy để thử truyền qua cáp.', 'en': 'Plug a USB-C cable between the phones to try the cable.'},
    'path_moving_cable': {'vi': 'Đã phát hiện cáp — đang chuyển sang cáp…', 'en': 'Cable detected — moving to the cable…'},
    'path_moving_wifi': {'vi': 'Đang quay lại Wi-Fi…', 'en': 'Moving back to Wi-Fi…'},
    'path_cable_slower': {
      'vi': 'Cáp đo được {cable} MB/s, chậm hơn Wi-Fi ({wifi} MB/s), nên tiếp tục dùng Wi-Fi.',
      'en': 'The cable measured {cable} MB/s, slower than Wi-Fi ({wifi} MB/s), so Wi-Fi is kept.'
    },
    'path_cable_nodata': {
      'vi': 'Cáp không truyền được dữ liệu (kết nối qua cáp chưa thành công) — tiếp tục dùng Wi-Fi. Rút ra cắm lại cáp để thử lại.',
      'en': 'The cable carried no data (the cable link did not come up) — staying on Wi-Fi. Replug to try again.'
    },
    'reconnecting_auto': {
      'vi': 'Đang kết nối lại — có thể do đang đổi giữa Wi-Fi và cáp…',
      'en': 'Reconnecting — possibly switching between Wi-Fi and the cable…'
    },
    'path_cable_lost': {'vi': 'Đã rút cáp — tiếp tục qua Wi-Fi.', 'en': 'Cable unplugged — continuing over Wi-Fi.'},
    'usb_hint': {
      'vi': 'Chỉ Android ↔ Android. Nối hai máy bằng cáp USB-C có truyền dữ liệu, mở khóa cả hai máy, mở ứng dụng ở cả hai và chọn Chỉ cáp. Vẫn cần quét mã QR để xác thực. Ở chế độ này ứng dụng không dùng Wi-Fi.',
      'en': 'Android ↔ Android only. Connect with a USB-C data cable, unlock both phones, open the app on both and choose Cable only. The QR scan is still required. Wi-Fi is not used in this mode.'
    },
    'usb_ios_unsupported': {
      'vi': 'iPhone không cho ứng dụng dùng cổng USB để truyền dữ liệu, nên chỉ có chế độ Wi-Fi.',
      'en': 'iPhone does not let apps use the USB port for data, so only Wi-Fi is available.'
    },
    'usb_state_idle': {'vi': 'Chưa kết nối cáp', 'en': 'Cable not connected'},
    'usb_state_waiting': {'vi': 'Đang chờ cáp USB-C…', 'en': 'Waiting for the USB-C cable…'},
    'usb_state_permission': {'vi': 'Hãy cho phép truy cập USB trên màn hình', 'en': 'Allow USB access on screen'},
    'usb_state_switching': {'vi': 'Đang chuyển máy kia sang chế độ phụ kiện…', 'en': 'Switching the other phone to accessory mode…'},
    'usb_state_connected': {'vi': 'Đã kết nối qua cáp', 'en': 'Connected by cable'},
    'usb_state_failed': {'vi': 'Kết nối cáp thất bại', 'en': 'Cable connection failed'},
    'usb_state_stopped': {'vi': 'Đã dừng kết nối cáp', 'en': 'Cable connection stopped'},
    'usb_role_host': {'vi': 'Máy này điều khiển USB', 'en': 'This phone controls USB'},
    'usb_role_accessory': {'vi': 'Máy kia điều khiển USB', 'en': 'The other phone controls USB'},
    'usb_err_USB_NOT_SUPPORTED': {'vi': 'Máy này không hỗ trợ USB host/accessory. Hãy dùng Wi-Fi.', 'en': 'This phone has no USB host/accessory support. Use Wi-Fi.'},
    'usb_err_IOS_NO_USB_API': {'vi': 'iPhone không hỗ trợ truyền qua cáp cho ứng dụng. Hãy dùng Wi-Fi.', 'en': 'iPhone does not support cable transfer for apps. Use Wi-Fi.'},
    'usb_err_USB_TIMEOUT': {
      'vi': 'Không thấy máy kia qua cáp. Kiểm tra: cáp có truyền dữ liệu (không phải cáp chỉ sạc), cả hai máy đã mở khóa, mục "USB do … điều khiển" trong thông báo USB.',
      'en': 'Other phone not found over the cable. Check: data cable (not charge-only), both phones unlocked, the "USB controlled by" setting.'
    },
    'usb_err_USB_PERMISSION_DENIED': {'vi': 'Quyền USB bị từ chối. Cắm lại cáp và chọn Cho phép.', 'en': 'USB permission denied. Replug and tap Allow.'},
    'usb_err_UNKNOWN_ACCESSORY': {'vi': 'Thiết bị cắm vào không phải ứng dụng Chuyển dữ liệu.', 'en': 'The connected device is not the Chuyển dữ liệu app.'},
    'usb_err_PEER_TIMEOUT': {'vi': 'Máy kia chưa mở ứng dụng ở chế độ Cáp USB-C.', 'en': 'The other phone is not in USB-C cable mode.'},
    'usb_err_PROTOCOL_VERSION_MISMATCH': {'vi': 'Hai máy dùng phiên bản ứng dụng khác nhau.', 'en': 'The two phones run different app versions.'},
    'usb_err_LINK_LOST': {'vi': 'Mất kết nối cáp. Cắm lại để tiếp tục.', 'en': 'Cable link lost. Replug to continue.'},
    'usb_err_generic': {'vi': 'Lỗi cáp USB ({code}).', 'en': 'USB cable error ({code}).'},
    'transport_hotspot': {'vi': 'Điểm phát', 'en': 'Direct'},
    'hotspot_hint': {
      'vi': 'Không cần router: máy hiện mã sẽ tự phát một Wi-Fi riêng, máy quét mã tự vào mạng đó. '
          'Máy hiện mã phải là Android. Thử nghiệm — chưa kiểm tra trên máy thật.',
      'en': 'No router needed: the phone showing the code creates its own Wi-Fi and the scanning phone joins it. '
          'The phone showing the code must be Android. Experimental — not yet tested on real phones.'
    },
    'hotspot_qr_note': {
      'vi': 'Đang phát Wi-Fi riêng cho lần chuyển này. Máy kia sẽ hỏi “kết nối với thiết bị này?” — hãy đồng ý.',
      'en': 'Sharing a private Wi-Fi for this transfer. The other phone will ask to connect — accept it.'
    },
    'hotspot_manual_title': {'vi': 'Vào Wi-Fi của máy kia', 'en': 'Join the other phone’s Wi-Fi'},
    'hotspot_manual_body': {
      'vi': 'iPhone chưa tự vào được. Mở Cài đặt › Wi-Fi, chọn mạng dưới đây, nhập mật khẩu, rồi quay lại bấm Tiếp tục.',
      'en': 'The iPhone could not join by itself. Open Settings › Wi-Fi, pick the network below, enter the password, '
          'then come back and tap Continue.'
    },
    'hotspot_network': {'vi': 'Tên mạng', 'en': 'Network'},
    'hotspot_password': {'vi': 'Mật khẩu', 'en': 'Password'},
    'hotspot_continue': {'vi': 'Đã vào mạng, tiếp tục', 'en': 'Joined, continue'},
    'slow_wifi': {
      'vi': 'Wi-Fi của máy này đang kết nối chậm ({mbps} Mbps) nên tốc độ chuyển bị giới hạn. '
          'Hãy lại gần router, tắt/bật Wi-Fi, hoặc dùng chế độ “Điểm phát”.',
      'en': 'This phone’s Wi-Fi link is slow ({mbps} Mbps), which limits the transfer. '
          'Move closer to the router, toggle Wi-Fi, or use “Direct” mode.'
    },
    'hs_err_HOTSPOT_PERMISSION': {
      'vi': 'Cần quyền “Thiết bị lân cận” (hoặc Vị trí trên Android 12 trở xuống) để tạo/vào Wi-Fi trực tiếp.',
      'en': 'The Nearby devices permission (Location on Android 12 and older) is needed for direct Wi-Fi.'
    },
    'hs_err_HOTSPOT_INCOMPATIBLE_MODE': {
      'vi': 'Điểm phát sóng của máy đang bật. Hãy tắt điểm phát sóng trong Cài đặt rồi thử lại.',
      'en': 'The phone’s own hotspot is on. Turn it off in Settings and try again.'
    },
    'hs_err_HOTSPOT_DISALLOWED': {
      'vi': 'Máy này không cho phép ứng dụng tạo điểm phát (chính sách thiết bị). Hãy dùng Wi-Fi thường.',
      'en': 'This phone does not allow apps to create a hotspot (device policy). Use normal Wi-Fi.'
    },
    'hs_err_HOTSPOT_JOIN_FAILED': {
      'vi': 'Không vào được Wi-Fi của máy kia. Hãy để hai máy gần nhau, bấm “Kết nối” khi được hỏi, rồi thử lại.',
      'en': 'Could not join the other phone’s Wi-Fi. Keep the phones close, tap Connect when asked, and retry.'
    },
    'hs_err_HOTSPOT_JOIN_DENIED': {
      'vi': 'Bạn đã từ chối kết nối Wi-Fi của máy kia.',
      'en': 'You declined to join the other phone’s Wi-Fi.'
    },
    'hs_err_HOTSPOT_UNSUPPORTED': {
      'vi': 'Máy này không tạo được điểm phát từ ứng dụng. Hãy để máy Android hiện mã QR.',
      'en': 'This phone cannot create a hotspot from an app. Let the Android phone show the QR code.'
    },
    'hs_err_generic': {'vi': 'Lỗi Wi-Fi trực tiếp ({code}).', 'en': 'Direct Wi-Fi error ({code}).'},
    'export_log': {'vi': 'Xuất log chẩn đoán (không chứa dữ liệu cá nhân)', 'en': 'Export diagnostic log (no personal data)'},
    'log_saved': {'vi': 'Đã lưu log vào: {where}', 'en': 'Log saved to: {where}'},
    'import_denied': {
      'vi': 'Chưa có quyền ghi vào: {cats}. Các tệp này được giữ trong Tệp/Download thay vì Ảnh/Danh bạ.',
      'en': 'No write access to: {cats}. These files were kept in Files/Downloads instead of Photos/Contacts.'
    },
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
