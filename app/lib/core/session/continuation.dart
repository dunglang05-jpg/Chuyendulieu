/// Audit P1-10: continuing an unfinished transfer after the app was killed or the phone restarted.
///
/// What is NOT done: no TLS session, ephemeral key or resume token is ever restored from disk. After a restart the
/// two phones pair again exactly like the first time (new QR, new certificate, 6-digit code confirmed by the user).
///
/// What is added: during the first pairing both phones derive a 32-byte continuation key K from fresh random
/// contributions of both sides, bound to that session. K is kept only in Android Keystore / iOS Keychain
/// (see SecureVault). After a new pairing, each phone proves knowledge of K with an HMAC bound to the NEW session
/// (its fresh nonces), so an old proof cannot be replayed, and both phones must confirm the same continuation id
/// before any partial data or sender plan is reused. If they disagree, nothing is continued: the transfer restarts
/// cleanly. Checkpoints written under a continuation are MAC'd with K (receiver_store.dart), so a forged or
/// corrupted checkpoint is ignored instead of trusted.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import '../protocol/codec.dart';
import '../protocol/errors.dart';
import 'session.dart';

/// Capability feature flag advertised by peers that implement this exchange.
const continuationFeature = 'cont1';

/// How long an unfinished transfer can be continued.
const continuationTtl = Duration(hours: 24);

const _maxOffers = 4;
final _offerLabel = utf8.encode('ptp1/cont/offer');
final _okLabel = utf8.encode('ptp1/cont/ok');
final _keyLabel = utf8.encode('ptp1/cont/key');
final _idLabel = utf8.encode('ptp1/cont/id');
final _bindingLabel = utf8.encode('ptp1/binding');

/// Value both ends of ONE session share and nobody can choose alone: hash of the session id, the pinned
/// certificate and both handshake nonces. Proofs are bound to it, which is what makes them unreplayable.
Uint8List sessionBinding(List<int> sid, List<int> fp, List<int> nonceJ, List<int> nonceH) =>
    Uint8List.fromList(hash.sha256.convert([..._bindingLabel, ...sid, ...fp, ...nonceJ, ...nonceH]).bytes);

/// Proof that [role] knows [key], bound to this session's [binding].
Uint8List continuationProof(List<int> key, List<int> label, String role, List<int> binding) =>
    hmacSha256(key, [label, utf8.encode(role), binding]);

/// One unfinished transfer, as this phone remembers it. [key] lives in the secure vault, never in this JSON.
class ContinuationRecord {
  ContinuationRecord({
    required this.id,
    required this.key,
    required this.role,
    required this.peerName,
    required this.peerPlatform,
    required this.createdAt,
    List<String>? transferIds,
    this.plan,
  }) : transferIds = transferIds ?? <String>[];

  final String id; // public, 16 bytes b64url
  final Uint8List key; // 32 bytes, secret
  final String role; // this phone's data role in that transfer
  final String peerName;
  final String peerPlatform;
  final DateTime createdAt;

  /// Receiver: batches whose partial data may be continued. Sender: batches it created, in order.
  final List<String> transferIds;

  /// Sender only: what was selected, so the rest can be sent without choosing again.
  /// {'batches': [[SourceItem.raw…]…], 'index': next batch}
  Map<String, Object?>? plan;

  bool expired(DateTime now) => now.isAfter(createdAt.add(continuationTtl));

  Map<String, Object?> toJson() => {
        'v': 1,
        'id': id,
        'role': role,
        'peerName': peerName,
        'peerPlatform': peerPlatform,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'transferIds': transferIds,
        'plan': plan,
      };

  /// [key] comes from the vault; the JSON's MAC is checked by the caller (ContinuationRepo).
  static ContinuationRecord fromJson(Map<String, Object?> j, Uint8List key) {
    if (j['v'] != 1 || j['id'] is! String || j['role'] is! String || j['createdAt'] is! String) {
      throw const FormatException('continuation record');
    }
    return ContinuationRecord(
      id: j['id'] as String,
      key: key,
      role: j['role'] as String,
      peerName: (j['peerName'] as String?) ?? '?',
      peerPlatform: (j['peerPlatform'] as String?) ?? '?',
      createdAt: DateTime.parse(j['createdAt'] as String),
      transferIds: ((j['transferIds'] as List<Object?>?) ?? const []).whereType<String>().toList(),
      plan: (j['plan'] as Map?)?.cast<String, Object?>(),
    );
  }
}

/// Result of the exchange: the record to use from now on, and whether it continues an earlier transfer.
class ContinuationOutcome {
  ContinuationOutcome(this.record, {required this.continued});
  final ContinuationRecord record;
  final bool continued;
}

/// Runs right after a NEW pairing (not after an in-session resume), only when both peers advertise
/// [continuationFeature]. Both phones send the same two messages; neither waits on the other first.
///
/// Returns the agreed earlier record (continued = true) only if BOTH phones verified each other's proof for the
/// same id. Otherwise returns a fresh record whose key both phones derived identically for this session.
Future<ContinuationOutcome> negotiateContinuation(
  PtpChannel ch,
  List<ContinuationRecord> candidates, {
  DateTime? now,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final at = now ?? DateTime.now();
  final role = ch.role;
  final peerRole = role == 'sender' ? 'receiver' : 'sender';
  final binding = ch.binding;
  final mine = [
    for (final r in candidates)
      if (r.role == role && !r.expired(at) && r.key.length == 32) r
  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final offered = mine.take(_maxOffers).toList();
  final nonce = randomBytes(32);

  await ch.writer.control({
    't': 'cont',
    'n': b64u(nonce),
    'offers': [
      for (final r in offered) {'id': r.id, 'proof': b64u(continuationProof(r.key, _offerLabel, role, binding))}
    ],
  });
  final peer = await ch.reader.expect('cont', timeout: timeout);
  final peerNonce = unb64u(peer['n'], length: 32);
  final peerOffers = peer['offers'];
  if (peerOffers is! List || peerOffers.length > _maxOffers) {
    throw PtpException(PtpErrorCode.protocolError, 'cont offers');
  }

  // Ids the peer proved it holds the key for, among the ones this phone offered too.
  final verified = <String>[];
  for (final o in peerOffers) {
    if (o is! Map || o['id'] is! String) throw PtpException(PtpErrorCode.protocolError, 'cont offer');
    final r = offered.where((x) => x.id == o['id']).firstOrNull;
    if (r == null) continue;
    final proof = unb64u(o['proof'], length: 32);
    if (constantTimeEquals(proof, continuationProof(r.key, _offerLabel, peerRole, binding))) verified.add(r.id);
  }
  verified.sort();
  final choice = verified.isEmpty ? null : verified.first;
  final chosen = choice == null ? null : offered.firstWhere((x) => x.id == choice);

  // Second round: each side states its choice and proves it again; continue only if both chose the same id.
  await ch.writer.control({
    't': 'cont_ok',
    'id': choice,
    'proof': chosen == null ? null : b64u(continuationProof(chosen.key, _okLabel, role, binding)),
  });
  final ok = await ch.reader.expect('cont_ok', timeout: timeout);
  final agreed = chosen != null &&
      ok['id'] == choice &&
      ok['proof'] is String &&
      constantTimeEquals(unb64u(ok['proof'], length: 32), continuationProof(chosen.key, _okLabel, peerRole, binding));
  if (agreed) return ContinuationOutcome(chosen, continued: true);

  // Fresh key for this session: both contributions, sender's first, bound to the session.
  final senderNonce = role == 'sender' ? nonce : peerNonce;
  final receiverNonce = role == 'sender' ? peerNonce : nonce;
  final key = hmacSha256([...senderNonce, ...receiverNonce], [_keyLabel, binding]);
  final id = b64u(hmacSha256(key, [_idLabel]).sublist(0, 16));
  return ContinuationOutcome(
    ContinuationRecord(
      id: id,
      key: key,
      role: role,
      peerName: ch.peer.name,
      peerPlatform: ch.peer.platform,
      createdAt: at,
    ),
    continued: false,
  );
}

/// MAC over a JSON document with the continuation key (records on disk, checkpoints).
String macJson(List<int> key, Map<String, Object?> body) =>
    b64u(hmacSha256(key, [utf8.encode('ptp1/mac'), utf8.encode(jsonEncode(body))]));

bool checkMacJson(List<int> key, Map<String, Object?> body, Object? mac) {
  if (mac is! String) return false;
  try {
    return constantTimeEquals(unb64u(mac, length: 32), unb64u(macJson(key, body), length: 32));
  } on PtpException {
    return false;
  }
}
