/// Receiver durable store: partial files, fsync'd checkpoints, atomic commit, capacity check.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../protocol/codec.dart';
import '../protocol/errors.dart';
import '../protocol/manifest.dart';
import '../protocol/paths.dart';

/// Persistence for per-file resume state. JSON implementation below; the app uses SQLite (data/db.dart).
abstract class CheckpointStore {
  Future<Map<String, dynamic>> load(String transferId);
  Future<void> save(String transferId, Map<String, dynamic> state);
  Future<void> delete(String transferId);
}

class JsonCheckpointStore implements CheckpointStore {
  JsonCheckpointStore(this.dir);
  final String dir;

  File _f(String tid) => File(p.join(dir, '$tid.state.json'));

  @override
  Future<Map<String, dynamic>> load(String tid) async {
    try {
      final j = jsonDecode(await _f(tid).readAsString());
      return j is Map<String, dynamic> ? j : {};
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> save(String tid, Map<String, dynamic> state) async {
    final tmp = File('${_f(tid).path}.tmp');
    final raf = await tmp.open(mode: FileMode.write);
    await raf.writeFrom(utf8.encode(jsonEncode(state)));
    await raf.flush(); // fsync
    await raf.close();
    await tmp.rename(_f(tid).path); // atomic replace
  }

  @override
  Future<void> delete(String tid) async {
    if (await _f(tid).exists()) await _f(tid).delete();
  }
}

/// Free bytes on the volume holding [path]; provided by the platform adapter (statvfs / NSURL resource values).
typedef FreeSpaceProbe = Future<int> Function(String path);

class OpenPart {
  OpenPart(this.raf, this.hasher, this.index);
  final RandomAccessFile raf;
  final StreamingSha256 hasher;
  final int index;
}

class ReceiverStore {
  ReceiverStore(this.root, this.checkpoints, this.freeSpace, {this.reserve = 256 * 1024 * 1024});

  final String root; // app-private inbox; import to Photos/MediaStore happens after commit
  final CheckpointStore checkpoints;
  final FreeSpaceProbe freeSpace;
  final int reserve;
  late Manifest manifest;
  late Map<String, dynamic> _files; // "i" -> {ident, durable, done, final}

  String get _partialDir => p.join(root, '.ptp-partial', manifest.transferId);
  String partPath(int i) => p.join(_partialDir, '$i.part');

  Future<Map<int, int>> prepare(Manifest m, List<int> accepted) async {
    manifest = m;
    await Directory(_partialDir).create(recursive: true);
    final old = (await checkpoints.load(m.transferId))['files'];
    final prev = old is Map<String, dynamic> ? old : <String, dynamic>{};
    _files = {};
    final offsets = <int, int>{};
    for (final i in accepted) {
      final e = m.files[i];
      final ident = jsonEncode(e.ident);
      final pr = prev['$i'];
      final same = pr is Map && pr['ident'] == ident;
      final part = File(partPath(i));
      if (same && pr['done'] == true) {
        _files['$i'] = {'ident': ident, 'durable': e.size, 'done': true, 'final': pr['final']};
        offsets[i] = e.size;
        continue;
      }
      var durable = same && pr['durable'] is int ? pr['durable'] as int : 0;
      if (durable > 0 && (!await part.exists() || await part.length() < durable || durable > e.size)) durable = 0;
      if (await part.exists()) {
        final raf = await part.open(mode: FileMode.append);
        await raf.truncate(durable); // drop bytes written after the last fsync'd checkpoint
        await raf.close();
      }
      _files['$i'] = {'ident': ident, 'durable': durable, 'done': false, 'final': null};
      offsets[i] = durable;
    }
    await _save();
    return offsets;
  }

  Future<void> _save() => checkpoints.save(manifest.transferId, {'transferId': manifest.transferId, 'files': _files});

  bool isDone(int i) => _files['$i']?['done'] == true;
  String? finalPath(int i) => _files['$i']?['final'] as String?;

  Future<void> checkCapacity(int needed) async {
    final free = await freeSpace(root);
    if (free - reserve < needed) {
      throw PtpException(PtpErrorCode.storageInsufficient, 'need $needed bytes, ${free - reserve} available');
    }
  }

  Future<OpenPart> openPart(int i, int offset) async {
    final f = File(partPath(i));
    final raf = await f.open(mode: FileMode.append); // creates if missing; read+write
    await raf.truncate(offset);
    final hasher = StreamingSha256();
    await raf.setPosition(0);
    var remaining = offset;
    while (remaining > 0) {
      final buf = await raf.read(remaining < 1 << 20 ? remaining : 1 << 20);
      if (buf.isEmpty) {
        await raf.close();
        throw PtpException(PtpErrorCode.resumeStateInvalid, 'partial shorter than checkpoint');
      }
      hasher.add(buf);
      remaining -= buf.length;
    }
    await raf.setPosition(offset);
    return OpenPart(raf, hasher, i);
  }

  Future<void> checkpoint(OpenPart part, int offset) async {
    await part.raf.flush(); // fsync
    _files['${part.index}']['durable'] = offset;
    await _save();
  }

  /// fsync, then atomically rename into `<root>/<category>/<path>` (unique name, never overwrite).
  Future<String> commit(OpenPart part) async {
    final e = manifest.files[part.index];
    await part.raf.flush();
    await part.raf.close();
    var dest = resolveInside(root, '${e.category}/${e.path}');
    await Directory(p.dirname(dest)).create(recursive: true);
    dest = uniqueDestination(dest);
    await File(partPath(part.index)).rename(dest);
    _files['${part.index}']
      ..['done'] = true
      ..['durable'] = e.size
      ..['final'] = dest;
    await _save();
    return dest;
  }

  Future<void> discard(int i, [OpenPart? part]) async {
    await part?.raf.close();
    final f = File(partPath(i));
    if (await f.exists()) await f.delete();
    _files['$i']['durable'] = 0;
    await _save();
  }

  /// User action "Xóa dữ liệu tạm": remove partial data of this transfer.
  Future<void> deletePartials() async {
    final d = Directory(_partialDir);
    if (await d.exists()) await d.delete(recursive: true);
    await checkpoints.delete(manifest.transferId);
  }
}
