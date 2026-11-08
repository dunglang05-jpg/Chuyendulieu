/// MigrationController — orchestrates one session for the UI: pairing, capability plan, selection,
/// batched transfer, auto-resume, import, report and history. Platform-neutral except for calls into
/// the ptp_platform adapter (Android Kotlin / iOS Swift).
library;

import 'dart:async';
import 'dart:io';

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
import '../core/session/identity.dart';
import '../core/session/session.dart';
import '../core/transfer/engine.dart';
import '../core/transfer/receiver_store.dart';
import '../data/db.dart';

const appVersion = '0.1.0';

/// A platform item opened for reading (Android fd path / iOS staged export).
class PlatformSource extends TransferSource {
  PlatformSource(this.item, this.opened, this.relPath);
  final SourceItem item;
  final OpenedItem opened;
  @override
  final String relPath;
  @override
  String get category => item.category;
  @override
  String? get mime => item.mime;

  /// Size from the live file, mtime from the platform (stable across re-exports, so resume works).
  @override
  Future<SourceStat> stat() async {
    final s = await File(opened.path).stat();
    if (s.type == FileSystemEntityType.notFound) throw PtpException(PtpErrorCode.fileChanged, 'source gone');
    return SourceStat(s.size, opened.mtimeMs ?? s.modified.millisecondsSinceEpoch);
  }

  @override
  Future<RandomAccessFile> open() => File(opened.path).open();

  @override
  Future<void> release() => PtpPlatform.closeRead(opened.token);
}

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

  final sm = MigrationStateMachine();
  String role = 'sender'; // this device's data role
  ProbeResult? probe;
  PtpHost? host;
  PtpChannel? channel;
  String? qrUri;
  DateTime? qrExpires;
  String? joinedUri; // kept for reconnect when this device scanned
  PtpException? error;
  bool reconnecting = false;
  String? deviceWarning;

  // Confirmation step
  String? pendingSas;
  DeviceInfo? pendingPeer;
  Completer<bool>? _confirm;

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
  CancelToken _cancel = CancelToken();
  final PauseGate pauseGate = PauseGate();
  bool userPaused = false;
  int? _sessionRow;
  Timer? _deviceTimer;
  Future<void> _importQueue = Future.value();
  ReceiverStore? _store;

  // Sender batches survive reconnects so the same transferIds are resumed.
  List<List<SourceItem>> _batches = [];
  final List<String> _batchIds = [];
  int _batchIndex = 0;

  MigrationState get state => sm.state;

  // ------------------------------------------------------------------ capabilities
  Future<Capabilities> _caps(String forRole) async {
    probe = await PtpPlatform.probe();
    final pr = probe!;
    return _capsCache = Capabilities(
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

  Future<bool> _confirmCb(String sas, DeviceInfo peer) {
    _go(MigrationState.pairing);
    _go(MigrationState.authenticating);
    pendingSas = sas;
    pendingPeer = peer;
    _confirm = Completer<bool>();
    notifyListeners();
    return _confirm!.future;
  }

  void answerConfirm(bool ok) {
    _confirm?.complete(ok);
    _confirm = null;
    pendingSas = null;
    notifyListeners();
  }

  void _go(MigrationState s) {
    if (sm.state != s && sm.canGo(s)) sm.go(s);
    notifyListeners();
  }

  // ------------------------------------------------------------------ pairing
  /// This device shows the QR. [myRole] is its data role.
  Future<void> showQr(String myRole) async {
    _resetSession(myRole);
    try {
      _go(MigrationState.discovering);
      final caps = await _caps(myRole);
      final id = await EphemeralIdentity.generate();
      final h = PtpHost(role: myRole, device: _device, confirm: _confirmCb, caps: caps, identity: id);
      await h.start();
      host = h;
      qrUri = h.qr.toUri();
      qrExpires = h.expiresAt;
      notifyListeners();
      final ch = await h.accept();
      await _onChannel(ch);
    } on PtpException catch (e) {
      _fail(e);
    }
  }

  /// This device scanned [uri]; its role is the opposite of the QR host's role.
  Future<void> joinQr(String uri) async {
    try {
      final qr = QrPayload.parse(uri);
      _resetSession(qr.hostRole == 'receiver' ? 'sender' : 'receiver');
      joinedUri = uri;
      _go(MigrationState.discovering);
      _go(MigrationState.pairing);
      await _caps(role);
      final ch = await joinSession(uri, device: _device, confirm: _confirmCb, capsForRole: (_) => _lastCaps!);
      await _onChannel(ch);
    } on PtpException catch (e) {
      _fail(e);
    }
  }

  Capabilities? get _lastCaps => _capsCache;
  Capabilities? _capsCache;

  Future<void> _onChannel(PtpChannel ch) async {
    channel = ch;
    _go(MigrationState.capabilityExchange);
    plan = ch.plan;
    _sessionRow ??= await db.startSession(role);
    if (role == 'sender') {
      _go(MigrationState.scanning);
      _go(MigrationState.preview);
    } else {
      _go(MigrationState.preparing);
      unawaited(_receiveLoop());
    }
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
    if (perm == 'granted' || perm == 'limited') {
      selection[category] = await PtpPlatform.scan(category);
    }
    notifyListeners();
  }

  void clearCategory(String category) {
    selection.remove(category);
    notifyListeners();
  }

  int get selectedCount => selection.values.fold(0, (a, l) => a + l.length);
  int get selectedBytesHint => selection.values.expand((l) => l).fold(0, (a, i) => a + i.sizeHint);

  /// Unique relPaths per category (two IMG_0001.HEIC from different years must not collide).
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
    progress
      ..totalFiles = items.length
      ..totalBytes = selectedBytesHint;
    _go(MigrationState.preparing);
    await PtpPlatform.setTransferActive(true);
    _startDeviceMonitor();
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

  Future<List<TransferSource>> _openBatch(List<SourceItem> batch) async {
    final seen = <String>{};
    final out = <TransferSource>[];
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
      if (it.sizeHint == 0) progress.totalBytes += opened.size; // iOS Photos/contacts: size known only now
      out.add(PlatformSource(it, opened, rel));
    }
    return out;
  }

  Future<void> _sendRemainingBatches() async {
    final ch = channel!;
    final started = DateTime.now();
    try {
      while (_batchIndex < _batches.length) {
        final sources = await _openBatch(_batches[_batchIndex]);
        if (sources.length < _batches[_batchIndex].length) {
          // iOS staging limit hit: push the rest into a new batch right after this one.
          final rest = _batches[_batchIndex].sublist(sources.length);
          _batches[_batchIndex] = _batches[_batchIndex].sublist(0, sources.length);
          _batches.insert(_batchIndex + 1, rest);
          _batchIds.insert(_batchIndex + 1, b64u(randomBytes(16)));
        }
        _go(MigrationState.transferring);
        final base = progress.doneBytes;
        final rep = await runSender(ch, sources,
            transferId: _batchIds[_batchIndex],
            more: _batchIndex < _batches.length - 1,
            cancel: _cancel,
            pause: pauseGate, onProgress: (i, done, total, wire) {
          progress
            ..current = sources[i].relPath
            ..doneBytes = base + wire
            ..mbps = wire / 1e6 / (DateTime.now().difference(started).inMilliseconds / 1000 + 1e-3);
          notifyListeners();
        });
        reports.add(rep);
        progress.doneFiles += rep.ok.length + rep.failed.length + rep.skipped.length;
        _batchIndex++;
      }
      await _finish();
    } on PtpException catch (e) {
      if (e.code.resumable) {
        await _reconnect();
      } else {
        _fail(e);
      }
    }
  }

  // ------------------------------------------------------------------ receiver
  Future<void> _receiveLoop() async {
    final inbox = await PtpPlatform.inboxDir();
    _store ??= ReceiverStore(inbox, SqliteCheckpointStore(db), PtpPlatform.freeBytes, reserve: storageReserve);
    await PtpPlatform.setTransferActive(true);
    _startDeviceMonitor();
    try {
      while (true) {
        final rep = await runReceiver(channel!, _store!, cancel: _cancel, approve: _approveCb,
            onProgress: (i, done, total, wire) {
          progress
            ..current = _store!.manifest.files[i].path
            ..doneBytes = wire;
          notifyListeners();
        });
        reports.add(rep);
        _queueImports(rep);
        if (!rep.more) break;
      }
      _go(MigrationState.importing);
      await _importQueue;
      await _finish();
    } on PtpException catch (e) {
      if (e.code.resumable) {
        await _reconnect();
      } else {
        _fail(e);
      }
    }
  }

  bool _approvedOnce = false;

  Future<bool> _approveCb(Manifest m, int needed) async {
    progress
      ..totalFiles += m.files.length
      ..totalBytes += m.totalBytes;
    if (_approvedOnce) {
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
    if (ok) _go(MigrationState.transferring);
    return ok;
  }

  void answerApprove(bool ok) {
    _approve?.complete(ok);
    _approve = null;
    notifyListeners();
  }

  /// Imports run in order, concurrently with receiving the next batch.
  void _queueImports(TransferReport rep) {
    final m = rep.manifest!;
    for (final e in rep.committedPaths.entries) {
      final entry = m.files[e.key];
      _importQueue = _importQueue.then((_) async {
        try {
          final r = await PtpPlatform.importFile(e.value, entry.category, p.basename(entry.path), entry.mime);
          imports.add(ImportOutcome(entry.category, entry.path, r.status, r.location, r.message));
        } catch (_) {
          imports.add(ImportOutcome(entry.category, entry.path, 'failed', null, 'import error'));
        }
        notifyListeners();
      });
    }
  }

  // ------------------------------------------------------------------ resume
  Future<void> _reconnect() async {
    reconnecting = true;
    _go(MigrationState.failed);
    notifyListeners();
    await channel?.close();
    final token = channel?.resumeToken;
    final deadline = DateTime.now().add(resumeWindow);
    try {
      PtpChannel? ch;
      if (host != null) {
        host!.release();
        ch = await host!.accept().timeout(resumeWindow);
      } else {
        while (ch == null) {
          if (_cancel.isCancelled || DateTime.now().isAfter(deadline)) {
            throw PtpException(PtpErrorCode.peerTimeout, 'resume window elapsed');
          }
          try {
            ch = await joinSession(joinedUri!,
                device: _device, confirm: _confirmCb, capsForRole: (_) => _lastCaps!, resumeToken: token);
          } on PtpException catch (e) {
            if (e.code != PtpErrorCode.peerTimeout && e.code != PtpErrorCode.sessionBusy) rethrow;
            await Future<void>.delayed(const Duration(seconds: 3));
          }
        }
      }
      channel = ch;
      reconnecting = false;
      _go(MigrationState.pairing);
      _go(MigrationState.authenticating);
      _go(MigrationState.capabilityExchange);
      _go(MigrationState.preparing);
      if (role == 'sender') {
        await _sendRemainingBatches();
      } else {
        await _receiveLoop();
      }
    } on TimeoutException {
      reconnecting = false;
      _fail(PtpException(PtpErrorCode.peerTimeout, 'resume window elapsed'));
    } on PtpException catch (e) {
      reconnecting = false;
      _fail(e);
    }
  }

  // ------------------------------------------------------------------ pause / cancel / device state
  void togglePause() {
    userPaused = !userPaused;
    if (userPaused) {
      pauseGate.pause();
    } else {
      pauseGate.resume();
    }
    notifyListeners();
  }

  Future<void> cancel() async {
    _cancel.cancel();
    _confirm?.complete(false);
    _approve?.complete(false);
    if (!sm.state.isTerminal) _go(MigrationState.cancelled);
    await _teardown();
    await _record('cancelled', PtpErrorCode.userCancelled);
    notifyListeners();
  }

  Future<void> deletePartials() async {
    await _store?.deletePartials();
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
        deviceWarning = hot ? 'thermal_pause' : (low ? 'battery_low' : null);
        if (hot && !pauseGate.isPaused) pauseGate.pause();
        if (!hot && pauseGate.isPaused && !userPaused) pauseGate.resume();
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
    if (!sm.state.isTerminal) {
      _go(e.code == PtpErrorCode.userCancelled ? MigrationState.cancelled : MigrationState.failed);
    }
    unawaited(_teardown());
    unawaited(_record(sm.state.name, e.code));
    notifyListeners();
  }

  Future<void> _teardown() async {
    _deviceTimer?.cancel();
    try {
      await PtpPlatform.setTransferActive(false);
    } catch (_) {}
    await channel?.close();
    await host?.close();
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
        peerPlatform: channel?.peer.platform,
        errorCode: code?.wire,
        ok: okCount,
        failed: failedCount,
        skipped: skippedCount,
        bytes: reports.fold(0, (a, r) => a + r.wireBytes),
        durationMs: reports.fold(0, (a, r) => a + r.elapsed.inMilliseconds),
        categories: cats);
  }

  void _resetSession(String myRole) {
    role = myRole;
    sm.reset();
    error = null;
    host = null;
    channel = null;
    qrUri = null;
    joinedUri = null;
    reconnecting = false;
    selection.clear();
    permission.clear();
    reports.clear();
    imports.clear();
    _batches = [];
    _batchIds.clear();
    _batchIndex = 0;
    _approvedOnce = false;
    _sessionRow = null;
    _store = null;
    _cancel = CancelToken();
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
