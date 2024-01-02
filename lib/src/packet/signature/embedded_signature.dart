// Copyright 2022-present by Dart Privacy Guard project. All rights reserved.
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.

import 'dart:typed_data';

import '../../enum/signature_subpacket_type.dart';
import '../signature_packet.dart';
import '../signature_subpacket.dart';

/// Packet embedded signature
/// Author Nguyen Van Nguyen <nguyennv1981@gmail.com>
class EmbeddedSignature extends SignatureSubpacket {
  EmbeddedSignature(final Uint8List data, {super.critical, super.isLong})
      : super(SignatureSubpacketType.embeddedSignature, data);

  factory EmbeddedSignature.fromSignature(final SignaturePacket signature) =>
      EmbeddedSignature(signature.toByteData());
}
