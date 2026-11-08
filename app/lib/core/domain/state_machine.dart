/// Migration state machine (master prompt F). Every transition declares timeout, retry policy,
/// whether a checkpoint is persisted, the user-facing error and the recovery action.
library;

import '../protocol/constants.dart';

enum MigrationState {
  idle,
  discovering, // showing QR / scanning QR
  pairing, // TLS + hello/welcome
  authenticating, // users compare the 6-digit code
  capabilityExchange,
  scanning, // sender: enumerate selected categories
  preview, // sender: choose items, see size; receiver: waits
  preparing, // receiver: capacity + permission checks, manifest_resp
  transferring,
  verifying, // SHA-256 at each file end (overlaps with transferring per file)
  importing, // receiver: MediaStore / Photos / Contacts / Files
  completed,
  partial,
  failed,
  cancelled;

  bool get isTerminal => this == completed || this == partial || this == failed || this == cancelled;
}

enum Recovery { none, retry, rescanQr, resume, grantPermission, freeSpace, openSettings }

class TransitionSpec {
  const TransitionSpec(this.from, this.to,
      {this.timeout, this.retries = 0, this.checkpoint = false, this.errorKey, this.recovery = Recovery.none});
  final MigrationState from;
  final MigrationState to;
  final Duration? timeout;
  final int retries;
  final bool checkpoint;
  final String? errorKey; // key into Strings for the failure of this step
  final Recovery recovery;
}


/// Forward transitions. Any non-terminal state may additionally go to failed/cancelled, and
/// transferring/verifying/importing may go to partial.
final List<TransitionSpec> transitionTable = [
  const TransitionSpec(MigrationState.idle, MigrationState.discovering),
  const TransitionSpec(MigrationState.discovering, MigrationState.pairing,
      timeout: qrTtl, errorKey: 'err_qr_expired', recovery: Recovery.rescanQr),
  const TransitionSpec(MigrationState.pairing, MigrationState.authenticating,
      timeout: handshakeTimeout, retries: 1, errorKey: 'err_connect', recovery: Recovery.rescanQr),
  const TransitionSpec(MigrationState.authenticating, MigrationState.capabilityExchange,
      timeout: confirmTimeout, checkpoint: true, errorKey: 'err_code_rejected', recovery: Recovery.rescanQr),
  const TransitionSpec(MigrationState.capabilityExchange, MigrationState.scanning,
      timeout: handshakeTimeout, errorKey: 'err_version', recovery: Recovery.none),
  // Receiver skips scanning/preview and waits for the manifest.
  const TransitionSpec(MigrationState.capabilityExchange, MigrationState.preparing,
      timeout: null, errorKey: 'err_peer_timeout', recovery: Recovery.retry),
  const TransitionSpec(MigrationState.scanning, MigrationState.preview,
      errorKey: 'err_permission', recovery: Recovery.grantPermission),
  const TransitionSpec(MigrationState.preview, MigrationState.preparing),
  const TransitionSpec(MigrationState.preparing, MigrationState.transferring,
      timeout: confirmTimeout, checkpoint: true, errorKey: 'err_storage', recovery: Recovery.freeSpace),
  const TransitionSpec(MigrationState.transferring, MigrationState.verifying,
      timeout: idleTimeout, retries: 1, checkpoint: true, errorKey: 'err_network', recovery: Recovery.resume),
  const TransitionSpec(MigrationState.verifying, MigrationState.transferring, checkpoint: true),
  const TransitionSpec(MigrationState.verifying, MigrationState.importing,
      checkpoint: true, errorKey: 'err_hash', recovery: Recovery.retry),
  const TransitionSpec(MigrationState.transferring, MigrationState.importing, checkpoint: true),
  const TransitionSpec(MigrationState.importing, MigrationState.completed, checkpoint: true),
  // Sender has nothing to import; it completes when the receiver's report arrives.
  const TransitionSpec(MigrationState.verifying, MigrationState.completed, checkpoint: true),
  const TransitionSpec(MigrationState.transferring, MigrationState.completed, checkpoint: true),
  // Resume path: a dropped transfer reconnects without a new QR.
  const TransitionSpec(MigrationState.failed, MigrationState.pairing,
      timeout: resumeWindow, errorKey: 'err_resume_expired', recovery: Recovery.rescanQr),
];

class IllegalTransition implements Exception {
  IllegalTransition(this.from, this.to);
  final MigrationState from;
  final MigrationState to;
  @override
  String toString() => 'Illegal transition ${from.name} -> ${to.name}';
}

class MigrationStateMachine {
  MigrationStateMachine({this.onTransition});
  MigrationState _state = MigrationState.idle;
  final void Function(MigrationState from, MigrationState to, TransitionSpec? spec)? onTransition;

  MigrationState get state => _state;

  TransitionSpec? specFor(MigrationState from, MigrationState to) {
    for (final s in transitionTable) {
      if (s.from == from && s.to == to) return s;
    }
    return null;
  }

  bool canGo(MigrationState to) {
    if (_state.isTerminal && !(_state == MigrationState.failed && to == MigrationState.pairing)) return false;
    if (to == MigrationState.failed || to == MigrationState.cancelled) return !_state.isTerminal;
    if (to == MigrationState.partial) {
      return _state == MigrationState.transferring ||
          _state == MigrationState.verifying ||
          _state == MigrationState.importing;
    }
    return specFor(_state, to) != null;
  }

  TransitionSpec? go(MigrationState to) {
    if (!canGo(to)) throw IllegalTransition(_state, to);
    final from = _state;
    final spec = specFor(from, to);
    _state = to;
    onTransition?.call(from, to, spec);
    return spec;
  }

  void reset() => _state = MigrationState.idle;
}

