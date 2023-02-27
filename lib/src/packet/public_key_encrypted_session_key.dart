// Copyright 2022-present by Nguyen Van Nguyen <nguyennv1981@gmail.com>. All rights reserved.
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.

import 'dart:typed_data';

import 'package:pointycastle/pointycastle.dart';

import '../crypto/asymmetric/elgamal.dart';
import '../enums.dart';
import '../helpers.dart';
import '../openpgp.dart';
import 'contained_packet.dart';
import 'key/key_id.dart';
import 'key/key_params.dart';
import 'key/session_key.dart';
import 'key/session_key_params.dart';
import 'key_packet.dart';

/// PublicKeyEncryptedSessionKey represents a Public-Key Encrypted Session Key packet.
///
/// See RFC 4880, section 5.1.
/// A Public-Key Encrypted Session Key packet holds the session key used to encrypt a message.
/// Zero or more Public-Key Encrypted Session Key packets and/or Symmetric-Key Encrypted Session Key
/// packets may precede a Symmetrically Encrypted Data Packet, which holds an encrypted message.
/// The message is encrypted with the session key, and the session key is itself
/// encrypted and stored in the Encrypted Session Key packet(s).
/// The Symmetrically Encrypted Data Packet is preceded by one Public-Key Encrypted
/// Session Key packet for each OpenPGP key to which the message is encrypted.
/// The recipient of the message finds a session key that is encrypted to their public key,
/// decrypts the session key, and then uses the session key to decrypt the message.
class PublicKeyEncryptedSessionKeyPacket extends ContainedPacket {
  static const version = OpenPGP.pkeskVersion;

  final KeyID publicKeyID;

  final KeyAlgorithm publicKeyAlgorithm;

  /// Encrypted session key params
  final SessionKeyParams sessionKeyParams;

  /// Session key
  final SessionKey? sessionKey;

  PublicKeyEncryptedSessionKeyPacket(
    this.publicKeyID,
    this.publicKeyAlgorithm,
    this.sessionKeyParams, {
    this.sessionKey,
  }) : super(PacketTag.publicKeyEncryptedSessionKey);

  factory PublicKeyEncryptedSessionKeyPacket.fromPacketData(final Uint8List bytes) {
    var pos = 0;
    final version = bytes[pos++];
    if (version != OpenPGP.pkeskVersion) {
      throw UnsupportedError('Version $version of the PKESK packet is unsupported.');
    }

    final keyID = bytes.sublist(pos, pos + 8);
    pos += 8;

    final keyAlgorithm = KeyAlgorithm.values.firstWhere((algo) => algo.value == bytes[pos]);
    pos++;

    final SessionKeyParams params;
    switch (keyAlgorithm) {
      case KeyAlgorithm.rsaEncryptSign:
      case KeyAlgorithm.rsaEncrypt:
        params = RSASessionKeyParams.fromPacketData(bytes.sublist(pos));
        break;
      case KeyAlgorithm.elgamal:
        params = ElGamalSessionKeyParams.fromPacketData(bytes.sublist(pos));
        break;
      case KeyAlgorithm.ecdh:
        params = ECDHSessionKeyParams.fromPacketData(bytes.sublist(pos));
        break;
      default:
        throw UnsupportedError('Unsupported PGP public key algorithm encountered');
    }

    return PublicKeyEncryptedSessionKeyPacket(
      KeyID(keyID),
      keyAlgorithm,
      params,
    );
  }

  factory PublicKeyEncryptedSessionKeyPacket.encryptSessionKey(
    final PublicKeyPacket key, {
    final SymmetricAlgorithm sessionKeySymmetric = OpenPGP.preferredSymmetric,
  }) {
    final sessionKey = SessionKey(Helper.generateSessionKey(sessionKeySymmetric), sessionKeySymmetric);
    final SessionKeyParams params;
    switch (key.algorithm) {
      case KeyAlgorithm.rsaEncryptSign:
      case KeyAlgorithm.rsaEncrypt:
        final publicKey = (key.publicParams as RSAPublicParams).publicKey;
        params = RSASessionKeyParams.encryptSessionKey(publicKey, sessionKey);
        break;
      case KeyAlgorithm.elgamal:
        final publicKey = (key.publicParams as ElGamalPublicParams).publicKey;
        params = ElGamalSessionKeyParams.encryptSessionKey(publicKey, sessionKey);
        break;
      case KeyAlgorithm.ecdh:
        params = ECDHSessionKeyParams.encryptSessionKey(
          (key.publicParams as ECDHPublicParams),
          sessionKey,
          key.fingerprint.hexToBytes(),
        );
        break;
      default:
        throw UnsupportedError('Unsupported PGP public key algorithm encountered');
    }
    return PublicKeyEncryptedSessionKeyPacket(
      key.keyID,
      key.algorithm,
      params,
      sessionKey: sessionKey,
    );
  }

  @override
  Uint8List toPacketData() {
    return Uint8List.fromList([
      version,
      ...publicKeyID.id,
      publicKeyAlgorithm.value,
      ...sessionKeyParams.encode(),
    ]);
  }

  PublicKeyEncryptedSessionKeyPacket decrypt(final SecretKeyPacket key) {
    // check that session key algo matches the secret key algo
    if (publicKeyAlgorithm == key.algorithm) {
      throw StateError('PKESK decryption error');
    }

    // final Uint8List decoded;
    final SessionKey? sessionKey;
    switch (key.algorithm) {
      case KeyAlgorithm.rsaEncryptSign:
      case KeyAlgorithm.rsaEncrypt:
        final privateKey = (key.secretParams as RSASecretParams).privateKey;
        sessionKey = (sessionKeyParams as RSASessionKeyParams).decrypt(privateKey);
        break;
      case KeyAlgorithm.elgamal:
        final publicKey = (key.publicParams as ElGamalPublicParams).publicKey;
        final secretExponent = (key.secretParams as ElGamalSecretParams).secretExponent;
        sessionKey = (sessionKeyParams as ElGamalSessionKeyParams).decrypt(
          ElGamalPrivateKey(secretExponent, publicKey.prime, publicKey.generator),
        );
        break;
      case KeyAlgorithm.ecdh:
        final publicParams = key.publicParams as ECDHPublicParams;
        final privateKey = ECPrivateKey(
          (key.secretParams as ECSecretParams).d,
          publicParams.publicKey.parameters,
        );
        sessionKey =
            (sessionKeyParams as ECDHSessionKeyParams).decrypt(privateKey, publicParams, key.fingerprint.hexToBytes());
        break;
      default:
        throw UnsupportedError('Unsupported PGP public key algorithm encountered');
    }

    return PublicKeyEncryptedSessionKeyPacket(
      publicKeyID,
      publicKeyAlgorithm,
      sessionKeyParams,
      sessionKey: sessionKey,
    );
  }
}
