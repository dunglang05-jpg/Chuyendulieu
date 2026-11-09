// Audit P1-7: the receiver writes media straight into its final destination (Android: a pending MediaStore item),
// so each byte is written once, the capacity check counts what is really needed, a full disk is reported as
// STORAGE_INSUFFICIENT, and a pending item is reused when the same transfer continues.
// The MediaStore is replaced by a folder ("shared storage") here; the real MediaStore path is NOT tested on devices.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:phone_transfer_pro/core/protocol/errors.dart';
import 'package:phone_transfer_pro/core/transfer/engine.dart';
import 'package:phone_transfer_pro/core/transfer/receiver_store.dart';

import 'loopback_transfer_test.dart' show pair, makeFile, sha;

/// Folder-backed stand-in for MediaStore: pending items are hidden files, publish renames them.
class FakeMediaSink implements MediaSink {
  FakeMediaSink(this.dir, {this.brokenPaths = false});
  final String dir;
  final bool brokenPaths; // returns a path this process cannot open (exercises the inbox fallback)
  int creates = 0;
  final deleted = <String>[];
  final _paths = <String, String>{};

  @override
  bool supports(String category) => category != 'contacts';

  @override
  Future<Map<String, String>> create(String category, String name, String? mime) async {
    creates++;
    await Directory(dir).create(recursive: true);
    final uri = 'fake://media/$creates';
    final path = brokenPaths ? p.join(dir, 'no-such-dir', name) : p.join(dir, '.pending-$creates-$name');
    if (!brokenPaths) await File(path).create();
    _paths[uri] = path;
    return {'uri': uri, 'path': path};
  }

  @override
  Future<String> reopen(String uri) async {
    final path = _paths[uri];
    if (path == null || !File(path).existsSync()) throw StateError('gone');
    return path;
  }

  @override
  Future<String> publish(String uri) async {
    final from = _paths.remove(uri)!;
    final name = p.basename(from).replaceFirst(RegExp(r'^\.pending-\d+-'), '');
    await File(from).rename(p.join(dir, name));
    return 'Pictures/PhoneTransferPro/$name';
  }

  @override
  Future<void> delete(String uri) async {
    deleted.add(uri);
    final path = _paths.remove(uri);
    if (path != null && File(path).existsSync()) await File(path).delete();
  }
}

Future<Object?> settle(Future<Object?> f) => f.then<Object?>((r) => r, onError: (Object e) => e);

int bytesUnder(String dir) => Directory(dir).existsSync()
    ? Directory(dir).listSync(recursive: true).whereType<File>().fold(0, (a, f) => a + f.lengthSync())
    : 0;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('ptp-sink-'));
  tearDown(() async => tmp.delete(recursive: true));

  ReceiverStore store(MediaSink? media, {bool importCopies = true, List<String>? events}) => ReceiverStore(
        p.join(tmp.path, 'inbox'),
        JsonCheckpointStore(p.join(tmp.path, 'cp')),
        (_) async => 1 << 40,
        reserve: 0,
        media: media,
        importCopies: importCopies,
        onEvent: (e, f) => events?.add('$e:${f['state']}'),
      );

  setUp(() async => Directory(p.join(tmp.path, 'cp')).createSync(recursive: true));

  test('media is written once, straight into the destination; contacts still use the inbox', () async {
    final photo = await makeFile(tmp, 'a.jpg', 3000123);
    final vcf = await makeFile(tmp, 'c.vcf', 1234);
    final sink = FakeMediaSink(p.join(tmp.path, 'shared'));
    final (h, hc, jc) = await pair();
    int? needed;
    final r = await Future.wait([
      runReceiver(hc, store(sink), approve: (m, n) async {
        needed = n;
        return true;
      }),
      runSender(jc, [FileSource(photo.path, 'DCIM/a.jpg', 'photos'), FileSource(vcf.path, 'c.vcf', 'contacts')]),
    ]);
    final rx = r[0];
    expect(rx.ok, [0, 1]);
    expect(rx.committedPaths[0], '${publishedPrefix}Pictures/PhoneTransferPro/a.jpg');
    expect(sha(File(p.join(tmp.path, 'shared', 'a.jpg'))), sha(photo));
    expect(File(p.join(tmp.path, 'inbox/photos/DCIM/a.jpg')).existsSync(), isFalse, reason: 'no inbox copy of media');
    expect(bytesUnder(p.join(tmp.path, 'shared')), 3000123, reason: 'exactly one copy of the photo was written');
    expect(sha(File(rx.committedPaths[1]!)), sha(vcf));
    expect(needed, 3000123 + 1234, reason: 'nothing is copied on import, so no extra space is asked for');
    await h.close();
  });

  test('without direct writes, the capacity check adds the largest file that will be copied on import', () async {
    final big = await makeFile(tmp, 'v.mp4', 2000000);
    final small = await makeFile(tmp, 'b.jpg', 5000);
    final (h, hc, jc) = await pair();
    int? needed;
    await Future.wait([
      runReceiver(hc, store(null), approve: (m, n) async {
        needed = n;
        return true;
      }),
      runSender(jc, [FileSource(big.path, 'v.mp4', 'videos'), FileSource(small.path, 'b.jpg', 'photos')]),
    ]);
    expect(needed, 2000000 + 5000 + 2000000);
    await h.close();
  });

  test('a path the process cannot open falls back to the inbox, deletes the pending item and still verifies', () async {
    final photo = await makeFile(tmp, 'a.jpg', 70000);
    final sink = FakeMediaSink(p.join(tmp.path, 'shared'), brokenPaths: true);
    final events = <String>[];
    final (h, hc, jc) = await pair();
    final r = await Future.wait([
      runReceiver(hc, store(sink, events: events)),
      runSender(jc, [FileSource(photo.path, 'a.jpg', 'photos')]),
    ]);
    expect(r[0].ok, [0]);
    expect(r[0].committedPaths[0]!.startsWith(publishedPrefix), isFalse);
    expect(sha(File(r[0].committedPaths[0]!)), sha(photo));
    expect(sink.deleted, ['fake://media/1']);
    expect(events, contains('media_sink_fallback:open'));
    await h.close();
  });

  test('a continued transfer reuses the same pending item from its checkpoint (no second item, no restart)', () async {
    final video = await makeFile(tmp, 'v.mp4', 20 * 1024 * 1024 + 11);
    final sink = FakeMediaSink(p.join(tmp.path, 'shared'));
    const tid = 'AAAAAAAAAAAAAAAAAAAAAA';

    var (h, hc, jc) = await pair();
    final token = CancelToken();
    await Future.wait([
      settle(runReceiver(hc, store(sink))),
      settle(runSender(jc, [FileSource(video.path, 'v.mp4', 'videos')], transferId: tid, cancel: token,
          onProgress: (i, d, t, w) {
        if (w > 10 * 1024 * 1024) token.cancel();
      })),
    ]);
    await h.close();
    expect(sink.creates, 1);

    (h, hc, jc) = await pair();
    final offsets = <int>[];
    final r = await Future.wait([
      runReceiver(hc, store(sink)),
      runSender(jc, [FileSource(video.path, 'v.mp4', 'videos')], transferId: tid, onProgress: (i, d, t, w) {
        if (offsets.isEmpty) offsets.add(d - w);
      }),
    ]);
    expect(r[0].ok, [0]);
    expect(sink.creates, 1, reason: 'the pending item from the first connection was reused');
    expect(offsets.single, greaterThanOrEqualTo(8 * 1024 * 1024), reason: 'continued from the 8 MiB checkpoint');
    expect(sha(File(p.join(tmp.path, 'shared', 'v.mp4'))), sha(video));
    await h.close();
  });

  test('disk full while writing becomes STORAGE_INSUFFICIENT, other write errors stay internal', () {
    expect(mapWriteError(const FileSystemException('w', 'x', OSError('No space left on device', 28))).code,
        PtpErrorCode.storageInsufficient);
    expect(mapWriteError(const FileSystemException('w', 'x', OSError('Disc quota exceeded', 69))).code,
        PtpErrorCode.storageInsufficient);
    expect(mapWriteError(const FileSystemException('w', 'x', OSError('I/O error', 5))).code, PtpErrorCode.internalError);
  });
}
