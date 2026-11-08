/// PTP/1 pairing (host shows QR, joiner scans), mutual confirmation and capability exchange.
/// Mirrors tools/reference_peer/ptp_ref/session.py; both must stay conformant to docs/PROTOCOL_v1.md.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import '../domain/capabilities.dart';
import '../protocol/codec.dart';
import '../protocol/constants.dart';
import '../protocol/errors.dart';
import '../protocol/framing.dart';
import '../protocol/qr_payload.dart';
import 'identity.dart';

class DeviceInfo {
  const DeviceInfo(this.name, this.platform, this.model);
  final String name; // user-visible label, shown to the peer only after TLS is up (never in the QR)
  final String platform;
  final String model;

  Map<String, String> toJson() => {
        'name': name.length > 64 ? name.substring(0, 64) : name,
        'platform': platform,
        'model': model.length > 32 ? model.substring(0, 32) : model,
      };

  static DeviceInfo fromJson(Object? j) {
    if (j is! Map) return const DeviceInfo('?', '?', '?');
    String s(Object? v) => v is String ? v : '?';
    return DeviceInfo(s(j['name']), s(j['platform']), s(j['model']));
  }
}

/// Shows the 6-digit code and the peer's name; returns true only if the user accepts.
typedef ConfirmCallback = Future<bool> Function(String sas, DeviceInfo peer);

class PtpChannel {
  PtpChannel(this.socket, this.reader, this.writer,
      {required this.role, required this.sas, required this.peer, required this.resumeToken, required this.resumed});

  final Socket socket;
  final FrameReader reader;
  final FrameWriter writer;
  final String role; // data role of THIS device: sender | receiver
  final String sas;
  final DeviceInfo peer;
  final Uint8List resumeToken;
  final bool resumed;
  late Capabilities localCaps;
  late Capabilities peerCaps;

  Set<String> get plan => role == 'sender' ? migrationPlan(localCaps, peerCaps) : migrationPlan(peerCaps, localCaps);

  Future<void> close() async {
    try {
      await reader.cancel().timeout(const Duration(seconds: 2));
      await socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    socket.destroy();
  }
}

Future<void> _mutualConfirm(FrameReader r, FrameWriter w, ConfirmCallback cb, String sas, DeviceInfo peer) async {
  bool accepted;
  try {
    accepted = await cb(sas, peer).timeout(confirmTimeout);
  } on TimeoutException {
    throw PtpException(PtpErrorCode.peerTimeout, 'local confirmation timed out');
  }
  await w.control({'t': 'confirm', 'accepted': accepted});
  if (!accepted) throw PtpException(PtpErrorCode.userCancelled, 'pairing rejected locally');
  final msg = await r.expect('confirm', timeout: confirmTimeout);
  if (msg['accepted'] != true) throw PtpException(PtpErrorCode.userCancelled, 'pairing rejected by peer');
}

Future<void> _exchangeCaps(PtpChannel ch, Capabilities caps) async {
  ch.localCaps = caps;
  await ch.writer.control({'t': 'caps', 'caps': caps.toJson()});
  ch.peerCaps = Capabilities.fromJson((await ch.reader.expect('caps'))['caps']);
}

/// Device that shows the QR code and runs the TLS server.
class PtpHost {
  PtpHost({required this.role, required this.device, required this.confirm, required this.caps, required this.identity})
      : sid = randomBytes(16),
        expiresAt = DateTime.now().add(qrTtl);

  final String role;
  final DeviceInfo device;
  ConfirmCallback confirm;
  final Capabilities caps;
  final EphemeralIdentity identity;
  final Uint8List sid;
  DateTime expiresAt;

  Uint8List? resumeToken;
  DateTime lastActivity = DateTime.now();
  bool pairedOnce = false;
  bool active = false;
  bool destroyed = false;
  int failures = 0;
  SecureServerSocket? _server;
  final _channels = StreamController<Object>();
  StreamIterator<Object>? _chIt;
  List<String> endpoints = const [];

  /// Bind on all interfaces; endpoints advertise private IPv4/IPv6 addresses of Wi-Fi / hotspot interfaces.
  Future<void> start({int port = 0}) async {
    _server = await SecureServerSocket.bind(InternetAddress.anyIPv4, port, identity.serverContext());
    _server!.listen(_handle, onError: (Object _) {});
    endpoints = await localEndpoints(_server!.port);
    _chIt = StreamIterator(_channels.stream);
  }

  int get port => _server!.port;

  QrPayload get qr => QrPayload(
        version: protocolVersion,
        sid: sid,
        expiresAt: expiresAt.millisecondsSinceEpoch ~/ 1000,
        endpoints: endpoints,
        fingerprint: identity.fingerprint,
        hostRole: role,
        platform: device.platform,
      );

  /// Waits for the next authenticated channel (first pairing or a resume).
  Future<PtpChannel> accept() async {
    if (!await _chIt!.moveNext()) throw PtpException(PtpErrorCode.pairingExpired, 'session closed');
    final item = _chIt!.current;
    if (item is PtpException) throw item;
    return item as PtpChannel;
  }

  void release() {
    active = false;
    lastActivity = DateTime.now();
  }

  /// Never waits on listeners: awaiting StreamController.close() while the StreamIterator is paused
  /// between moveNext() calls hangs forever (found by CI).
  Future<void> close() async {
    destroyed = true;
    try {
      await _server?.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (!_channels.isClosed) unawaited(_channels.close());
    unawaited(_chIt?.cancel());
  }

  Future<void> _handle(SecureSocket socket) async {
    final reader = FrameReader(socket);
    final writer = FrameWriter(socket);
    try {
      final ch = await _handshake(socket, reader, writer);
      if (!_channels.isClosed) _channels.add(ch);
    } on PtpException catch (e) {
      await writer.error(e.code, e.message);
      socket.destroy();
      if (e.code == PtpErrorCode.userCancelled && !_channels.isClosed) _channels.add(e);
    } catch (_) {
      socket.destroy();
    }
  }

  Future<PtpChannel> _handshake(SecureSocket socket, FrameReader reader, FrameWriter writer) async {
    if (destroyed) throw PtpException(PtpErrorCode.pairingExpired, 'session closed');
    final hello = await reader.expect('hello');
    final versions = hello['versions'];
    if (versions is! List || !versions.contains(protocolVersion)) {
      throw PtpException(PtpErrorCode.protocolVersionMismatch, 'no common protocol version');
    }
    final nonceJ = unb64u(hello['nonce'], length: 16);
    final fp = identity.fingerprint;
    final resume = hello['resume'];
    if (active) throw PtpException(PtpErrorCode.sessionBusy, 'another peer is connected');
    bool ok;
    if (resume != null) {
      ok = resume is Map &&
          resumeToken != null &&
          DateTime.now().difference(lastActivity) <= resumeWindow &&
          constantTimeEquals(unb64u(resume['proof'], length: 32), resumeProof(resumeToken!, fp, nonceJ));
    } else {
      if (DateTime.now().isAfter(expiresAt)) throw PtpException(PtpErrorCode.pairingExpired, 'QR code expired');
      if (pairedOnce) throw PtpException(PtpErrorCode.authenticationFailed, 'session already used');
      ok = constantTimeEquals(unb64u(hello['proof'], length: 32), pairingProof(sid, fp, nonceJ));
    }
    if (!ok) {
      failures++;
      if (failures >= maxAuthFailures) {
        destroyed = true; // rate limit: this QR is dead
        unawaited(_server?.close());
      }
      throw PtpException(PtpErrorCode.authenticationFailed, 'bad proof');
    }
    active = true;
    try {
      final nonceH = randomBytes(16);
      await writer.control({'t': 'welcome', 'version': protocolVersion, 'nonce': b64u(nonceH), 'device': device.toJson()});
      final peer = DeviceInfo.fromJson(hello['device']);
      final sas = sasCode(sid, fp, nonceJ, nonceH);
      if (resume == null) {
        await _mutualConfirm(reader, writer, confirm, sas, peer);
        resumeToken = randomBytes(32);
        pairedOnce = true;
      }
      await writer.control({'t': 'paired', 'resumeToken': b64u(resumeToken!), 'resumed': resume != null});
      final ch = PtpChannel(socket, reader, writer,
          role: role, sas: sas, peer: peer, resumeToken: resumeToken!, resumed: resume != null);
      await _exchangeCaps(ch, caps);
      lastActivity = DateTime.now();
      return ch;
    } catch (_) {
      active = false;
      rethrow;
    }
  }
}

/// Joiner: scans the QR, connects, pins the certificate fingerprint, proves knowledge of the session id.
Future<PtpChannel> joinSession(
  String uri, {
  required DeviceInfo device,
  required ConfirmCallback confirm,
  required Capabilities Function(String role) capsForRole,
  Uint8List? resumeToken,
  Duration connectTimeout = const Duration(seconds: 5),
}) async {
  final qr = QrPayload.parse(uri, ignoreExpiry: resumeToken != null);
  final role = qr.hostRole == 'receiver' ? 'sender' : 'receiver';
  PtpException last = PtpException(PtpErrorCode.peerTimeout, 'no endpoint reachable');
  for (final ep in qr.endpoints.map(Endpoint.parse)) {
    SecureSocket socket;
    try {
      socket = await SecureSocket.connect(
        ep.address,
        ep.port,
        timeout: connectTimeout,
        // Self-signed by design: accept ONLY the certificate whose SHA-256 matches the QR.
        onBadCertificate: (cert) => constantTimeEquals(hash.sha256.convert(cert.der).bytes, qr.fingerprint),
      );
    } on SocketException catch (e) {
      last = PtpException(PtpErrorCode.peerTimeout, 'connect failed: ${e.osError?.errorCode ?? ''}');
      continue;
    } on HandshakeException {
      throw PtpException(PtpErrorCode.authenticationFailed, 'host certificate does not match QR fingerprint');
    }
    // Defence in depth: re-check the pin after the handshake as well.
    final der = socket.peerCertificate?.der;
    if (der == null || !constantTimeEquals(hash.sha256.convert(der).bytes, qr.fingerprint)) {
      socket.destroy();
      throw PtpException(PtpErrorCode.authenticationFailed, 'host certificate does not match QR fingerprint');
    }
    final reader = FrameReader(socket);
    final writer = FrameWriter(socket);
    try {
      final nonceJ = randomBytes(16);
      final hello = <String, Object?>{
        't': 'hello',
        'versions': supportedVersions,
        'nonce': b64u(nonceJ),
        'device': device.toJson(),
      };
      if (resumeToken != null) {
        hello['resume'] = {'proof': b64u(resumeProof(resumeToken, qr.fingerprint, nonceJ))};
      } else {
        hello['proof'] = b64u(pairingProof(qr.sid, qr.fingerprint, nonceJ));
      }
      await writer.control(hello);
      final welcome = await reader.expect('welcome');
      if (!supportedVersions.contains(welcome['version'])) {
        throw PtpException(PtpErrorCode.protocolVersionMismatch, 'host chose unsupported version');
      }
      final nonceH = unb64u(welcome['nonce'], length: 16);
      final sas = sasCode(qr.sid, qr.fingerprint, nonceJ, nonceH);
      final peer = DeviceInfo.fromJson(welcome['device']);
      if (resumeToken == null) await _mutualConfirm(reader, writer, confirm, sas, peer);
      final paired = await reader.expect('paired', timeout: confirmTimeout);
      final token = unb64u(paired['resumeToken'], length: 32);
      final ch = PtpChannel(socket, reader, writer,
          role: role, sas: sas, peer: peer, resumeToken: token, resumed: resumeToken != null);
      await _exchangeCaps(ch, capsForRole(role));
      return ch;
    } on PtpException catch (e) {
      await writer.error(e.code, e.message);
      socket.destroy();
      rethrow;
    }
  }
  throw last;
}

/// Private (RFC 1918 / link-local / ULA) addresses of up interfaces, e.g. Wi-Fi or hotspot.
Future<List<String>> localEndpoints(int port) async {
  final out = <String>[];
  final ifaces = await NetworkInterface.list(includeLinkLocal: false, type: InternetAddressType.IPv4);
  for (final i in ifaces) {
    for (final a in i.addresses) {
      final b = a.rawAddress;
      final private = b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
      if (private && !a.isLoopback) out.add('${a.address}:$port');
    }
  }
  if (out.isEmpty) out.add('127.0.0.1:$port'); // tests / no Wi-Fi: UI warns the user
  return out.take(8).toList();
}
