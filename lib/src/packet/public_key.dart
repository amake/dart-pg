// Copyright 2022-present by Nguyen Van Nguyen <nguyennv1981@gmail.com>. All rights reserved.
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.

import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../enums.dart';
import '../helpers.dart';
import '../key/dsa_public_params.dart';
import '../key/ec_public_params.dart';
import '../key/ecdh_public_params.dart';
import '../key/ecdsa_public_params.dart';
import '../key/elgamal_public_params.dart';
import '../key/key_id.dart';
import '../key/key_params.dart';
import '../key/rsa_public_params.dart';
import 'contained_packet.dart';
import 'key_packet.dart';

/// PublicKey represents an OpenPGP public key.
/// See RFC 4880, section 5.5.2.
class PublicKeyPacket extends ContainedPacket implements KeyPacket {
  @override
  final int version;

  @override
  final DateTime creationTime;

  @override
  final int expirationDays;

  @override
  final KeyAlgorithm algorithm;

  final KeyParams publicParams;

  late final Uint8List _fingerprint;

  late final KeyID _keyID;

  PublicKeyPacket(
    this.version,
    this.creationTime,
    this.publicParams, {
    this.expirationDays = 0,
    this.algorithm = KeyAlgorithm.rsaEncryptSign,
    super.tag = PacketTag.publicKey,
  }) {
    _calculateFingerprintAndKeyID();
  }

  factory PublicKeyPacket.fromPacketData(final Uint8List bytes) {
    var pos = 0;

    /// A one-octet version number (3, 4 or 5).
    final version = bytes[pos++];

    /// A four-octet number denoting the time that the key was created.
    final creationTime = bytes.sublist(pos, pos + 4).toDateTime();
    pos += 4;

    /// A two-octet number denoting the time in days that this key is valid.
    /// If this number is zero, then it does not expire.
    final expirationDays = (version == 3) ? bytes.sublist(pos, pos + 2).toIn16() : 0;
    if (version == 3) {
      pos += 2;
    }

    // A one-octet number denoting the public-key algorithm of this key.
    final algorithm = KeyAlgorithm.values.firstWhere((algo) => algo.value == bytes[pos]);
    pos++;
    if (version == 5) {
      /// - A four-octet scalar octet count for the following key material.
      pos += 4;
    }

    /// A series of values comprising the key material.
    /// This is algorithm-specific and described in section XXXX.
    final KeyParams publicParams;
    switch (algorithm) {
      case KeyAlgorithm.rsaEncryptSign:
      case KeyAlgorithm.rsaEncrypt:
      case KeyAlgorithm.rsaSign:
        publicParams = RSAPublicParams.fromPacketData(bytes.sublist(pos));
        break;
      case KeyAlgorithm.elgamal:
        publicParams = ElGamalPublicParams.fromPacketData(bytes.sublist(pos));
        break;
      case KeyAlgorithm.dsa:
        publicParams = DSAPublicParams.fromPacketData(bytes.sublist(pos));
        break;
      case KeyAlgorithm.ecdh:
        publicParams = ECDHPublicParams.fromPacketData(bytes.sublist(pos));
        break;
      case KeyAlgorithm.ecdsa:
        publicParams = ECDSAPublicParams.fromPacketData(bytes.sublist(pos));
        break;
      default:
        throw UnsupportedError('Unknown PGP public key algorithm encountered');
    }
    return PublicKeyPacket(
      version,
      creationTime,
      publicParams,
      expirationDays: expirationDays,
      algorithm: algorithm,
    );
  }

  /// Computes and set the fingerprint of the key
  void _calculateFingerprintAndKeyID() {
    if (version <= 3) {
      final pk = publicParams as RSAPublicParams;
      final bytes = pk.modulus!.toBytes();
      _fingerprint = Uint8List.fromList(md5.convert([...bytes, ...pk.publicExponent!.toBytes()]).bytes);
      _keyID = KeyID(bytes.sublist(bytes.length - 8));
    } else {
      final bytes = toPacketData();
      if (version == 4) {
        _fingerprint = Uint8List.fromList(sha1.convert([0x99, ...bytes.length.pack16(), ...bytes]).bytes);
        _keyID = KeyID(_fingerprint.sublist(12, 20));
      } else {
        _fingerprint = Uint8List.fromList(sha256.convert([0x9A, ...bytes.length.pack32(), ...bytes]).bytes);
        _keyID = KeyID(_fingerprint.sublist(0, 8));
      }
    }
  }

  @override
  String get fingerprint => _fingerprint.toHexadecimal();

  @override
  KeyID get keyID => _keyID;

  @override
  int get keyStrength {
    final keyParams = publicParams;
    if (keyParams is RSAPublicParams) {
      return keyParams.modulus!.bitLength;
    }
    if (keyParams is DSAPublicParams) {
      return keyParams.primeP.bitLength;
    }
    if (keyParams is ElGamalPublicParams) {
      return keyParams.primeP.bitLength;
    }
    if (keyParams is ECPublicParams) {
      return keyParams.publicKey.parameters!.curve.fieldSize;
    }
    return -1;
  }

  @override
  Uint8List toPacketData() {
    final keyData = publicParams.encode();
    final List<int> bytes;
    if (version <= 3) {
      bytes = [
        version,
        ...creationTime.toBytes(),
        ...expirationDays.pack16(),
        algorithm.value,
        ...keyData,
      ];
    } else if (version == 4) {
      bytes = [
        version,
        ...creationTime.toBytes(),
        algorithm.value,
        ...keyData,
      ];
    } else {
      bytes = [
        version,
        ...creationTime.toBytes(),
        algorithm.value,
        ...keyData.length.pack32(),
        ...keyData,
      ];
    }

    return Uint8List.fromList(bytes);
  }
}
