// Copyright 2022-present by Nguyen Van Nguyen <nguyennv1981@gmail.com>. All rights reserved.
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.

import 'dart:math';
import 'dart:typed_data';

import '../crypto/math/int_ext.dart';
import '../enum/aead_algorithm.dart';
import '../enum/packet_tag.dart';
import '../enum/symmetric_algorithm.dart';
import '../helpers.dart';
import 'contained_packet.dart';
import 'packet_list.dart';

/// Implementation of the Symmetrically Encrypted Authenticated Encryption with
/// Additional Data (AEAD) Protected Data Packet(Tag 20)
/// See https://datatracker.ietf.org/doc/html/draft-ietf-openpgp-rfc4880bis#name-aead-encrypted-data-packet-
/// Author Nguyen Van Nguyen <nguyennv1981@gmail.com>
class AeadEncryptedData extends ContainedPacket {
  static const version = 1;

  final SymmetricAlgorithm symmetric;
  final AeadAlgorithm aead;
  final int chunkSize;
  final Uint8List iv;

  /// Encrypted data
  final Uint8List encrypted;

  /// Decrypted packets contained within.
  final PacketList? packets;

  AeadEncryptedData(
    this.symmetric,
    this.aead,
    this.chunkSize,
    this.iv,
    this.encrypted, {
    this.packets,
  }) : super(PacketTag.aeadEncryptedData);

  factory AeadEncryptedData.fromByteData(
    final Uint8List bytes,
  ) {
    var pos = 0;

    /// A one-octet version number. The only currently defined version is 1.
    final packetVersion = bytes[pos++];
    if (packetVersion != version) {
      throw UnsupportedError(
        'Version $packetVersion of the AEAD-encrypted data packet is unsupported.',
      );
    }

    /// A one-octet number describing the symmetric algorithm used.
    final symmetric = SymmetricAlgorithm.values.firstWhere(
      (algo) => algo.value == bytes[pos],
    );
    pos++;

    /// A one-octet number describing the aead algorithm used.
    final aead = AeadAlgorithm.values.firstWhere(
      (algo) => algo.value == bytes[pos],
    );

    final chunkSize = bytes[pos++];
    final iv = bytes.sublist(pos, pos + aead.ivLength);
    pos += aead.ivLength;

    return AeadEncryptedData(
      symmetric,
      aead,
      chunkSize,
      iv,
      bytes.sublist(pos),
    );
  }

  static Future<AeadEncryptedData> encryptPackets(
    final Uint8List key,
    final PacketList packets, {
    final SymmetricAlgorithm symmetric = SymmetricAlgorithm.aes256,
    final AeadAlgorithm aead = AeadAlgorithm.eax,
    final int chunkSize = 12,
  }) async {
    final iv = Helper.secureRandom().nextBytes(symmetric.blockSize);
    final encryptor = AeadEncryptedData(
      symmetric,
      aead,
      chunkSize,
      iv,
      Uint8List(0),
    );
    return AeadEncryptedData(
      symmetric,
      aead,
      chunkSize,
      iv,
      encryptor._crypt(true, key, packets.encode()),
      packets: packets,
    );
  }

  @override
  Uint8List toByteData() {
    return Uint8List.fromList([
      version,
      symmetric.value,
      aead.value,
      chunkSize,
      ...iv,
      ...encrypted,
    ]);
  }

  /// Encrypt the payload in the packet.
  Future<AeadEncryptedData> encrypt(
    final Uint8List key, {
    final SymmetricAlgorithm symmetric = SymmetricAlgorithm.aes256,
    final AeadAlgorithm aead = AeadAlgorithm.eax,
    final int chunkSize = 12,
  }) async {
    if (packets != null && packets!.isNotEmpty) {
      return AeadEncryptedData.encryptPackets(
        key,
        packets!,
        symmetric: symmetric,
      );
    }
    return this;
  }

  /// Decrypts the encrypted data contained in the packet.
  Future<AeadEncryptedData> decrypt(
    final Uint8List key, {
    final SymmetricAlgorithm symmetric = SymmetricAlgorithm.aes256,
  }) async {
    final length = encrypted.length;
    final data = encrypted.sublist(0, length + aead.tagLength);
    final authTag = encrypted.sublist(length + aead.tagLength);
    return AeadEncryptedData(
      symmetric,
      aead,
      chunkSize,
      iv,
      encrypted,
      packets: PacketList.packetDecode(_crypt(
        false,
        key,
        data,
        finalChunk: authTag,
      )),
    );
  }

  /// En/decrypt the payload.
  Uint8List _crypt(
    bool forEncryption,
    Uint8List key,
    Uint8List data, {
    Uint8List? finalChunk,
  }) {
    final cipher = aead.cipherEngine(key, symmetric);
    final dataLength = data.length;
    final tagLength = forEncryption ? 0 : aead.tagLength;
    final chunkSize = pow(2, this.chunkSize + 6).toInt() + tagLength; // ((uint64_t)1 << (c + 6))

    final zeroBuffer = Uint8List(21);
    final adataBuffer = zeroBuffer.sublist(0, 13);
    final adataTagBuffer = Uint8List(21);

    final aaData = _getAAData();
    adataBuffer.setAll(0, aaData);
    adataTagBuffer.setAll(0, aaData);
    adataTagBuffer.setAll(
      13 + 4,
      (dataLength - tagLength * (dataLength / chunkSize).ceil()).pack64(),
    );

    final List<Uint8List> crypted = List.empty(growable: true);
    for (var chunkIndex = 0; chunkIndex == 0 || data.isNotEmpty;) {
      final chunkIndexData = adataTagBuffer.sublist(5, 13);
      crypted.add(
        forEncryption
            ? cipher.encrypt(
                data.sublist(0, chunkSize),
                cipher.getNonce(iv, chunkIndexData),
                adataBuffer,
              )
            : cipher.decrypt(
                data.sublist(0, chunkSize),
                cipher.getNonce(iv, chunkIndexData),
                adataBuffer,
              ),
      );

      /// We take a chunk of data, en/decrypt it, and shift `data` to the next chunk.
      data = data.sublist(chunkSize);
      adataTagBuffer.setAll(5 + 4, (++chunkIndex).pack64());
    }

    /// After the final chunk, we either encrypt a final, empty data
    /// chunk to get the final authentication tag or validate that final
    /// authentication tag.
    final chunkIndexData = adataTagBuffer.sublist(5, 13);
    crypted.add(
      forEncryption
          ? cipher.encrypt(
              finalChunk ?? Uint8List(0),
              cipher.getNonce(iv, chunkIndexData),
              adataTagBuffer,
            )
          : cipher.decrypt(
              finalChunk ?? Uint8List(0),
              cipher.getNonce(iv, chunkIndexData),
              adataTagBuffer,
            ),
    );

    return Uint8List.fromList([
      ...crypted.expand((element) => element),
    ]);
  }

  Uint8List _getAAData() {
    return Uint8List.fromList([
      0xC0 | tag.value,
      version,
      symmetric.value,
      aead.value,
      chunkSize,
    ]);
  }
}
