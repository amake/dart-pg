// Copyright 2022-present by Nguyen Van Nguyen <nguyennv1981@gmail.com>. All rights reserved.
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.

import 'dart:typed_data';

import '../../enums.dart';
import '../signature_subpacket.dart';

class ExportableCertification extends SignatureSubpacket {
  ExportableCertification(Uint8List data, {super.critical, super.isLongLength})
      : super(SignatureSubpacketType.exportableCertification, data);

  factory ExportableCertification.fromExportable(bool exportable, {bool critical = false}) =>
      ExportableCertification(Uint8List.fromList([exportable ? 1 : 0]), critical: critical);

  bool get isExportable => data[0] != 0;
}
