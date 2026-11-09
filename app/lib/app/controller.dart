/// MigrationController — orchestrates one session for the UI: pairing, capability plan, selection,
/// batched transfer, auto-resume, import, report and history.
///
/// Sockets, TLS, the transfer engines and SHA-256 run in a background isolate (core/worker/transfer_worker.dart,
/// audit P0-2). This class stays on the UI isolate: state machine, user questions, platform permissions,
/// opening sources, importing into Photos/MediaStore/Contacts/Files, diagnostics and history.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:ptp_platform/ptp_platform.dart';

import '../core/domain/capabilities.dart';
import '../core/domain/categories.dart';
import '../core/domain/state_machine.dart';
import '../core/protocol/codec.dart';
import '../core/protocol/constants.dart';
import '../core/protocol/errors.dart';
import '../core/protocol/manifest.dart';
import '../core/protocol/qr_payload.dart';
import '../core/session/continuation.dart';
import '../core/session/session.dart';
import '../core/transfer/engine.dart';
import '../core/transfer/path_policy.dart';
import '../core/transfer/receiver_store.dart';
import '../core/worker/transfer_worker.dart';
import '../data/db.dart';
import 'continuation_repo.dart';
import 'diag_log.dart';

const appVersion = '0.1.0';

class ImportOutcome {
  ImportOutcome(this.category, this.name, this.status, this.location, this.message);
  final String category;
  final String name;
  final String status;
  final String? location;
  final String? message;
}

class Progress {
  int doneBytes = 0;
  int totalBytes = 0;
  int doneFiles = 0;
  int totalFiles = 0;
  String current = '';
  double mbps = 0;
}

class MigrationController extends ChangeNotifier {
  MigrationController(this.db);
  final AppDatabase db;

  late final sm = MigrationStateMachine(
      onTransition: (from, to, spec) => _log.event('transition', {'from': from, 'to': to, 'role': role}));
  final DiagLog _log = DiagLog.instance;
  String role = 'sender'; // this device's data role
  ProbeResult? probe;
  TransferWorkerClient? _worker;
  StreamSubscription<(String, Object?)>? _workerSub;
  bool _isHost = false;
  bool _paired = false;
  DeviceInfo? peer;
  String? qrUri;
  DateTime? qrExpires;
  List<String> qrEndpoints = const [];
  PtpException? error;
  bool reconnecting = false;
  String? deviceWarning;

  /// 'wifi' (default, unchanged behaviour), 'usb' (USB-C cable only, Android ↔ Android, experimental) or 'auto'
  /// (experimental: Wi-Fi, moved onto the cable when one is plugged in and MEASURED faster; back to Wi-Fi if the
  /// cable is slower or unplugged). In 'usb' mode the host listens on 127.0.0.1 and the joiner only dials the USB
  /// bridge: never falls back to Wi-Fi.
  String transport = 'wifi';

  /// Which link the live channel actually runs on (from the socket address, not assumed).
  bool onCable = false;

  /// True between a deliberate path switch and the resumed channel.
  bool switchingPath = false;
  final PathPolicy _policy = PathPolicy();
  PathReason get pathReason => _policy.reason;
  double? get pathWifiMbps => _policy.wifiMbps;
  double? get pathCableMbps => _policy.cableMbps;
  bool _usbArmed = false;

  /// "Tự động" is active on this session (both phones Android, USB supported) and waiting for / using a cable.
  bool get cableArmed => _usbArmed;
  bool _usbRelinking = false;
  Timer? _pathTimer;
  QrPayload? _wifiQr; // joiner: the scanned QR (Wi-Fi endpoints)
  int _hostPort = 0;

  // ------------------------------------------------------------------ continuation after restart (audit P1-10)
  ContinuationRepo? _contRepo;
  ContinuationRecord? _contRecord;

  /// Audit P2-18 "kiểm tra tăng cường": re-read every received file and compare its SHA-256 again before it is
  /// published. Off by default until its cost is measured on phones (docs/REMAINING_HARDENING_REPORT.md).
  bool strictVerify = false;

  /// This session continues an earlier transfer that BOTH phones verified (continuation.dart).
  bool continuedTransfer = false;

  /// Unfinished transfers found on this phone (shown on the home screen). No keys in here are shown.
  List<ContinuationRecord> pendingContinuations = const [];
  String? usbState;
  String? usbRole;
  String? usbError;
  Timer? _usbPoll;
  String _usbMode = 'listen';
  int _usbPort = 0;

  // Confirmation step
  String? pendingSas;
  DeviceInfo? pendingPeer;

  // Receiver approval of the incoming manifest
  Manifest? pendingManifest;
  int pendingNeeded = 0;
  Completer<bool>? _approve;

  // Sender selection: category -> items
  final Map<String, List<SourceItem>> selection = {};
  final Map<String, String> permission = {};
  Set<String> plan = {};

  final progress = Progress();
  final List<TransferReport> reports = [];
  final List<ImportOutcome> imports = [];
  bool userPaused = false;
  bool _thermalPaused = false;
  int? _sessionRow;
  Timer? _deviceTimer;
  Future<void> _importQueue = Future.value();
  String? _inbox;
  final Set<String> _seenTransferIds = {};

  // Sender batches survive reconnects so the same transferIds are resumed.
  List<List<SourceItem>> _batches = [];
  final List<String> _batchIds = [];
  int _batchIndex = 0;
  Completer<TransferReport>? _batchWait;
  int _progressBase = 0;
  DateTime _sendStarted = DateTime.now();

  MigrationState get state => sm.state;

  Future<ContinuationRepo?> _repo() async {
    if (_contRepo != null) return _contRepo;
    try {
      final inbox = _inbox ?? await PtpPlatform.inboxDir();
      _contRepo = ContinuationRepo(p.join(p.dirname(inbox), 'continuation'), _PlatformVault(), onEvent: _log.event);
    } catch (_) {}
    return _contRepo;
  }

  /// Reads unfinished transfers (drops expired / tampered / keyless ones). Called at start-up and after a session.
  Future<void> loadContinuations() async {
    try {
      pendingContinuations = await (await _repo())?.loadAll() ?? const [];
    } catch (_) {
      pendingContinuations = const [];
    }
    notifyListeners();
  }

  Future<List<Map<String, Object?>>> _contCandidatesForWorker() async {
    await loadContinuations();
    return [for (final r in pendingContinuations) ContinuationRepo.toWorker(r)];
  }

  Future<void> _saveContinuation() async {
    final r = _contRecord;
    if (r == null) return;
    try {
      await (await _repo())?.save(r);
    } catch (_) {
      _log.event('continuation_save', {'status': 'failed'});
    }
  }

  Future<void> _dropContinuation() async {
    final r = _contRecord;
    _contRecord = null;
    if (r == null) return;
    try {
      await (await _repo())?.delete(r.id);
    } catch (_) {}
  }

  void _persistSenderPlan() {
    final r = _contRecord;
    if (r == null || role != 'sender') return;
    r.transferIds
      ..clear()
      ..addAll(_batchIds);
    r.plan = {
      'batches': [
        for (final b in _batches) [for (final it in b) it.raw]
      ],
      'index': _batchIndex,
    };
    unawaited(_saveContinuation());
  }

  // ------------------------------------------------------------------ capabilities
  Future<Capabilities> _caps(String forRole) async {
    probe = await PtpPlatform.probe();
    final pr = probe!;
    try {
      _inbox = await PtpPlatform.inboxDir();
      await _log.open(p.dirname(_inbox!));
    } catch (_) {}
    _log.event('probe', {'platform': pr.platform, 'os': pr.osVersion, 'model': pr.model, 'role': forRole, 'free': pr.freeBytes});
    return Capabilities(
      platform: pr.platform,
      role: forRole,
      osVersion: pr.osVersion,
      appVersion: appVersion,
      categories: [
        for (final c in pr.categories)
          CategoryCapability(c['id'] as String,
              canExport: c['export'] == true,
              canImport: c['import'] == true,
              status: SupportStatus.fromWire(forRole == 'sender' ? c['status'] : c['importStatus']))
      ],
      permissions: pr.permissions,
      freeStorageBytes: pr.freeBytes,
      backgroundTransfer: pr.backgroundConstraints != 'ios_foreground_only',
      backgroundConstraints: pr.backgroundConstraints,
    );
  }

  DeviceInfo get _device => DeviceInfo(probe?.deviceName ?? 'Phone', probe?.platform ?? 'android', probe?.model ?? '');

  void answerConfirm(bool ok) {
    _worker?.send('confirm', ok);
    pendingSas = null;
    notifyListeners();
  }

  void _go(MigrationState s) {
    if (sm.state != s && sm.canGo(s)) sm.go(s);
    notifyListeners();
  }

  // ------------------------------------------------------------------ worker plumbing
  Future<Object?> _rpc(String op, Map<String, Object?> args) async {
    switch (op) {
      case 'closeRead':
        await PtpPlatform.closeRead(args['token'] as String);
        return null;
      case 'freeBytes':
        return PtpPlatform.freeBytes(args['path'] as String);
      case 'mediaCreate':
        return PtpPlatform.mediaCreate(args['category'] as String, args['name'] as String, args['mime'] as String?);
      case 'mediaReopen':
        return PtpPlatform.mediaReopen(args['uri'] as String);
      case 'mediaPublish':
        return PtpPlatform.mediaPublish(args['uri'] as String);
      case 'mediaDelete':
        await PtpPlatform.mediaDelete(args['uri'] as String);
        return null;
    }
    return null;
  }

  Future<void> _startWorker() async {
    final w = await TransferWorkerClient.spawn(_rpc);
    _worker = w;
    _workerSub = w.events.listen(_onWorkerEvent);
  }

  void _onWorkerEvent((String, Object?) ev) {
    final (type, data) = ev;
    switch (type) {
      case 'qr':
        final m = data as Map<String, Object?>;
        qrUri = m['uri'] as String;
        qrExpires = m['expiresAt'] as DateTime;
        qrEndpoints = (m['endpoints'] as List<Object?>).cast<String>();
        _hostPort = m['port'] as int;
        _log.event('qr_shown', {'endpoints': qrEndpoints.length, 'role': role, 'state': transport});
        if (transport == 'usb') unawaited(_startUsb('connect', m['port'] as int));
        notifyListeners();
      case 'confirm':
        final m = data as Map<String, Object?>;
        _go(MigrationState.pairing);
        _go(MigrationState.authenticating);
        pendingSas = m['sas'] as String;
        pendingPeer = m['peer'] as DeviceInfo;
        notifyListeners();
      case 'paired':
        final m = data as Map<String, Object?>;
        peer = m['peer'] as DeviceInfo;
        plan = (m['plan'] as List<Object?>).cast<String>().toSet();
        onCable = transport == 'usb' || (transport == 'auto' && m['loopback'] == true);
        final cm = m['cont'];
        if (cm is Map) {
          try {
            final j = cm.cast<String, Object?>();
            _contRecord = ContinuationRecord.fromJson(j, unb64u(j['key'], length: 32));
            continuedTransfer = j['continued'] == true;
          } catch (_) {
            _contRecord = null;
            continuedTransfer = false;
          }
        }
        if (m['resumed'] == true) {
          unawaited(_onResumed());
        } else {
          unawaited(_onPaired());
        }
      case 'progress':
        final m = data as Map<String, Object?>;
        final wire = m['wire'] as int;
        progress
          ..current = m['name'] as String
          ..doneBytes = _progressBase + wire;
        // Measured speed on BOTH phones (device test: the receiver showed none): bytes over the last 5 s;
        // before 2 s of samples exist, the average since the start of this send/receive.
        final now = DateTime.now();
        _speed.add(now, progress.doneBytes);
        final secs = now.difference(_sendStarted).inMilliseconds / 1000;
        progress.mbps = _speed.rate(now) ?? (secs > 0 ? (progress.doneBytes - _sendStartBytes) / 1e6 / secs : 0);
        notifyListeners();
      case 'approve':
        final m = data as Map<String, Object?>;
        unawaited(_approveCb(m['manifest'] as Manifest, m['needed'] as int)
            .then((ok) => _worker?.send('approve', ok)));
      case 'batch':
        final rep = data as TransferReport;
        if (role == 'sender') {
          _batchWait?.complete(rep);
        } else {
          _onReceivedBatch(rep);
        }
      case 'receiveDone':
        unawaited(_onReceiveDone());
      case 'error':
        _onWorkerError(data as PtpException);
      case 'log':
        final l = data as List<Object?>;
        _log.event(l[0] as String, (l[1] as Map<Object?, Object?>).cast<String, Object?>());
    }
  }

  int _sendStartBytes = 0;
  final RateMeter _speed = RateMeter();

  void _onWorkerError(PtpException e) {
    final wait = _batchWait;
    if (wait != null && !wait.isCompleted) {
      _batchWait = null;
      wait.completeError(e); // the sender loop decides (resume or fail)
      return;
    }
    if (reconnecting) {
      reconnecting = false;
      _fail(e); // reconnect itself failed
      return;
    }
    if (_paired && e.code.resumable && !sm.state.isTerminal) {
      _startReconnect();
    } else {
      _fail(e);
    }
  }

  // ------------------------------------------------------------------ pairing
  /// This device shows the QR. [myRole] is its data role.
  /// [mode]: 'wifi' | 'usb' | 'auto'; null keeps the current choice (e.g. "new code").
  Future<void> showQr(String myRole, {String? mode}) async {
    final m = mode ?? transport;
    await _closePrevious();
    _resetSession(myRole);
    transport = m;
    final usb = m == 'usb';
    try {
      _go(MigrationState.discovering);
      final caps = await _caps(myRole);
      if (usb) await _requireUsb();
      final cont = await _contCandidatesForWorker();
      await _startWorker();
      _isHost = true;
      _worker!.send('host', {
        'cont': cont,
        'role': myRole,
        'device': _device,
        'caps': caps,
        'loopbackOnly': usb,
        'flags': usb ? const ['usb'] : (m == 'auto' ? const [usbAutoFlag] : const <String>[]),
      });
    } on PtpException catch (e) {
      _fail(e);
    }
  }

  /// This device scanned [uri]; its role is the opposite of the QR host's role.
  Future<void> joinQr(String uri) async {
    try {
      final qr = QrPayload.parse(uri);
      await _closePrevious();
      _resetSession(qr.hostRole == 'receiver' ? 'sender' : 'receiver');
      transport = qr.flags.contains('usb') ? 'usb' : (qr.flags.contains(usbAutoFlag) ? 'auto' : 'wifi');
      _wifiQr = qr;
      _go(MigrationState.discovering);
      final caps = await _caps(role);
      var dial = uri;
      if (transport == 'usb') {
        await _requireUsb();
        final port = await _startUsb('listen', 0, waitConnected: true);
        // Same session id, fingerprint and expiry; only the endpoint changes to the local USB bridge.
        dial = QrPayload(
                version: qr.version,
                sid: qr.sid,
                expiresAt: qr.expiresAt,
                endpoints: ['127.0.0.1:$port'],
                fingerprint: qr.fingerprint,
                hostRole: qr.hostRole,
                platform: qr.platform,
                flags: qr.flags)
            .toUri();
      }
      _go(MigrationState.pairing);
      final cont = await _contCandidatesForWorker();
      await _startWorker();
      _isHost = false;
      _worker!.send('join', {'uri': dial, 'device': _device, 'caps': caps, 'cont': cont});
    } on PtpException catch (e) {
      _fail(e);
    }
  }

  // ------------------------------------------------------------------ USB-C cable (experimental, Android only)
  Future<void> _requireUsb() async {
    final st = await PtpPlatform.usbStatus();
    if (st['supported'] != true) {
      throw PtpException(PtpErrorCode.platformRestriction, (st['error'] as String?) ?? 'USB_NOT_SUPPORTED');
    }
  }

  /// Starts the native USB bridge and keeps polling it. With [waitConnected], returns the local bridge port once the
  /// cable link is up (joiner). If the cable drops after pairing, the bridge is restarted on the same port so the
  /// worker's normal resume logic reconnects through it.
  Future<int> _startUsb(String mode, int port, {bool waitConnected = false, int timeoutMs = 90000}) async {
    _usbMode = mode;
    _usbPort = port;
    await PtpPlatform.usbStart(mode, port: port, timeoutMs: timeoutMs);
    final ready = Completer<int>();
    var lastState = '';
    _usbPoll?.cancel();
    _usbPoll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (_usbRelinking) return;
      Map<String, Object?> st;
      try {
        st = await PtpPlatform.usbStatus();
      } catch (_) {
        return;
      }
      usbState = st['state'] as String?;
      usbRole = st['role'] as String?;
      usbError = st['error'] as String?;
      if (usbState != lastState) {
        lastState = usbState ?? '';
        _log.event('usb', {'state': usbState, 'role': usbRole, 'code': usbError});
        notifyListeners();
      }
      final bp = st['bridgePort'];
      if (usbState == 'connected') {
        if (bp is int && bp > 0) _usbPort = mode == 'listen' ? bp : _usbPort;
        if (!ready.isCompleted) ready.complete(mode == 'listen' ? (bp as int? ?? 0) : port);
        if (transport == 'auto') _policy.onCableState(true);
      } else if (usbState == 'failed') {
        if (transport == 'auto') {
          _policy.onCableState(false);
          final code = (usbError ?? '').split(':').first;
          // Unplugged or nothing plugged yet: keep waiting for a cable. Anything else (permission denied,
          // unknown accessory, no USB support): stop trying and stay on Wi-Fi, without asking again.
          if (_sessionLive && (code == 'LINK_LOST' || code == 'USB_TIMEOUT')) {
            await _relinkUsb(timeoutMs);
          } else {
            _usbPoll?.cancel();
            _usbArmed = false;
            _log.event('path_auto_off', {'code': code});
            try {
              await PtpPlatform.usbStop();
            } catch (_) {}
          }
          return;
        }
        if (waitConnected && !ready.isCompleted) {
          ready.completeError(PtpException(PtpErrorCode.platformRestriction, usbError ?? 'USB_FAILED'));
        } else if (_sessionLive) {
          // Cable unplugged/replugged mid-session: relink on the same local port; resume does the rest.
          await _relinkUsb(timeoutMs);
        } else if (!_paired) {
          _fail(PtpException(PtpErrorCode.platformRestriction, usbError ?? 'USB_FAILED'));
        }
      }
    });
    if (!waitConnected) return port;
    return ready.future.timeout(const Duration(seconds: 100),
        onTimeout: () => throw PtpException(PtpErrorCode.platformRestriction, 'USB_TIMEOUT'));
  }

  /// Paired and not finished. While reconnecting the state machine sits in `failed`, but the session is still alive.
  bool get _sessionLive => _paired && (!sm.state.isTerminal || reconnecting);

  Future<void> _relinkUsb(int timeoutMs) async {
    _usbRelinking = true;
    try {
      _log.event('usb_relink', {'role': usbRole, 'state': transport});
      await PtpPlatform.usbStart(_usbMode, port: _usbPort, timeoutMs: timeoutMs);
    } catch (_) {
    } finally {
      _usbRelinking = false;
    }
  }

  // ------------------------------------------------------------------ "Tự động": Wi-Fi → cable handover
  static const int _autoWaitMs = 6 * 60 * 60 * 1000; // wait for a cable for the whole session, not 90 s

  /// Both phones Android and the host asked for 'auto': start waiting for a cable in the background.
  /// The host forwards cable connections to its own TLS port; the joiner exposes the cable on a local port.
  Future<void> _armUsbAuto() async {
    if (transport != 'auto' || _usbArmed) return;
    if (probe?.platform != 'android' || peer?.platform != 'android') {
      _log.event('path_auto_off', {'peerPlatform': peer?.platform});
      return;
    }
    try {
      final st = await PtpPlatform.usbStatus();
      if (st['supported'] != true) return;
      _usbArmed = true;
      if (_isHost) {
        await _startUsb('connect', _hostPort, timeoutMs: _autoWaitMs);
      } else {
        await _startUsb('listen', 0, timeoutMs: _autoWaitMs);
        _pathTimer?.cancel();
        _pathTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _pathTick());
      }
    } catch (_) {
      _usbArmed = false;
    }
  }

  /// Joiner only: feed real progress into the policy and carry out its decision.
  void _pathTick() {
    final now = DateTime.now();
    final transferring = sm.state == MigrationState.transferring && !userPaused && !_thermalPaused && !reconnecting;
    // Only real progress counts: no samples while paused / reconnecting, so a stall never reads as "0 MB/s".
    if (transferring) _policy.onBytes(now, progress.doneBytes);
    final from = _policy.path;
    final action = _policy.tick(now, transferring: transferring);
    if (action == PathAction.none) return;
    final qr = _wifiQr;
    if (qr == null) return;
    final usbEp = '127.0.0.1:$_usbPort';
    // Preferred path first, the other one as a fallback for the reconnect loop.
    final eps = action == PathAction.toCable
        ? [usbEp, ...qr.endpoints]
        : [...qr.endpoints, if (_policy.cableUp && !_policy.cableRejected && _usbPort > 0) usbEp];
    final uri = QrPayload(
            version: qr.version,
            sid: qr.sid,
            expiresAt: qr.expiresAt,
            endpoints: eps.take(8).toList(),
            fingerprint: qr.fingerprint,
            hostRole: qr.hostRole,
            platform: qr.platform,
            flags: qr.flags)
        .toUri();
    _log.event('path_switch', {
      'from': from.name,
      'to': _policy.path.name,
      'reason': _policy.reason.name,
      'wifiMbps': _policy.wifiMbps == null ? null : double.parse(_policy.wifiMbps!.toStringAsFixed(1)),
      'cableMbps': _policy.cableMbps == null ? null : double.parse(_policy.cableMbps!.toStringAsFixed(1)),
    });
    switchingPath = true;
    _worker?.send('dial', {'uri': uri, 'drop': true, 'to': _policy.path.name});
    notifyListeners();
  }

  Future<void> _onPaired() async {
    _paired = true;
    unawaited(_armUsbAuto());
    _go(MigrationState.capabilityExchange);
    _log.event('paired', {'peerPlatform': peer?.platform, 'role': role, 'count': plan.length});
    _sessionRow ??= await db.startSession(role);
    final plan0 = _contRecord?.plan;
    if (role == 'sender' && continuedTransfer && plan0 != null && _restorePlan(plan0)) {
      // Both phones proved the same earlier transfer: send what is left, with the same transfer ids, so the
      // receiver continues from its (MAC-checked) checkpoints. The receiver still approves the manifest.
      _log.event('continuation', {'state': 'resume_send', 'batch': _batchIndex, 'batches': _batches.length});
      _go(MigrationState.scanning);
      _go(MigrationState.preview);
      _go(MigrationState.preparing);
      await _requestNotifications();
      await PtpPlatform.setTransferActive(true);
      _startDeviceMonitor();
      _sendStarted = DateTime.now();
      _sendStartBytes = 0;
      await _sendRemainingBatches();
    } else if (role == 'sender') {
      _go(MigrationState.scanning);
      _go(MigrationState.preview);
    } else {
      _go(MigrationState.preparing);
      await _requestNotifications();
      await PtpPlatform.setTransferActive(true);
      _startDeviceMonitor();
      _sendStarted = DateTime.now();
      _sendStartBytes = progress.doneBytes;
      _speed.reset();
      _sendReceiveCommand();
    }
  }

  bool _restorePlan(Map<String, Object?> plan) {
    try {
      final batches = [
        for (final b in plan['batches'] as List<Object?>)
          [for (final it in b as List<Object?>) SourceItem((it as Map).cast<String, Object?>())]
      ];
      final ids = _contRecord!.transferIds;
      final index = plan['index'] as int;
      if (batches.length != ids.length || index < 0 || index >= batches.length) return false;
      _batches = batches;
      _batchIds
        ..clear()
        ..addAll(ids);
      _batchIndex = index;
      final left = batches.sublist(index).expand((b) => b);
      progress
        ..totalFiles = left.length
        ..totalBytes = left.fold(0, (a, i) => a + i.sizeHint);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _sendReceiveCommand() {
    final inbox = _inbox!;
    final android = probe?.platform == 'android';
    _worker?.send('receive', {
      'inbox': inbox,
      'checkpoints': p.join(p.dirname(inbox), 'checkpoints'),
      'reserve': storageReserve,
      // Audit P1-7: Android writes media/documents straight into MediaStore (one write); contacts still go through
      // the inbox. iOS keeps the inbox: Photos import moves the file (shouldMoveFile), so nothing is copied.
      'mediaCategories': android ? const ['photos', 'videos', 'audio', 'documents'] : const <String>[],
      'importCopies': android,
      // Audit P2-18: size check always; full read-back + SHA-256 only when [strictVerify] (one extra read per file).
      'verify': strictVerify ? 'full' : 'size',
    });
  }

  // ------------------------------------------------------------------ sender: selection
  Future<void> selectCategory(String category) async {
    if (category == 'documents' || (category == 'audio' && probe?.platform == 'ios')) {
      final picked = await PtpPlatform.pickDocuments(category: category);
      selection[category] = [...?selection[category], ...picked];
      notifyListeners();
      return;
    }
    final perm = await PtpPlatform.requestPermission(category, forImport: false);
    permission[category] = perm;
    _log.event('permission', {'category': category, 'perm': perm});
    if (perm == 'granted' || perm == 'limited') {
      selection[category] = await PtpPlatform.scan(category);
      _log.event('scan', {'category': category, 'count': selection[category]!.length});
    }
    notifyListeners();
  }

  void clearCategory(String category) {
    selection.remove(category);
    notifyListeners();
  }

  int get selectedCount => selection.values.fold(0, (a, l) => a + l.length);
  int get selectedBytesHint => selection.values.expand((l) => l).fold(0, (a, i) => a + i.sizeHint);

  List<SourceItem> _orderedSelection() {
    final out = <SourceItem>[];
    for (final c in categoryRegistry) {
      if (!plan.contains(c.id)) continue;
      out.addAll(selection[c.id] ?? const []);
    }
    return out;
  }

  Future<void> startSending() async {
    final items = _orderedSelection();
    if (items.isEmpty) return;
    _batches = _splitBatches(items);
    _batchIds
      ..clear()
      ..addAll(List.generate(_batches.length, (_) => b64u(randomBytes(16))));
    _batchIndex = 0;
    _persistSenderPlan();
    progress
      ..totalFiles = items.length
      ..totalBytes = selectedBytesHint;
    _go(MigrationState.preparing);
    await _requestNotifications();
    await PtpPlatform.setTransferActive(true);
    _startDeviceMonitor();
    _sendStarted = DateTime.now();
    _sendStartBytes = 0;
    await _sendRemainingBatches();
  }

  /// ≤ 1000 items per manifest (bounds open descriptors on Android and staged exports on iOS).
  List<List<SourceItem>> _splitBatches(List<SourceItem> items) {
    const maxItems = 1000;
    final out = <List<SourceItem>>[];
    for (var i = 0; i < items.length; i += maxItems) {
      out.add(items.sublist(i, i + maxItems > items.length ? items.length : i + maxItems));
    }
    return out;
  }

  /// Opens the batch on the UI isolate (platform channels) and returns plain descriptions for the worker.
  /// Unique relPaths per category (two IMG_0001.HEIC from different years must not collide).
  Future<List<Map<String, Object?>>> _openBatch(List<SourceItem> batch) async {
    final seen = <String>{};
    final out = <Map<String, Object?>>[];
    var stagedBytes = 0;
    final free = probe?.freeBytes ?? 0;
    for (final it in batch) {
      final opened = await PtpPlatform.openForRead(it);
      stagedBytes += probe?.platform == 'ios' ? opened.size : 0;
      if (probe?.platform == 'ios' && free > 0 && stagedBytes > free ~/ 4 && out.isNotEmpty) {
        // Staging on iOS doubles storage temporarily; stop this batch early and let the next one follow.
        await PtpPlatform.closeRead(opened.token);
        break;
      }
      var rel = it.relPath;
      var n = 1;
      while (!seen.add('${it.category}/${rel.toLowerCase()}')) {
        final ext = p.extension(it.relPath);
        rel = '${p.withoutExtension(it.relPath)} (${n++})$ext';
      }
      if (it.sizeHint == 0 && !_seenTransferIds.contains(_batchIds[_batchIndex])) {
        progress.totalBytes += opened.size; // iOS Photos/contacts: size known only now
      }
      out.add({
        'path': opened.path,
        'relPath': rel,
        'category': it.category,
        'mime': it.mime,
        'mtimeMs': opened.mtimeMs,
        'token': opened.token,
      });
    }
    _seenTransferIds.add(_batchIds[_batchIndex]);
    return out;
  }

  Future<void> _sendRemainingBatches() async {
    try {
      while (_batchIndex < _batches.length) {
        final items = await _openBatch(_batches[_batchIndex]);
        if (items.length < _batches[_batchIndex].length) {
          // iOS staging limit hit: push the rest into a new batch right after this one.
          final rest = _batches[_batchIndex].sublist(items.length);
          _batches[_batchIndex] = _batches[_batchIndex].sublist(0, items.length);
          _batches.insert(_batchIndex + 1, rest);
          _batchIds.insert(_batchIndex + 1, b64u(randomBytes(16)));
          _persistSenderPlan();
        }
        _go(MigrationState.transferring);
        _progressBase = reports.fold(0, (a, r) => a + r.wireBytes);
        final wait = Completer<TransferReport>();
        _batchWait = wait;
        _worker!.send('send', {
          'transferId': _batchIds[_batchIndex],
          'more': _batchIndex < _batches.length - 1,
          'items': items,
        });
        final rep = await wait.future;
        _batchWait = null;
        reports.add(rep);
        _logBatch(rep);
        progress.doneFiles += rep.ok.length + rep.failed.length + rep.skipped.length;
        _batchIndex++;
        _persistSenderPlan();
      }
      await _finish();
    } on PtpException catch (e) {
      if (e.code.resumable && !reconnecting) {
        _startReconnect();
      } else {
        reconnecting = false;
        _fail(e);
      }
    }
  }

  // ------------------------------------------------------------------ receiver
  bool _approvedOnce = false;
  final Set<String> _countedBatches = {};
  int _recvBase = 0;

  /// Receiver-side write permissions asked in this session: category -> granted|limited|denied.
  final Map<String, String> importPermission = {};

  void _onReceivedBatch(TransferReport rep) {
    reports.add(rep);
    _recvBase += rep.wireBytes;
    _progressBase = _recvBase;
    _logBatch(rep);
    _queueImports(rep);
    notifyListeners();
  }

  Future<void> _onReceiveDone() async {
    _go(MigrationState.importing);
    await _importQueue;
    await _finish();
  }

  Future<bool> _approveCb(Manifest m, int needed) async {
    _seenTransferIds.add(m.transferId);
    final cr = _contRecord;
    if (cr != null && role == 'receiver' && !cr.transferIds.contains(m.transferId)) {
      cr.transferIds.add(m.transferId);
      await _saveContinuation();
    }
    if (_countedBatches.add(m.transferId)) {
      progress
        ..totalFiles += m.files.length
        ..totalBytes += m.totalBytes;
    }
    _log.event('manifest', {'files': m.files.length, 'bytes': m.totalBytes, 'needed': needed});
    if (_approvedOnce) {
      await _ensureImportPermissions(m);
      _go(MigrationState.transferring);
      return true; // later batches / resumes of an approved session
    }
    pendingManifest = m;
    pendingNeeded = needed;
    _approve = Completer<bool>();
    notifyListeners();
    final ok = await _approve!.future;
    _approvedOnce = ok;
    pendingManifest = null;
    if (ok) await _ensureImportPermissions(m);
    if (ok) _go(MigrationState.transferring);
    return ok;
  }

  /// P0-1: ask for write access on THIS (receiving) device before data arrives — iOS Photos add-only and
  /// Contacts. Android needs none for its own MediaStore entries; contacts go through the system app.
  /// A refusal is not fatal: files are kept in Files/Downloads and the report says so.
  Future<void> _ensureImportPermissions(Manifest m) async {
    final cats = {for (final f in m.files) f.category};
    for (final c in const ['photos', 'videos', 'contacts']) {
      if (!cats.contains(c) || importPermission.containsKey(c)) continue;
      if (c == 'videos' && importPermission.containsKey('photos')) {
        importPermission[c] = importPermission['photos']!; // same Photos permission on iOS
        continue;
      }
      try {
        importPermission[c] = await PtpPlatform.requestPermission(c, forImport: true);
      } catch (_) {
        importPermission[c] = 'denied';
      }
      _log.event('import_permission', {'category': c, 'perm': importPermission[c]});
    }
    notifyListeners();
  }

  /// Android 13+: the foreground-service notification is hidden unless the user allows notifications.
  Future<void> _requestNotifications() async {
    try {
      final r = await PtpPlatform.requestPermission('notifications', forImport: false);
      _log.event('permission', {'category': 'notifications', 'perm': r});
    } catch (_) {}
  }

  void _logBatch(TransferReport r) => _log.event('batch_done', {
        'role': role,
        'files': r.manifest?.files.length,
        'ok': r.ok.length,
        'failed': r.failed.length,
        'skipped': r.skipped.length,
        'bytes': r.wireBytes,
        'mbps': double.parse(r.mbPerSecond.toStringAsFixed(2)),
        'more': r.more,
        'ms': r.elapsed.inMilliseconds,
        // Where the time went (see TransferReport.timers); numbers only, no file names.
        for (final e in r.timingsMs.entries) 't_${e.key}': e.value,
      });

  Future<void> _closePrevious() async {
    _usbPoll?.cancel();
    _usbPoll = null;
    _pathTimer?.cancel();
    _pathTimer = null;
    if (transport == 'usb' || _usbArmed) {
      try {
        await PtpPlatform.usbStop();
      } catch (_) {}
    }
    await _workerSub?.cancel();
    _workerSub = null;
    final w = _worker;
    _worker = null;
    if (w != null) await w.dispose();
  }

  /// Copies the diagnostic log to Downloads (Android) / Files (iOS). Returns where it went.
  Future<String?> exportLog() async {
    try {
      // Possible from the home screen before any session: open the log folder first.
      await _log.open(p.dirname(_inbox ?? await PtpPlatform.inboxDir()));
    } catch (_) {}
    final snap = await _log.snapshot();
    if (snap == null) return null;
    final ts = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final r = await PtpPlatform.importFile(snap, 'documents', 'chuyen-du-lieu-log-$ts.txt', 'text/plain');
    return r.location;
  }

  void answerApprove(bool ok) {
    _approve?.complete(ok);
    _approve = null;
    notifyListeners();
  }

  /// Imports run in order on the UI isolate (platform channels), concurrently with receiving the next batch.
  void _queueImports(TransferReport rep) {
    final m = rep.manifest!;
    for (final e in rep.committedPaths.entries) {
      final entry = m.files[e.key];
      if (e.value.startsWith(publishedPrefix)) {
        // Already written into its final place while receiving (audit P1-7): nothing to copy.
        imports.add(ImportOutcome(entry.category, entry.path, 'imported', e.value.substring(publishedPrefix.length), null));
        _log.event('import', {'category': entry.category, 'status': 'imported', 'state': 'direct'});
        continue;
      }
      _importQueue = _importQueue.then((_) async {
        try {
          final r = await PtpPlatform.importFile(e.value, entry.category, p.basename(entry.path), entry.mime);
          imports.add(ImportOutcome(entry.category, entry.path, r.status, r.location, r.message));
          _log.event('import', {'category': entry.category, 'status': r.status});
        } catch (_) {
          imports.add(ImportOutcome(entry.category, entry.path, 'failed', null, 'import error'));
        }
        notifyListeners();
      });
    }
  }

  // ------------------------------------------------------------------ resume
  void _startReconnect() {
    reconnecting = true;
    _log.event('reconnect_start', {'role': role, 'state': _isHost ? 'host' : 'joiner'});
    _go(MigrationState.failed);
    _worker?.send('reconnect');
    notifyListeners();
  }

  Future<void> _onResumed() async {
    reconnecting = false;
    switchingPath = false;
    _log.event('resumed', {'role': role});
    _go(MigrationState.pairing);
    _go(MigrationState.authenticating);
    _go(MigrationState.capabilityExchange);
    _go(MigrationState.preparing);
    if (role == 'sender') {
      await _sendRemainingBatches();
    } else {
      _sendReceiveCommand();
    }
  }

  // ------------------------------------------------------------------ pause / cancel / device state
  void togglePause() {
    userPaused = !userPaused;
    _applyPause();
    notifyListeners();
  }

  void _applyPause() => _worker?.send(userPaused || _thermalPaused ? 'pause' : 'resume');

  Future<void> cancel() async {
    _worker?.send('cancel');
    _approve?.complete(false);
    _approve = null;
    if (pendingSas != null) answerConfirm(false);
    if (!sm.state.isTerminal) _go(MigrationState.cancelled);
    // Give the worker a moment to tell the peer, then stop it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _teardown();
    await _dropContinuation(); // the user abandoned this transfer
    unawaited(loadContinuations());
    await _record('cancelled', PtpErrorCode.userCancelled);
    notifyListeners();
  }

  /// "Xóa dữ liệu tạm": removes partial files and checkpoints of this session's batches (worker may be gone).
  Future<void> deletePartials() async {
    final inbox = _inbox;
    if (inbox == null) return;
    for (final tid in _seenTransferIds) {
      try {
        final d = Directory(p.join(inbox, '.ptp-partial', tid));
        if (await d.exists()) await d.delete(recursive: true);
        final cp = File(p.join(p.dirname(inbox), 'checkpoints', '$tid.state.json'));
        if (await cp.exists()) {
          // Hidden MediaStore items of unfinished files (audit P1-7) are removed too.
          try {
            final files = (jsonDecode(await cp.readAsString()) as Map)['files'] as Map;
            for (final r in files.values) {
              if (r is Map && r['done'] != true && r['uri'] is String) await PtpPlatform.mediaDelete(r['uri'] as String);
            }
          } catch (_) {}
          await cp.delete();
        }
      } catch (_) {}
    }
    _log.event('partials_deleted', {'count': _seenTransferIds.length});
    notifyListeners();
  }

  /// Pauses on serious/critical thermal state; warns on low battery. Values come from the OS, not estimates.
  void _startDeviceMonitor() {
    _deviceTimer?.cancel();
    _deviceTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      try {
        final st = await PtpPlatform.deviceState();
        final hot = st['thermal'] == 'serious' || st['thermal'] == 'critical';
        final pct = st['batteryPct'] as int? ?? -1;
        final low = pct >= 0 && pct < 10 && st['charging'] != true;
        final warn = hot ? 'thermal_pause' : (low ? 'battery_low' : null);
        if (warn != deviceWarning) _log.event('device', {'thermal': st['thermal'], 'battery': pct, 'charging': st['charging']});
        deviceWarning = warn;
        if (hot != _thermalPaused) {
          _thermalPaused = hot;
          _applyPause();
        }
        notifyListeners();
      } catch (_) {}
    });
  }

  // ------------------------------------------------------------------ end states
  int get okCount => reports.fold(0, (a, r) => a + r.ok.length);
  int get failedCount => reports.fold(0, (a, r) => a + r.failed.length);
  int get skippedCount => reports.fold(0, (a, r) => a + r.skipped.length);
  int get needsActionCount => imports.where((i) => i.status == 'requires_user_action' || i.status == 'failed').length;

  Future<void> _finish() async {
    _log.event('finish', {'ok': okCount, 'failed': failedCount, 'skipped': skippedCount, 'role': role});
    await _dropContinuation(); // nothing left to continue
    unawaited(loadContinuations());
    final partial = failedCount > 0 || skippedCount > 0 || imports.any((i) => i.status == 'failed');
    if (sm.state == MigrationState.importing && !partial) {
      _go(MigrationState.completed);
    } else if (partial && sm.canGo(MigrationState.partial)) {
      _go(MigrationState.partial);
    } else {
      _go(MigrationState.completed);
    }
    await _teardown();
    await _record(sm.state.name, null);
  }

  void _fail(PtpException e) {
    error = e;
    _log.event('error', {'code': e.code.wire, 'state': sm.state, 'role': role});
    if (!sm.state.isTerminal) {
      _go(e.code == PtpErrorCode.userCancelled ? MigrationState.cancelled : MigrationState.failed);
    }
    unawaited(_teardown());
    unawaited(_record(sm.state.name, e.code));
    notifyListeners();
  }

  Future<void> _teardown() async {
    _deviceTimer?.cancel();
    _usbPoll?.cancel();
    _usbPoll = null;
    _pathTimer?.cancel();
    _pathTimer = null;
    if (transport == 'usb' || _usbArmed) {
      try {
        await PtpPlatform.usbStop();
      } catch (_) {}
    }
    try {
      await PtpPlatform.setTransferActive(false);
    } catch (_) {}
    await _closePrevious();
  }

  Future<void> _record(String state, PtpErrorCode? code) async {
    final row = _sessionRow;
    if (row == null) return;
    final cats = <String, int>{};
    for (final r in reports) {
      for (final i in r.ok) {
        final c = r.manifest!.files[i].category;
        cats[c] = (cats[c] ?? 0) + 1;
      }
    }
    await db.finishSession(row,
        state: state,
        peerPlatform: peer?.platform,
        errorCode: code?.wire,
        ok: okCount,
        failed: failedCount,
        skipped: skippedCount,
        // Device test: a cancelled session showed 0.0 MB although ~200 MB had moved (only finished batches were
        // counted). Count the bytes actually moved, finished batch or not.
        bytes: max(reports.fold<int>(0, (a, r) => a + r.wireBytes), progress.doneBytes),
        durationMs: reports.fold(0, (a, r) => a + r.elapsed.inMilliseconds),
        categories: cats);
  }

  void _resetSession(String myRole) {
    role = myRole;
    sm.reset();
    error = null;
    peer = null;
    _paired = false;
    qrUri = null;
    qrEndpoints = const [];
    reconnecting = false;
    pendingSas = null;
    pendingManifest = null;
    selection.clear();
    permission.clear();
    reports.clear();
    imports.clear();
    _batches = [];
    _batchIds.clear();
    _batchIndex = 0;
    _batchWait = null;
    _approvedOnce = false;
    _countedBatches.clear();
    _seenTransferIds.clear();
    _recvBase = 0;
    _progressBase = 0;
    importPermission.clear();
    _sessionRow = null;
    userPaused = false;
    _thermalPaused = false;
    transport = 'wifi';
    _contRecord = null;
    continuedTransfer = false;
    onCable = false;
    switchingPath = false;
    _usbArmed = false;
    _wifiQr = null;
    _policy.reset();
    usbState = null;
    usbRole = null;
    usbError = null;
    progress
      ..doneBytes = 0
      ..totalBytes = 0
      ..doneFiles = 0
      ..totalFiles = 0
      ..current = ''
      ..mbps = 0;
  }

  void backToHome() {
    sm.reset();
    notifyListeners();
  }
}

class _PlatformVault implements SecureVault {
  @override
  Future<void> put(String name, Uint8List secret) => PtpPlatform.vaultPut(name, base64.encode(secret));

  @override
  Future<Uint8List?> get(String name) async {
    final s = await PtpPlatform.vaultGet(name);
    return s == null ? null : base64.decode(s);
  }

  @override
  Future<void> delete(String name) => PtpPlatform.vaultDelete(name);
}
