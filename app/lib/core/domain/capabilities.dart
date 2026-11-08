/// Capability document (contracts/capability.schema.json v1.1) and migration-plan intersection.
library;

import '../protocol/constants.dart';
import '../protocol/errors.dart';
import 'categories.dart';

class CategoryCapability {
  const CategoryCapability(this.id, {required this.canExport, required this.canImport, required this.status});
  final String id;
  final bool canExport;
  final bool canImport;
  final SupportStatus status;

  Map<String, Object?> toJson() => {'id': id, 'export': canExport, 'import': canImport, 'status': status.wire};
}

class Capabilities {
  Capabilities({
    required this.platform,
    required this.role,
    required this.osVersion,
    required this.appVersion,
    required this.categories,
    this.transports = const ['lan_tcp_tls13'],
    this.permissions = const {},
    this.freeStorageBytes,
    this.maxFileSizeBytes = maxFileSize,
    this.backgroundTransfer = false,
    this.backgroundConstraints = 'unknown',
    this.cryptoSuites = const ['TLS_AES_128_GCM_SHA256', 'TLS_AES_256_GCM_SHA384', 'TLS_CHACHA20_POLY1305_SHA256'],
  });

  final String platform;
  final String role;
  final String osVersion;
  final String appVersion;
  final List<CategoryCapability> categories;
  final List<String> transports;
  final Map<String, String> permissions;
  final int? freeStorageBytes;
  final int maxFileSizeBytes;
  final bool backgroundTransfer;
  final String backgroundConstraints;
  final List<String> cryptoSuites;

  /// No PII: no device name, no account, no file names.
  Map<String, Object?> toJson() => {
        'protocolVersion': '$protocolVersion',
        'platform': platform,
        'role': role,
        'osVersion': osVersion,
        'appVersion': appVersion,
        'categories': [for (final c in categories) c.toJson()],
        'transports': transports,
        'permissions': permissions,
        'freeStorageBytes': freeStorageBytes,
        'maxFileSizeBytes': maxFileSizeBytes,
        'backgroundTransfer': backgroundTransfer,
        'backgroundConstraints': backgroundConstraints,
        'cryptoSuites': cryptoSuites,
      };

  static Capabilities fromJson(Object? json) {
    if (json is! Map<String, dynamic>) throw PtpException(PtpErrorCode.protocolError, 'caps not an object');
    if (json['protocolVersion'] != '$protocolVersion' || !platformIds.contains(json['platform'])) {
      throw PtpException(PtpErrorCode.protocolVersionMismatch, 'capability protocol/platform');
    }
    final cats = json['categories'];
    if (cats is! List || cats.length > 64) throw PtpException(PtpErrorCode.protocolError, 'caps categories');
    final parsed = <CategoryCapability>[];
    for (final c in cats) {
      if (c is! Map<String, dynamic> || c['id'] is! String) {
        throw PtpException(PtpErrorCode.protocolError, 'caps category entry');
      }
      parsed.add(CategoryCapability(c['id'] as String,
          canExport: c['export'] == true, canImport: c['import'] == true, status: SupportStatus.fromWire(c['status'])));
    }
    final perms = json['permissions'];
    final free = json['freeStorageBytes'];
    return Capabilities(
      platform: json['platform'] as String,
      role: json['role'] is String ? json['role'] as String : 'both',
      osVersion: json['osVersion'] is String ? json['osVersion'] as String : '',
      appVersion: json['appVersion'] is String ? json['appVersion'] as String : '',
      categories: parsed,
      transports: json['transports'] is List ? (json['transports'] as List).whereType<String>().toList() : const [],
      permissions: perms is Map ? {for (final e in perms.entries) if (e.value is String) '${e.key}': e.value as String} : const {},
      freeStorageBytes: free is int ? free : null,
      backgroundTransfer: json['backgroundTransfer'] == true,
      backgroundConstraints:
          json['backgroundConstraints'] is String ? json['backgroundConstraints'] as String : 'unknown',
    );
  }
}

/// Categories the sender can export AND the receiver can import (runtime values from both peers).
Set<String> migrationPlan(Capabilities sender, Capabilities receiver) {
  final exp = {
    for (final c in sender.categories)
      if (c.canExport && c.status != SupportStatus.unsupported) c.id
  };
  final imp = {
    for (final c in receiver.categories)
      if (c.canImport && c.status != SupportStatus.unsupported) c.id
  };
  return exp.intersection(imp).intersection(categoryIds.toSet());
}
