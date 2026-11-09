/// Ephemeral per-session TLS identity: ECDSA P-256 key + self-signed certificate.
/// The joiner trusts it only through the SHA-256 fingerprint carried in the QR code.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as hash;

import '../protocol/codec.dart';

class EphemeralIdentity {
  EphemeralIdentity(this.certPem, this.keyPem, this.certDer);
  final String certPem;
  final String keyPem; // keep in memory / app-private storage only; never log
  final Uint8List certDer;

  Uint8List get fingerprint => Uint8List.fromList(hash.sha256.convert(certDer).bytes);

  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  Map<String, String> toJson() => {'cert': certPem, 'key': keyPem};

  static EphemeralIdentity fromJson(Map<String, dynamic> j) {
    final cert = j['cert'] as String;
    return EphemeralIdentity(cert, j['key'] as String, CryptoUtils.getBytesFromPEMString(cert));
  }

  /// Key generation is pure Dart; run it off the UI isolate.
  static Future<EphemeralIdentity> generate() => Isolate.run(_generateSync);

  static EphemeralIdentity _generateSync() {
    final pair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem({'CN': 'ptp-ephemeral'}, priv, pub);
    final serial = BigInt.parse(randomBytes(15).map((b) => b.toRadixString(16).padLeft(2, '0')).join(), radix: 16);
    final certPem = X509Utils.generateSelfSignedCertificate(priv, csr, 2, serialNumber: serial.toString());
    final keyPem = CryptoUtils.encodeEcPrivateKeyToPem(priv);
    return EphemeralIdentity(certPem, keyPem, CryptoUtils.getBytesFromPEMString(certPem));
  }
}
