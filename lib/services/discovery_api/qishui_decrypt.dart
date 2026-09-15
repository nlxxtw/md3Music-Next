import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 汽水 CDN 密文 MP4 解密（对齐 musicdl `sodautils.AudioDecryptor`）。
/// 有进度无声 = 播了未解密的密文。
class QishuiDecryptResult {
  QishuiDecryptResult({required this.bytes, required this.extension});
  final Uint8List bytes;
  final String extension;
}

class QishuiDecrypt {
  static QishuiDecryptResult decrypt(Uint8List data, String playAuth) {
    final hexKey = _extractKey(playAuth);
    if (hexKey == null || hexKey.length != 32) {
      throw StateError('汽水音频密钥无效');
    }

    final file = Uint8List.fromList(data);
    final moov = _findBox(file, 'moov');
    if (moov == null) throw StateError('汽水音频缺少 moov');

    var senc = _findBox(
      file,
      'senc',
      start: moov.offset + 8,
      end: moov.offset + moov.size,
    );
    final trak = _findBox(
      file,
      'trak',
      start: moov.offset + 8,
      end: moov.offset + moov.size,
    );
    if (trak == null) throw StateError('汽水音频缺少 trak');
    final mdia = _findBox(
      file,
      'mdia',
      start: trak.offset + 8,
      end: trak.offset + trak.size,
    );
    if (mdia == null) throw StateError('汽水音频缺少 mdia');
    final minf = _findBox(
      file,
      'minf',
      start: mdia.offset + 8,
      end: mdia.offset + mdia.size,
    );
    if (minf == null) throw StateError('汽水音频缺少 minf');
    final stbl = _findBox(
      file,
      'stbl',
      start: minf.offset + 8,
      end: minf.offset + minf.size,
    );
    if (stbl == null) throw StateError('汽水音频缺少 stbl');
    final stsz = _findBox(
      file,
      'stsz',
      start: stbl.offset + 8,
      end: stbl.offset + stbl.size,
    );
    if (stsz == null) throw StateError('汽水音频缺少 stsz');

    final stszBody = stsz.body;
    final sampleSizeFixed = _u32(stszBody, 4);
    final sampleCount = _u32(stszBody, 8);
    if (sampleCount <= 0 || sampleCount > 500000) {
      throw StateError('汽水音频样本数量无效');
    }
    final sampleSizes = <int>[];
    if (sampleSizeFixed != 0) {
      for (var i = 0; i < sampleCount; i++) {
        sampleSizes.add(sampleSizeFixed);
      }
    } else {
      if (12 + sampleCount * 4 > stszBody.length) {
        throw StateError('汽水音频样本表损坏');
      }
      for (var i = 0; i < sampleCount; i++) {
        sampleSizes.add(_u32(stszBody, 12 + i * 4));
      }
    }

    senc ??= _findBox(
      file,
      'senc',
      start: stbl.offset + 8,
      end: stbl.offset + stbl.size,
    );
    if (senc == null) throw StateError('汽水音频缺少 senc');

    final sencBody = senc.body;
    final sencFlags = _u32(sencBody, 0) & 0x00ffffff;
    final sencSampleCount = _u32(sencBody, 4);
    final ivs = <Uint8List>[];
    var ptr = 8;
    for (var i = 0; i < sencSampleCount; i++) {
      if (ptr + 8 > sencBody.length) break;
      final iv = Uint8List(16);
      iv.setRange(0, 8, sencBody.sublist(ptr, ptr + 8));
      ivs.add(iv);
      ptr += 8;
      if ((sencFlags & 0x02) != 0) {
        if (ptr + 2 > sencBody.length) break;
        final subCount = (sencBody[ptr] << 8) | sencBody[ptr + 1];
        ptr += 2 + (subCount * 6);
      }
    }

    final mdat = _findBox(file, 'mdat');
    if (mdat == null) throw StateError('汽水音频缺少 mdat');

    final keyBytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      keyBytes[i] = int.parse(hexKey.substring(i * 2, i * 2 + 2), radix: 16);
    }

    final decryptedMdat = BytesBuilder(copy: false);
    var readPtr = mdat.offset + 8;
    for (var i = 0; i < sampleSizes.length; i++) {
      final size = sampleSizes[i];
      if (readPtr + size > file.length) {
        throw StateError('汽水音频样本越界');
      }
      final chunk = file.sublist(readPtr, readPtr + size);
      if (i < ivs.length) {
        decryptedMdat.add(_aesCtr(keyBytes, ivs[i], chunk));
      } else {
        decryptedMdat.add(chunk);
      }
      readPtr += size;
    }

    final plain = decryptedMdat.takeBytes();
    if (plain.length != mdat.size - 8) {
      throw StateError(
        '汽水解密长度不匹配 ${plain.length} != ${mdat.size - 8}',
      );
    }
    file.setRange(mdat.offset + 8, mdat.offset + mdat.size, plain);

    final stsd = _findBox(
      file,
      'stsd',
      start: stbl.offset + 8,
      end: stbl.offset + stbl.size,
    );
    if (stsd != null) {
      // enca → mp4a（CENC 加密 AAC 盒改回普通）
      final region = file.sublist(stsd.offset, stsd.offset + stsd.size);
      final needle = ascii.encode('enca');
      final repl = ascii.encode('mp4a');
      for (var i = 0; i + 4 <= region.length; i++) {
        if (region[i] == needle[0] &&
            region[i + 1] == needle[1] &&
            region[i + 2] == needle[2] &&
            region[i + 3] == needle[3]) {
          file.setRange(stsd.offset + i, stsd.offset + i + 4, repl);
          break;
        }
      }
    }

    return QishuiDecryptResult(bytes: file, extension: 'm4a');
  }

  /// musicdl SpadeDecryptor.extractkey —— 端点用 `len - padding - 1 - skip`，
  /// 不要用 OpenMusic 里多减一次 padding 的错误公式。
  static String? _extractKey(String playAuth) {
    final raw = playAuth.trim();
    if (RegExp(r'^[0-9a-f]{32}$', caseSensitive: false).hasMatch(raw)) {
      return raw.toLowerCase();
    }
    try {
      final source = base64.decode(raw);
      if (source.length < 3) return null;
      final padding = (source[0] ^ source[1] ^ source[2]) - 48;
      if (padding < 0 || source.length < padding + 2) return null;
      final input = source.sublist(1, source.length - padding);
      final working = Uint8List(input.length + 2);
      working[0] = 0xfa;
      working[1] = 0x55;
      working.setRange(2, 2 + input.length, input);
      final decoded = Uint8List(input.length);
      for (var i = 0; i < decoded.length; i++) {
        var byte = (input[i] ^ working[i]) - _bitCount(i) - 21;
        if (byte < 0) byte %= 255;
        // musicdl: v if >=0 else v % 255；Dart 负数 % 在部分环境需校正
        while (byte < 0) {
          byte += 255;
        }
        decoded[i] = byte & 0xff;
      }
      final skip = _decodeBase36(decoded[0]);
      // musicdl: end_index = 1 + (len(bytes_data) - padding_len - 2) - skip
      //        = source.length - padding - 1 - skip
      //        = input.length - skip
      final endIndex = input.length - skip;
      if (endIndex <= 1 || endIndex > decoded.length) return null;
      final hex = utf8.decode(decoded.sublist(1, endIndex), allowMalformed: true);
      if (!RegExp(r'^[0-9a-f]{32}$', caseSensitive: false).hasMatch(hex)) {
        return null;
      }
      return hex.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  static int _decodeBase36(int c) {
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 97 && c <= 122) return c - 97 + 10;
    return 0xff;
  }

  static int _bitCount(int n) {
    var value = n & 0xffffffff;
    value -= (value >> 1) & 0x55555555;
    value = (value & 0x33333333) + ((value >> 2) & 0x33333333);
    return (((value + (value >> 4)) & 0x0f0f0f0f) * 0x01010101) >> 24;
  }

  static Uint8List _aesCtr(Uint8List key, Uint8List iv, Uint8List data) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), Uint8List.fromList(iv)));
    return cipher.process(data);
  }

  static int _u32(Uint8List data, int offset) {
    return (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
  }

  static _Box? _findBox(
    Uint8List data,
    String type, {
    int start = 0,
    int? end,
  }) {
    final limit = end ?? data.length;
    var pos = start;
    final want = ascii.encode(type);
    while (pos + 8 <= limit) {
      final size = _u32(data, pos);
      if (size < 8 || pos + size > limit) break;
      if (data[pos + 4] == want[0] &&
          data[pos + 5] == want[1] &&
          data[pos + 6] == want[2] &&
          data[pos + 7] == want[3]) {
        return _Box(
          offset: pos,
          size: size,
          body: data.sublist(pos + 8, pos + size),
        );
      }
      pos += size;
    }
    return null;
  }
}

class _Box {
  _Box({required this.offset, required this.size, required this.body});
  final int offset;
  final int size;
  final Uint8List body;
}

/// isolate 入口
Map<String, dynamic> qishuiDecryptIsolate(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final auth = args['auth'] as String;
  final result = QishuiDecrypt.decrypt(bytes, auth);
  return {
    'bytes': result.bytes,
    'extension': result.extension,
  };
}
