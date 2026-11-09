/// Platform adapter API. One MethodChannel, same contract on Android (Kotlin) and iOS (Swift).
/// Content bytes never cross the channel: native code hands Dart a readable/writable file path.
library;

import 'package:flutter/services.dart';

class ProbeResult {
  ProbeResult(this.raw);
  final Map<String, Object?> raw;
  String get platform => raw['platform'] as String;
  String get osVersion => raw['osVersion'] as String;
  String get model => raw['model'] as String;
  String get deviceName => raw['deviceName'] as String;
  int? get freeBytes => raw['freeBytes'] as int?;
  String get backgroundConstraints => raw['backgroundConstraints'] as String;

  /// [{id, export, import, status}] — computed from OS version + current permission state.
  List<Map<String, Object?>> get categories =>
      (raw['categories'] as List).map((e) => Map<String, Object?>.from(e as Map)).toList();
  Map<String, String> get permissions => Map<String, String>.from(raw['permissions'] as Map);
}

class SourceItem {
  SourceItem(this.raw);
  final Map<String, Object?> raw;
  String get id => raw['id'] as String; // MediaStore uri / PHAsset localIdentifier / staged path
  String get name => raw['name'] as String;
  String get relPath => raw['relPath'] as String;
  String get category => raw['category'] as String;
  int get sizeHint => (raw['size'] as int?) ?? 0; // display only; exact size comes from openForRead
  String? get mime => raw['mime'] as String?;
}

class OpenedItem {
  OpenedItem(this.raw);
  final Map<String, Object?> raw;
  String get path => raw['path'] as String; // Android: /proc/self/fd/N ; iOS: staged file
  int get size => raw['size'] as int;
  int? get mtimeMs => raw['mtimeMs'] as int?;
  String get token => raw['token'] as String; // pass to closeRead
}

/// imported | saved_to_files | requires_user_action | failed
class ImportResult {
  ImportResult(this.raw);
  final Map<String, Object?> raw;
  String get status => raw['status'] as String;
  String? get location => raw['location'] as String?;
  String? get message => raw['message'] as String?;
}

class PtpPlatform {
  static const MethodChannel _ch = MethodChannel('com.phonetransferpro/ptp_platform');

  static Future<T> _call<T>(String method, [Map<String, Object?>? args]) async {
    final r = await _ch.invokeMethod<Object?>(method, args);
    return r as T;
  }

  static Future<ProbeResult> probe() async => ProbeResult(Map<String, Object?>.from(await _call<Map>('probe')));

  /// Returns granted | limited | denied. Asked in context, one category at a time.
  static Future<String> requestPermission(String category, {required bool forImport}) =>
      _call<String>('requestPermission', {'category': category, 'forImport': forImport});

  static Future<List<SourceItem>> scan(String category, {int limit = 100000}) async {
    final list = await _call<List>('scan', {'category': category, 'limit': limit});
    return list.map((e) => SourceItem(Map<String, Object?>.from(e as Map))).toList();
  }

  /// System document picker (SAF / UIDocumentPicker). Only user-chosen files are ever read.
  static Future<List<SourceItem>> pickDocuments({String category = 'documents'}) async {
    final list = await _call<List>('pickDocuments', {'category': category});
    return list.map((e) => SourceItem(Map<String, Object?>.from(e as Map))).toList();
  }

  static Future<OpenedItem> openForRead(SourceItem item) async =>
      OpenedItem(Map<String, Object?>.from(await _call<Map>('openForRead', {'id': item.id, 'category': item.category})));

  static Future<void> closeRead(String token) => _call<void>('closeRead', {'token': token});

  /// App-private inbox directory where verified files land before import.
  static Future<String> inboxDir() => _call<String>('inboxDir');

  static Future<int> freeBytes(String path) async => await _call<int>('freeBytes', {'path': path});

  static Future<ImportResult> importFile(String path, String category, String displayName, String? mime) async =>
      ImportResult(Map<String, Object?>.from(await _call<Map>('importFile',
          {'path': path, 'category': category, 'name': displayName, 'mime': mime})));

  /// Android: foreground service (dataSync) + wake lock. iOS: idle timer off + short background task.
  static Future<void> setTransferActive(bool active) => _call<void>('setTransferActive', {'active': active});

  /// {batteryPct, charging, thermal: nominal|fair|serious|critical|unknown}
  static Future<Map<String, Object?>> deviceState() async =>
      Map<String, Object?>.from(await _call<Map>('deviceState'));

  static Future<void> openAppSettings() => _call<void>('openAppSettings');

  /// USB-C cable link (Android ↔ Android via AOA). iOS always reports supported=false.
  /// {supported, hostSupported, accessorySupported, state: idle|waiting|permission|switching|connected|failed|stopped,
  ///  role: usb_host|usb_accessory|null, error, bridgePort}
  static Future<Map<String, Object?>> usbStatus() async =>
      Map<String, Object?>.from(await _call<Map>('usbStatus'));

  /// mode 'listen' (this app joins: returns bridgePort once connected) or 'connect' (this app hosts on [port]).
  /// [timeoutMs]: how long to wait for a cable (90 s when the user picked cable-only; the whole session in "auto").
  static Future<Map<String, Object?>> usbStart(String mode, {int port = 0, int timeoutMs = 90000}) async =>
      Map<String, Object?>.from(await _call<Map>('usbStart', {'mode': mode, 'port': port, 'timeoutMs': timeoutMs}));

  static Future<void> usbStop() => _call<void>('usbStop');

  /// Android only (audit P1-7): receive straight into a hidden MediaStore item (IS_PENDING=1) so each byte is
  /// written once. Returns {uri, path}; `path` is /proc/self/fd/N of a read+write descriptor kept open natively.
  static Future<Map<String, String>> mediaCreate(String category, String name, String? mime) async =>
      Map<String, String>.from(await _call<Map>('mediaCreate', {'category': category, 'name': name, 'mime': mime}));

  /// Path for an existing pending item (reconnect / restart). Throws if it no longer exists.
  static Future<String> mediaReopen(String uri) async => await _call<String>('mediaReopen', {'uri': uri});

  /// Clears IS_PENDING (item becomes visible); returns a readable location such as "Pictures/PhoneTransferPro/a.jpg".
  static Future<String> mediaPublish(String uri) async => await _call<String>('mediaPublish', {'uri': uri});

  static Future<void> mediaDelete(String uri) => _call<void>('mediaDelete', {'uri': uri});
}
