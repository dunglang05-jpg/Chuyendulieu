/// Error model shared by protocol, engines and UI (PROTOCOL_v1 §9).
library;

enum PtpErrorCode {
  peerTimeout('PEER_TIMEOUT'),
  pairingExpired('PAIRING_EXPIRED'),
  authenticationFailed('AUTHENTICATION_FAILED'),
  protocolVersionMismatch('PROTOCOL_VERSION_MISMATCH'),
  protocolError('PROTOCOL_ERROR'),
  manifestInvalid('MANIFEST_INVALID'),
  capabilityUnavailable('CAPABILITY_UNAVAILABLE'),
  permissionDenied('PERMISSION_DENIED'),
  storageInsufficient('STORAGE_INSUFFICIENT'),
  fileChanged('FILE_CHANGED'),
  hashMismatch('HASH_MISMATCH'),
  networkInterrupted('NETWORK_INTERRUPTED'),
  resumeStateInvalid('RESUME_STATE_INVALID'),
  importRequiresUserAction('IMPORT_REQUIRES_USER_ACTION'),
  platformRestriction('PLATFORM_RESTRICTION'),
  sessionBusy('SESSION_BUSY'),
  userCancelled('USER_CANCELLED'),
  internalError('INTERNAL_ERROR');

  const PtpErrorCode(this.wire);
  final String wire;

  static PtpErrorCode fromWire(Object? s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => PtpErrorCode.internalError);

  /// Whether reconnecting with the resume token can recover from this error.
  bool get resumable => this == networkInterrupted || this == peerTimeout;
}

class PtpException implements Exception {
  PtpException(this.code, [this.message = '']);
  final PtpErrorCode code;
  final String message;

  @override
  String toString() => message.isEmpty ? code.wire : '${code.wire}: $message';
}
