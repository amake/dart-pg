/// Copyright 2023-present by Dart Privacy Guard project. All rights reserved.
/// For the full copyright and license information, please view the LICENSE
/// file that was distributed with this source code.

import 'dart:typed_data';

import 'package:dart_pg/src/crypto/math/byte_ext.dart';
import 'package:pointycastle/api.dart';

/// An implementation of RFC 7253 on The OCB Authenticated-Encryption Algorithm.
/// See https://tools.ietf.org/html/rfc7253
class OCBBlockCipher implements AEADCipher {
  static const _blockSize = 16;

  final BlockCipher _hashCipher;
  final BlockCipher _mainCipher;

  /// Configuration
  late bool _forEncryption;
  late int _macSize;
  late Uint8List _initialAssociatedText;

  /// Key dependent
  /// Elements are lazily calculated
  late List<Uint8List> _lSub;
  late Uint8List _lAsterisk;
  late Uint8List _lDollar;

  /// Nonce dependent
  late Uint8List _ktopInput;
  final Uint8List _stretch = Uint8List.fromList(List.filled(24, 0));
  final Uint8List _offsetMain_0 = Uint8List(16);

  /// Per encryption/decryption
  late Uint8List _hashBlock;
  late Uint8List _mainBlock;
  late int _hashBlockPos;
  late int _mainBlockPos;
  late int _hashBlockCount;
  late int _mainBlockCount;
  late Uint8List _offsetHash;
  final Uint8List _offsetMain = Uint8List(16);
  late Uint8List _sum;
  late Uint8List _checksum;

  /// NOTE: The MAC value is preserved after doFinal
  late Uint8List _macBlock;

  OCBBlockCipher(this._hashCipher, this._mainCipher) {
    if (_hashCipher.blockSize != _blockSize) {
      throw ArgumentError('Hash cipher must have a block size of $_blockSize');
    }
    if (_mainCipher.blockSize != _blockSize) {
      throw ArgumentError('Main cipher must have a block size of $_blockSize');
    }

    if (_hashCipher.algorithmName != _mainCipher.algorithmName) {
      throw ArgumentError('Hash cipher and main cipher must be the same algorithm');
    }
  }

  /// True if initialized for encryption
  bool get forEncryption => _forEncryption;

  /// The length in bytes of the authentication tag
  int get macSize => _macSize;

  @override
  String get algorithmName => '${_mainCipher.algorithmName}/OCB';

  @override
  Uint8List get mac => _getMac();

  int get blockSize => _blockSize;

  /// The underlying cipher
  BlockCipher get underlyingCipher => _mainCipher;

  @override
  void init(bool forEncryption, CipherParameters? params) {
    _forEncryption = forEncryption;

    final KeyParameter keyParam;
    final Uint8List newNonce;

    _macBlock = Uint8List(0);
    if (params is AEADParameters) {
      final param = params;
      newNonce = param.nonce;
      _initialAssociatedText = param.associatedData;

      final macSizeBits = param.macSize;
      if (macSizeBits < 32 || macSizeBits > 256 || macSizeBits % 8 != 0) {
        throw ArgumentError('Invalid value for MAC size: $macSizeBits');
      }

      _macSize = macSizeBits ~/ 8;
      keyParam = param.parameters as KeyParameter;
    } else if (params is ParametersWithIV) {
      var param = params;
      newNonce = param.iv;
      _initialAssociatedText = Uint8List(0);
      _macSize = 16;
      keyParam = param.parameters as KeyParameter;
    } else {
      throw ArgumentError('invalid parameters passed to AEADBlockCipher');
    }

    _hashBlock = Uint8List(16);
    _mainBlock = Uint8List(_forEncryption ? _blockSize : (_blockSize + _macSize));

    if (newNonce.isEmpty) {
      throw ArgumentError('IV must be no more than 15 bytes');
    }

    /// Key dependent initialisation
    _hashCipher.init(true, keyParam);
    _mainCipher.init(_forEncryption, keyParam);
    _ktopInput = Uint8List(0);

    _lAsterisk = Uint8List(16);
    _hashCipher.processBlock(_lAsterisk, 0, _lAsterisk, 0);
    _lDollar = _double(_lAsterisk);

    _lSub = List.empty(growable: true);
    _lSub.add(_double(_lDollar));

    /// Nonce dependent and per encryption/decryption initialisation
    final bottom = _processNonce(newNonce);
    final bits = bottom % 8;
    var bytes = bottom ~/ 8;
    if (bits == 0) {
      _offsetMain_0.setAll(0, _stretch.sublist(bytes));
    } else {
      for (var i = 0; i < 16; ++i) {
        final b1 = _stretch[bytes];
        final b2 = _stretch[++bytes];
        _offsetMain_0[i] = ((b1 << bits) | (b2 >>> (8 - bits))) & 0xff;
      }
    }

    _hashBlockPos = 0;
    _mainBlockPos = 0;

    _hashBlockCount = 0;
    _mainBlockCount = 0;

    _offsetHash = Uint8List(16);
    _sum = Uint8List(16);
    _offsetMain.setAll(0, _offsetMain_0.sublist(0));
    _checksum = Uint8List(16);

    if (_initialAssociatedText.isNotEmpty) {
      processAADBytes(_initialAssociatedText, 0, _initialAssociatedText.length);
    }
  }

  @override
  int doFinal(Uint8List output, int outOff) {
    /// For decryption, get the tag from the end of the message
    Uint8List? tag;
    if (!_forEncryption) {
      if (_mainBlockPos < _macSize) {
        throw InvalidCipherTextException('Data too short');
      }
      _mainBlockPos -= _macSize;
      tag = Uint8List(_macSize);
      tag.setAll(0, _mainBlock.sublist(_mainBlockPos, _macSize));
    }

    /// HASH: Process any final partial block; compute final hash value
    if (_hashBlockPos > 0) {
      _extend(_hashBlock, _hashBlockPos);
      _updateHash(_lAsterisk);
    }

    /// Ocb encrypt/decrypt: Process any final partial block
    if (_mainBlockPos > 0) {
      if (_forEncryption) {
        _extend(_mainBlock, _mainBlockPos);
        _xor(_checksum, _mainBlock);
      }

      _xor(_offsetMain, _lAsterisk);
      final pad = Uint8List(16);
      _hashCipher.processBlock(_offsetMain, 0, pad, 0);

      _xor(_mainBlock, pad);
      if (output.length < (outOff + _mainBlockPos)) {
        throw StateError('Output buffer too short');
      }
      output.setAll(outOff, _mainBlock.sublist(0, _mainBlockPos));

      if (!_forEncryption) {
        _extend(_mainBlock, _mainBlockPos);
        _xor(_checksum, _mainBlock);
      }
    }

    /// Ocb encrypt/decrypt: Compute raw tag
    _xor(_checksum, _offsetMain);
    _xor(_checksum, _lDollar);
    _hashCipher.processBlock(_checksum, 0, _checksum, 0);
    _xor(_checksum, _sum);

    _macBlock = Uint8List(_macSize);
    _macBlock.setAll(0, _checksum.sublist(0, _macSize));

    /// Validate or append tag and reset this cipher for the next run
    var resultLen = _mainBlockPos;

    if (_forEncryption) {
      if (output.length < (outOff + resultLen + _macSize)) {
        throw StateError('Output buffer too short');
      }

      /// Append tag to the message
      output.setAll(outOff + resultLen, _macBlock.sublist(0, _macSize));
      resultLen += _macSize;
    } else {
      /// Compare the tag from the message with the calculated one
      if (_macBlock.equals(tag ?? Uint8List(0))) {
        throw InvalidCipherTextException('Mac check in OCB failed');
      }
    }

    _reset(false);

    return resultLen;
  }

  Uint8List process(Uint8List data) {
    final out = Uint8List(getOutputSize(data.length));
    final len = processBytes(data, 0, data.length, out, 0);
    final outLen = len + doFinal(out, len);
    return Uint8List.view(out.buffer, 0, outLen);
  }

  @override
  int processBytes(Uint8List input, int inOff, int len, Uint8List output, int outOff) {
    if (input.length < (inOff + len)) {
      throw ArgumentError('Input buffer too short');
    }
    var resultLen = 0;
    for (var i = 0; i < len; ++i) {
      _mainBlock[_mainBlockPos] = input[inOff + i];
      if (++_mainBlockPos == _mainBlock.length) {
        _processMainBlock(output, outOff + resultLen);
        resultLen += _blockSize;
      }
    }

    return resultLen;
  }

  @override
  int getUpdateOutputSize(final int len) {
    var totalData = len + _mainBlockPos;
    if (!forEncryption) {
      if (totalData < macSize) {
        return 0;
      }
      totalData -= macSize;
    }
    return totalData - totalData % _blockSize;
  }

  @override
  void processAADByte(final int input) {
    _hashBlock[_hashBlockPos] = input;
    if (++_hashBlockPos == _hashBlock.length) {
      _processHashBlock();
    }
  }

  @override
  int processByte(int input, Uint8List output, int outOff) {
    _mainBlock[_mainBlockPos] = input;
    if (++_mainBlockPos == _mainBlock.length) {
      _processMainBlock(output, outOff);
      return _blockSize;
    }
    return 0;
  }

  @override
  void reset() {
    _reset(true);
  }

  void _reset(final bool clearMac) {
    _hashCipher.reset();
    _mainCipher.reset();

    _clear(_hashBlock);
    _clear(_mainBlock);

    _hashBlockPos = 0;
    _mainBlockPos = 0;

    _hashBlockCount = 0;
    _mainBlockCount = 0;

    _clear(_offsetHash);
    _clear(_sum);
    _offsetMain.setAll(0, _offsetMain_0);
    _clear(_checksum);

    if (clearMac) {
      _macBlock = Uint8List(0);
    }

    if (_initialAssociatedText.isNotEmpty) {
      processAADBytes(_initialAssociatedText, 0, _initialAssociatedText.length);
    }
  }

  @override
  void processAADBytes(Uint8List input, int off, int len) {
    for (var i = 0; i < len; ++i) {
      _hashBlock[_hashBlockPos] = input[off + i];
      if (++_hashBlockPos == _hashBlock.length) {
        _processHashBlock();
      }
    }
  }

  @override
  int getOutputSize(int len) {
    final totalData = len + _mainBlockPos;
    if (_forEncryption) {
      return totalData + _macSize;
    }
    return totalData < _macSize ? 0 : totalData - _macSize;
  }

  Uint8List _getMac() {
    if (_macBlock.isEmpty) {
      return Uint8List(_macSize);
    }
    return _macBlock.sublist(0);
  }

  void _clear(Uint8List input) {
    input.fillRange(0, input.length, 0);
  }

  Uint8List _getLSub(int n) {
    while (n >= _lSub.length) {
      _lSub.add(_double(_lSub.last));
    }
    return _lSub[n];
  }

  void _processHashBlock() {
    /// HASH: Process any whole blocks
    _updateHash(_getLSub(_ntz(++_hashBlockCount)));
    _hashBlockPos = 0;
  }

  void _processMainBlock(Uint8List output, int outOff) {
    if (output.length < (outOff + _blockSize)) {
      throw ArgumentError('Output buffer too short');
    }

    /// Ocb encrypt/decrypt: Process any whole blocks
    if (_forEncryption) {
      _xor(_checksum, _mainBlock);
      _mainBlockPos = 0;
    }

    _xor(_offsetMain, _getLSub(_ntz(++_mainBlockCount)));

    _xor(_mainBlock, _offsetMain);
    _mainCipher.processBlock(_mainBlock, 0, _mainBlock, 0);
    _xor(_mainBlock, _offsetMain);

    output.setAll(outOff, _mainBlock.sublist(0));

    if (!_forEncryption) {
      _xor(_checksum, _mainBlock);
      _mainBlock.setAll(0, _mainBlock.sublist(_blockSize, _macSize));
      _mainBlockPos = _macSize;
    }
  }

  int _processNonce(Uint8List n) {
    final nonce = Uint8List(16);
    nonce.setAll(nonce.length - n.length, n.sublist(0, n.length));
    nonce[0] = (macSize << 4) & 0xff;
    nonce[15 - n.length] |= 1;
    final bottom = nonce[15] & 0x3F;
    nonce[15] &= 0xC0;

    /// When used with incrementing nonces, the cipher is only applied once every 64 inits.
    if (_ktopInput.isEmpty || !nonce.equals(_ktopInput)) {
      final ktop = Uint8List(16);
      _ktopInput = nonce;
      _hashCipher.processBlock(_ktopInput, 0, ktop, 0);
      _stretch.setAll(0, ktop.sublist(0));
      for (var i = 0; i < 8; ++i) {
        _stretch[16 + i] = (ktop[i] ^ ktop[i + 1]) & 0xff;
      }
    }

    return bottom;
  }

  void _updateHash(Uint8List lSub) {
    _xor(_offsetHash, lSub);
    _xor(_hashBlock, _offsetHash);
    _hashCipher.processBlock(_hashBlock, 0, _hashBlock, 0);
    _xor(_sum, _hashBlock);
  }

  static Uint8List _double(Uint8List block) {
    final result = Uint8List.fromList(List.filled(16, 9));
    final carry = _shiftLeft(block, result);
    result[15] ^= (0x87 >>> ((1 - carry) << 3));
    return result;
  }

  static void _extend(Uint8List block, int pos) {
    block[pos] = 0x80;
    while (++pos < 16) {
      block[pos] = 0;
    }
  }

  static int _ntz(int n) {
    if (n == 0) {
      return 64;
    }
    var ntz = 0;
    while ((n & 1) == 0) {
      ++ntz;
      n >>>= 1;
    }
    return ntz;
  }

  static int _shiftLeft(Uint8List block, Uint8List output) {
    var i = 16;
    var bit = 0;
    while (--i >= 0) {
      var b = block[i] & 0xff;
      output[i] = ((b << 1) | bit) & 0xff;
      bit = (b >>> 7) & 1;
    }
    return bit;
  }

  static void _xor(Uint8List block, Uint8List val) {
    for (var i = 15; i >= 0; --i) {
      block[i] ^= val[i];
    }
  }
}
