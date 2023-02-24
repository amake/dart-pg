// Copyright 2022-present by Nguyen Van Nguyen <nguyennv1981@gmail.com>. All rights reserved.
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.

import 'dart:typed_data';

import 'package:pointycastle/api.dart';

import '../crypto/symmetric/base_cipher.dart';
import '../enums.dart';
import '../helpers.dart';
import '../openpgp.dart';
import 'contained_packet.dart';
import 'packet_list.dart';

/// Implementation of the Sym. Encrypted Integrity Protected Data Packet (Tag 18)
/// See RFC 4880, section 5.13.
///
/// The Symmetrically Encrypted Integrity Protected Data packet is a variant of the Symmetrically Encrypted Data packet.
/// It is a new feature created for OpenPGP that addresses the problem of detecting a modification to encrypted data.
/// It is used in combination with a Modification Detection Code packet.
class SymEncryptedIntegrityProtectedDataPacket extends ContainedPacket {
  static const version = OpenPGP.seipVersion;

  /// Encrypted data, the output of the selected symmetric-key cipher
  /// operating in Cipher Feedback mode with shift amount equal to the
  /// block size of the cipher (CFB-n where n is the block size).
  final Uint8List encrypted;

  /// Decrypted packets contained within.
  final PacketList? packets;

  SymEncryptedIntegrityProtectedDataPacket(this.encrypted, {this.packets})
      : super(PacketTag.symEncryptedIntegrityProtectedData);

  factory SymEncryptedIntegrityProtectedDataPacket.fromPacketData(final Uint8List bytes) {
    /// A one-octet version number. The only currently defined version is 1.
    final version = bytes[0];
    if (version != OpenPGP.seipVersion) {
      throw UnsupportedError('Version $version of the SEIP packet is unsupported.');
    }
    return SymEncryptedIntegrityProtectedDataPacket(bytes.sublist(1));
  }

  factory SymEncryptedIntegrityProtectedDataPacket.encryptPackets(
    final SymmetricAlgorithm symmetric,
    final Uint8List key,
    final PacketList packets,
  ) {
    final toHash = Uint8List.fromList([
      ...Helper.generatePrefix(symmetric),
      ...packets.packetEncode(),
      0xd3,
      0x14,
    ]);
    final plainText = Uint8List.fromList([...toHash, ...Helper.hashDigest(toHash, HashAlgorithm.sha1)]);

    final cipher = BufferedCipher(symmetric.cipherEngine)
      ..init(
        true,
        ParametersWithIV(KeyParameter(key), Uint8List(symmetric.blockSize)),
      );
    return SymEncryptedIntegrityProtectedDataPacket(cipher.process(plainText), packets: packets);
  }

  @override
  Uint8List toPacketData() {
    return Uint8List.fromList([version, ...encrypted]);
  }

  SymEncryptedIntegrityProtectedDataPacket encrypt(final SymmetricAlgorithm symmetric, final Uint8List key) {
    if (packets != null && packets!.isNotEmpty) {
      return SymEncryptedIntegrityProtectedDataPacket.encryptPackets(symmetric, key, packets!);
    }
    return this;
  }

  /// Decrypts the encrypted data contained in the packet.
  SymEncryptedIntegrityProtectedDataPacket decrypt(final SymmetricAlgorithm symmetric, final Uint8List key) {
    final cipher = BufferedCipher(symmetric.cipherEngine)
      ..init(
        false,
        ParametersWithIV(KeyParameter(key), Uint8List(symmetric.blockSize)),
      );
    final decrypted = cipher.process(encrypted);
    final realHash = decrypted.sublist(decrypted.length - HashAlgorithm.sha1.digestSize);
    final toHash = decrypted.sublist(0, decrypted.length - HashAlgorithm.sha1.digestSize);
    final verifyHash = realHash.equals(Helper.hashDigest(toHash, HashAlgorithm.sha1));
    if (!verifyHash) {
      throw StateError('Modification detected.');
    }

    return SymEncryptedIntegrityProtectedDataPacket(
      encrypted,
      packets: PacketList.packetDecode(toHash.sublist(symmetric.blockSize + 2, toHash.length - 2)),
    );
  }
}
