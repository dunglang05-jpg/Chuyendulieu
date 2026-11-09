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

  /// Android: {ignoringBatteryOptimizations, manufacturer}. iOS always reports true (not applicable).
  static Future<Map<String, Object?>> backgroundStatus() async =>
      Map<String, Object?>.from(await _call<Map>('backgroundStatus'));

  /// Android: shows the system dialog "let the app always run in background?" once. granted | asked | unavailable.
  static Future<String> requestBackground() async => await _call<String>('requestBackground');

  /// Android: battery optimisation list in Settings (fallback: app details).
  static Future<void> openBatterySettings() => _call<void>('openBatterySettings');

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

  /// Audit P1-10: small secrets sealed by Android Keystore (AES-GCM) / iOS Keychain (this device only).
  /// [name]: 1–64 chars of [A-Za-z0-9_-]. [data]: base64.
  static Future<void> vaultPut(String name, String data) => _call<void>('vaultPut', {'name': name, 'data': data});

  /// Base64, or null when absent / no longer decryptable.
  static Future<String?> vaultGet(String name) async => await _call<String?>('vaultGet', {'name': name});

  static Future<void> vaultDelete(String name) => _call<void>('vaultDelete', {'name': name});

  /// "Điểm phát" host (Android only): app-scoped hotspot without Internet sharing.
  /// Wi-Fi Direct group on 5 GHz when this phone supports it (2.4 GHz with [force24]), else a local-only hotspot.
  /// Returns {ssid, psk, sec: wpa2|wpa3, mode: p2p|ap, band: 5|2|a, ips: [host IPv4]}. Also HOTSPOT_WIFI_OFF,
  /// HOTSPOT_BUSY. Throws PlatformException with codes
  /// HOTSPOT_PERMISSION | HOTSPOT_INCOMPATIBLE_MODE | HOTSPOT_DISALLOWED | HOTSPOT_NO_CHANNEL | HOTSPOT_FAILED |
  /// HOTSPOT_UNSUPPORTED (iOS). The name/password must never be logged.
  static Future<Map<String, Object?>> hotspotStart({bool force24 = false}) async =>
      Map<String, Object?>.from(await _call<Map>('hotspotStart', {'force24': force24}));

  static Future<void> hotspotStop() => _call<void>('hotspotStop');

  /// "Điểm phát" joiner: connects to the host's hotspot (system dialog) and routes this app's sockets over it.
  /// Returns the host's gateway IPv4 when known, else ''. Codes: HOTSPOT_JOIN_FAILED | HOTSPOT_JOIN_DENIED |
  /// HOTSPOT_PERMISSION | HOTSPOT_WIFI_OFF | HOTSPOT_NO_5GHZ. [mode]/[band] come from the QR.
  static Future<String> hotspotJoin(String ssid, String psk, String sec,
          {String mode = 'ap', String band = 'a', int timeoutMs = 60000}) async =>
      (await _call<String?>('hotspotJoin',
          {'ssid': ssid, 'psk': psk, 'sec': sec, 'mode': mode, 'band': band, 'timeoutMs': timeoutMs})) ??
      '';

  static Future<void> hotspotLeave() => _call<void>('hotspotLeave');

  /// Link rate of the current router Wi-Fi in Mbps, -1 when unknown (always -1 on iOS).
  static Future<int> wifiLinkMbps() async => (await _call<int?>('wifiLinkMbps')) ?? -1;
}
