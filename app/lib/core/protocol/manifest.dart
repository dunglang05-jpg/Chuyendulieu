/// Transfer manifest (PROTOCOL_v1 §7, contracts/transfer_manifest.schema.json).
library;

import 'codec.dart';
import 'constants.dart';
import 'errors.dart';
import 'paths.dart';

class FileEntry {
  const FileEntry({
    required this.index,
    required this.path,
    required this.size,
    required this.category,
    this.mime,
    this.mtimeMs,
  });

  final int index;
  final String path;
  final int size;
  final String category;
  final String? mime;
  final int? mtimeMs;

  Map<String, Object?> toJson() =>
      {'i': index, 'path': path, 'size': size, 'category': category, 'mime': mime, 'mtime': mtimeMs};

  /// Identity used to decide whether a partial file may be resumed.
  List<Object?> get ident => [path, size, mtimeMs, category];
}

class Manifest {
  Manifest(this.transferId, this.files);
  final String transferId;
  final List<FileEntry> files;

  int get totalBytes => files.fold(0, (a, f) => a + f.size);

  Map<String, Object?> toJson() => {
        't': 'manifest',
        'transferId': transferId,
        'totalBytes': totalBytes,
        'files': [for (final f in files) f.toJson()],
      };

  static const _fields = {'i', 'path', 'size', 'category', 'mime', 'mtime', 'sha256'};

  static Manifest fromJson(Map<String, dynamic> msg) {
    final tid = msg['transferId'];
    unb64u(tid is String ? tid : '', length: 16);
    final files = msg['files'];
    if (files is! List || files.length > maxFiles) throw PtpException(PtpErrorCode.manifestInvalid, 'bad file list');
    final out = <FileEntry>[];
    final seen = <String>{};
    for (var idx = 0; idx < files.length; idx++) {
      final f = files[idx];
      if (f is! Map<String, dynamic> || !_fields.containsAll(f.keys)) {
        throw PtpException(PtpErrorCode.manifestInvalid, 'bad file entry');
      }
      final size = f['size'];
      if (f['i'] != idx || size is! int || size < 0 || size > maxFileSize) {
        throw PtpException(PtpErrorCode.manifestInvalid, 'bad index or size');
      }
      final cat = f['category'];
      if (cat is! String || !categoryIds.contains(cat)) {
        throw PtpException(PtpErrorCode.manifestInvalid, 'unknown category');
      }
      final path = validateRelativePath(f['path']);
      if (!seen.add('$cat/${path.toLowerCase()}')) throw PtpException(PtpErrorCode.manifestInvalid, 'duplicate path');
      final mime = f['mime'];
      final mtime = f['mtime'];
      if (mime != null && (mime is! String || mime.length > 255)) {
        throw PtpException(PtpErrorCode.manifestInvalid, 'bad mime');
      }
      if (mtime != null && mtime is! int) throw PtpException(PtpErrorCode.manifestInvalid, 'bad mtime');
      out.add(FileEntry(index: idx, path: path, size: size, category: cat, mime: mime as String?, mtimeMs: mtime as int?));
    }
    final m = Manifest(tid as String, out);
    if (msg['totalBytes'] != m.totalBytes) throw PtpException(PtpErrorCode.manifestInvalid, 'totalBytes mismatch');
    return m;
  }
}
