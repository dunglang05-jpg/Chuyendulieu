/// Audit P1-10: where unfinished transfers are remembered across app restarts and reboots.
///
/// The 32-byte key goes to the platform vault (Android Keystore-sealed / iOS Keychain); the record JSON (no key)
/// goes to the app's files with an HMAC made with that key. A record whose key is gone, whose MAC fails, that cannot
/// be parsed, or that is older than 24 h is deleted on load: it is never continued.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/protocol/codec.dart';
import '../core/session/continuation.dart';

/// Platform secret storage; the app passes PtpPlatform.vault*, tests pass a map.
abstract class SecureVault {
  Future<void> put(String name, Uint8List secret);
  Future<Uint8List?> get(String name);
  Future<void> delete(String name);
}

class ContinuationRepo {
  ContinuationRepo(this.dir, this.vault, {this.onEvent});
  final String dir;
  final SecureVault vault;
  final void Function(String event, Map<String, Object?> fields)? onEvent;

  static String _vaultName(String id) => 'cont_${id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';
  File _file(String id) => File(p.join(dir, '${_vaultName(id)}.json'));

  Future<List<ContinuationRecord>> loadAll({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final d = Directory(dir);
    if (!await d.exists()) return [];
    final out = <ContinuationRecord>[];
    await for (final f in d.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      String? id;
      try {
        final doc = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final body = (doc['body'] as Map).cast<String, Object?>();
        id = body['id'] as String;
        final key = await vault.get(_vaultName(id));
        if (key == null || key.length != 32) throw const FormatException('no key');
        if (!checkMacJson(key, body, doc['mac'])) throw const FormatException('mac');
        final r = ContinuationRecord.fromJson(body, key);
        if (r.expired(at)) {
          await delete(r.id);
          onEvent?.call('continuation_dropped', {'reason': 'expired'});
          continue;
        }
        out.add(r);
      } catch (e) {
        onEvent?.call('continuation_dropped', {'reason': e is FormatException ? e.message : 'corrupt'});
        try {
          await f.delete();
          if (id != null) await vault.delete(_vaultName(id));
        } catch (_) {}
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<void> save(ContinuationRecord r) async {
    await Directory(dir).create(recursive: true);
    await vault.put(_vaultName(r.id), r.key);
    final body = r.toJson();
    final f = _file(r.id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'body': body, 'mac': macJson(r.key, body)}), flush: true);
    await tmp.rename(f.path);
  }

  Future<void> delete(String id) async {
    try {
      final f = _file(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    try {
      await vault.delete(_vaultName(id));
    } catch (_) {}
  }

  /// Wire form handed to the worker isolate (includes the key; never logged, never written as is).
  static Map<String, Object?> toWorker(ContinuationRecord r) => {...r.toJson(), 'key': b64u(r.key)};
}
