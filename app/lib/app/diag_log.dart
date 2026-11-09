/// Diagnostic event log for device testing. Privacy by construction: only whitelisted keys and short
/// "token-like" values are kept, so file names, contact data, device names, IPs and keys cannot be logged
/// even by mistake. Users export it explicitly ("Xuất log") to share test evidence.
library;

import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

class DiagLog {
  DiagLog._();
  static final DiagLog instance = DiagLog._();

  /// Keys that may appear in the log. Anything else is dropped.
  static const Set<String> allowedKeys = {
    'state', 'from', 'to', 'code', 'role', 'peerPlatform', 'platform', 'os', 'model', 'category', 'perm',
    'status', 'bytes', 'files', 'ok', 'failed', 'skipped', 'ms', 'mbps', 'batch', 'batches', 'attempt',
    'thermal', 'battery', 'charging', 'count', 'resumed', 'more', 'needed', 'free', 'endpoints', 'version',
    'reason', 'wifiMbps', 'cableMbps',
    't_read', 't_hash', 't_wait', 't_send', 't_net', 't_write', 't_sync', 't_open', 't_commit',
  };

  /// Values: numbers/bools, or ≤ 48 chars of letters, digits, space and `._:-+()`. Rejects '/', '@', '\',
  /// so paths, e-mails and URIs never pass.
  static final RegExp _safe = RegExp(r'^[A-Za-z0-9 ._:\-+()]{0,48}$');

  static const int _maxMemory = 2000;
  final Queue<String> _lines = Queue();
  IOSink? _sink;
  String? _path;
  final Stopwatch _clock = Stopwatch()..start();

  /// Opens (and rotates at 1 MiB) `<dir>/diag.log`. Safe to call more than once.
  Future<void> open(String dir) async {
    if (_sink != null) return;
    final f = File(p.join(dir, 'diag.log'));
    try {
      if (await f.exists() && await f.length() > 1024 * 1024) {
        await f.rename(p.join(dir, 'diag.1.log'));
      }
      _sink = File(f.path).openWrite(mode: FileMode.append);
      _path = f.path;
    } catch (_) {
      _sink = null; // logging must never break a transfer
    }
  }

  static final RegExp _ipv4 = RegExp(r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}');

  static Object? sanitize(Object? v) {
    if (v == null || v is num || v is bool) return v;
    final s = v is Enum ? v.name : '$v';
    return _safe.hasMatch(s) && !_ipv4.hasMatch(s) ? s : '<redacted>';
  }

  static String format(String event, Map<String, Object?> fields, {DateTime? at}) {
    final ev = _safe.hasMatch(event) ? event : '<redacted>';
    final b = StringBuffer('${(at ?? DateTime.now()).toUtc().toIso8601String()} $ev');
    for (final e in fields.entries) {
      if (!allowedKeys.contains(e.key)) continue;
      b.write(' ${e.key}=${sanitize(e.value)}');
    }
    return b.toString();
  }

  void event(String event, [Map<String, Object?> fields = const {}]) {
    final line = format(event, {...fields, 'ms': _clock.elapsedMilliseconds});
    _lines.add(line);
    while (_lines.length > _maxMemory) {
      _lines.removeFirst();
    }
    _sink?.writeln(line);
  }

  List<String> get recent => List.unmodifiable(_lines);

  /// Flushes and returns a copy of the log file suitable for handing to the platform "save to Files/Downloads".
  Future<String?> snapshot() async {
    if (_path == null) return null;
    await _sink?.flush();
    final out = '${_path!}.export.txt';
    await File(_path!).copy(out);
    return out;
  }
}
