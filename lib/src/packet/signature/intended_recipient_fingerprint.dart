// Copyright 2022-present by Nguyen Van Nguyen <nguyennv1981@gmail.com>. All rights reserved.
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.

import 'dart:typed_data';

import '../../enums.dart';
import '../signature_subpacket.dart';

/// packet giving the intended recipient fingerprint.
class IntendedRecipientFingerprint extends SignatureSubpacket {
  IntendedRecipientFingerprint(Uint8List data, {super.critical, super.isLongLength})
      : super(SignatureSubpacketType.intendedRecipientFingerprint, data);

  int get keyVersion => data[0];

  Uint8List get fingerprint => data.sublist(1);
}
