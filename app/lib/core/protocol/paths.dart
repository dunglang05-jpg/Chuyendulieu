/// Receiver-side path rules (PROTOCOL_v1 §8): NFC, no traversal, no symlinks, portable characters.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'errors.dart';

const _forbidden = r'\:*?"<>|';

String validateRelativePath(Object? path) {
  if (path is! String || path.isEmpty) throw PtpException(PtpErrorCode.manifestInvalid, 'empty path');
  final norm = unorm.nfc(path);
  if (utf8.encode(norm).length > 1024 || norm.startsWith('/')) {
    throw PtpException(PtpErrorCode.manifestInvalid, 'path too long or absolute');
  }
  final segments = norm.split('/');
  if (segments.length > 32) throw PtpException(PtpErrorCode.manifestInvalid, 'path too deep');
  for (final seg in segments) {
    if (seg.isEmpty || seg == '.' || seg == '..' || utf8.encode(seg).length > 255) {
      throw PtpException(PtpErrorCode.manifestInvalid, 'bad path segment');
    }
    final last = seg[seg.length - 1];
    if (last == ' ' || last == '.') throw PtpException(PtpErrorCode.manifestInvalid, 'bad segment ending');
    for (final unit in seg.runes) {
      if (unit < 0x20 || unit == 0x7f || _forbidden.contains(String.fromCharCode(unit))) {
        throw PtpException(PtpErrorCode.manifestInvalid, 'forbidden character in path');
      }
    }
  }
  return norm;
}

/// Join a validated relative path to [root]; refuse escapes and symlinked components.
String resolveInside(String root, String rel) {
  final rootAbs = p.normalize(Directory(root).absolute.path);
  var cur = rootAbs;
  for (final part in rel.split('/')) {
    cur = p.join(cur, part);
    if (FileSystemEntity.isLinkSync(cur)) {
      throw PtpException(PtpErrorCode.manifestInvalid, 'symlink in destination path');
    }
  }
  final target = p.normalize(cur);
  if (!p.isWithin(rootAbs, target)) throw PtpException(PtpErrorCode.manifestInvalid, 'path escapes destination');
  return target;
}

/// "a.jpg" -> "a (1).jpg" when the name is taken. Never overwrites user data.
String uniqueDestination(String path) {
  if (!File(path).existsSync() && !Directory(path).existsSync()) return path;
  final dir = p.dirname(path);
  final ext = p.extension(path);
  final stem = p.basenameWithoutExtension(path);
  for (var n = 1; n < 10000; n++) {
    final cand = p.join(dir, '$stem ($n)$ext');
    if (!File(cand).existsSync() && !Directory(cand).existsSync()) return cand;
  }
  throw PtpException(PtpErrorCode.internalError, 'too many name collisions');
}
