// Copyright 2022-present by Nguyen Van Nguyen <nguyennv1981@gmail.com>. All rights reserved.
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.

import '../enums.dart';
import 'secret_key.dart';

class SecretSubkey extends SecretKey {
  static const tag = PacketTag.secretSubkey;

  SecretSubkey(super.publicKey, super.symmetricAlgorithm, super.s2kUsage, super.s2k, super.iv, super.keyData);
}
