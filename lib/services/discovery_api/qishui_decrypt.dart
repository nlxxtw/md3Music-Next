import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 汽水 CDN 密文解密 —— 对齐 OpenMusic `qishuiDecryptWorker.ts`：
/// Spade 解 auth → AES-CTR 按 stco/stsc 样本偏移解密 →
/// AAC：重建干净 ftyp+moov+mdat；FLAC：拼 `fLaC` + dfLa 元数据 + 明文样本。
class QishuiDecryptResult {
  QishuiDecryptResult({required this.bytes, required this.extension});
  final Uint8List bytes;
  final String extension;
}

class QishuiDecrypt {
  static const _encryptedBoxTypes = {
    'senc',
    'saio',
    'saiz',
    'sinf',
    'schi',
    'tenc',
    'schm',
    'frma',
  };
  static const _containerBoxTypes = {
    'moov',
    'trak',
    'mdia',
    'minf',
    'stbl',
    'stsd',
  };

  static QishuiDecryptResult decrypt(Uint8List data, String playAuth) {
    final keyBytes = _resolveKey(playAuth);

    final moov = _findBox(data, 'moov');
    if (moov == null) throw StateError('汽水音频缺少 moov');
    final trak = _findBox(
      data,
      'trak',
      start: moov.offset + 8,
      end: moov.offset + moov.size,
    );
    final mdia = trak == null
        ? null
        : _findBox(
            data,
            'mdia',
            start: trak.offset + 8,
            end: trak.offset + trak.size,
          );
    final minf = mdia == null
        ? null
        : _findBox(
            data,
            'minf',
            start: mdia.offset + 8,
            end: mdia.offset + mdia.size,
          );
    final stbl = minf == null
        ? null
        : _findBox(
            data,
            'stbl',
            start: minf.offset + 8,
            end: minf.offset + minf.size,
          );
    final stsd = stbl == null
        ? null
        : _findBox(
            data,
            'stsd',
            start: stbl.offset + 8,
            end: stbl.offset + stbl.size,
          );
    final stsz = stbl == null
        ? null
        : _findBox(
            data,
            'stsz',
            start: stbl.offset + 8,
            end: stbl.offset + stbl.size,
          );
    final stsc = stbl == null
        ? null
        : _findBox(
            data,
            'stsc',
            start: stbl.offset + 8,
            end: stbl.offset + stbl.size,
          );
    final stco = stbl == null
        ? null
        : _findBox(
            data,
            'stco',
            start: stbl.offset + 8,
            end: stbl.offset + stbl.size,
          );
    var senc = stbl == null
        ? null
        : _findBox(
            data,
            'senc',
            start: stbl.offset + 8,
            end: stbl.offset + stbl.size,
          );
    senc ??= _findBox(
      data,
      'senc',
      start: moov.offset + 8,
      end: moov.offset + moov.size,
    );
    final mdat = _findBox(data, 'mdat');
    if (trak == null ||
        mdia == null ||
        minf == null ||
        stbl == null ||
        stsd == null ||
        stsz == null ||
        stsc == null ||
        stco == null ||
        senc == null ||
        mdat == null) {
      throw StateError('汽水音频容器不完整');
    }

    final sizes = _sampleSizes(stsz);
    final stscEntries = _sampleToChunk(stsc);
    final chunkCount = _u32(stco.body, 4);
    if (chunkCount > 200000 || 8 + chunkCount * 4 > stco.body.length) {
      throw StateError('汽水音频 chunk 偏移无效');
    }
    final sourceChunkOffsets = List<int>.generate(
      chunkCount,
      (i) => _u32(stco.body, 8 + i * 4),
    );

    // OpenMusic：固定每样本 8B IV（无 subsample）；若带 subsample flag 则回退 musicdl 解析。
    final sencFlags = _u32(senc.body, 0) & 0x00ffffff;
    final ivCount = _u32(senc.body, 4);
    if (ivCount > 200000) throw StateError('汽水音频 IV 数据无效');
    if (sizes.length > ivCount) throw StateError('汽水音频样本范围无效');

    final ivs = <Uint8List>[];
    if ((sencFlags & 0x02) != 0) {
      var ptr = 8;
      for (var i = 0; i < ivCount; i++) {
        if (ptr + 8 > senc.body.length) break;
        final iv = Uint8List(16);
        iv.setRange(0, 8, senc.body.sublist(ptr, ptr + 8));
        ivs.add(iv);
        ptr += 8;
        if (ptr + 2 > senc.body.length) break;
        final subCount = (senc.body[ptr] << 8) | senc.body[ptr + 1];
        ptr += 2 + (subCount * 6);
      }
    } else {
      if (8 + ivCount * 8 > senc.body.length) {
        throw StateError('汽水音频 IV 数据无效');
      }
      for (var i = 0; i < ivCount; i++) {
        final iv = Uint8List(16);
        final off = 8 + i * 8;
        iv.setRange(0, 8, senc.body.sublist(off, off + 8));
        ivs.add(iv);
      }
    }

    final sampleOffsets = List<int>.filled(sizes.length, 0);
    var sampleIndex = 0;
    for (var chunk = 1; chunk <= chunkCount && sampleIndex < sizes.length; chunk++) {
      var offset = sourceChunkOffsets[chunk - 1];
      final count = _samplesInChunk(chunk, stscEntries);
      if (count == 0) throw StateError('汽水音频 chunk 映射无效');
      for (var j = 0; j < count && sampleIndex < sizes.length; j++) {
        final size = sizes[sampleIndex];
        if (offset + size > data.length) {
          throw StateError('汽水音频样本范围无效');
        }
        sampleOffsets[sampleIndex] = offset;
        offset += size;
        sampleIndex += 1;
      }
    }
    if (sampleIndex != sizes.length) {
      throw StateError('汽水音频样本与 chunk 映射不一致');
    }

    final flacMeta = _findFlacMetadata(stsd);
    if (flacMeta != null) {
      final totalBytes = sizes.fold<int>(0, (a, b) => a + b);
      final header = ascii.encode('fLaC');
      final output = Uint8List(header.length + flacMeta.length + totalBytes);
      output.setRange(0, header.length, header);
      output.setRange(header.length, header.length + flacMeta.length, flacMeta);
      var writeAt = header.length + flacMeta.length;
      for (var i = 0; i < sizes.length; i++) {
        final size = sizes[i];
        final src = data.sublist(sampleOffsets[i], sampleOffsets[i] + size);
        final plain = i < ivs.length ? _aesCtr(keyBytes, ivs[i], src) : src;
        output.setRange(writeAt, writeAt + size, plain);
        writeAt += size;
      }
      return QishuiDecryptResult(bytes: output, extension: 'flac');
    }

    final samples = <Uint8List>[];
    for (var i = 0; i < sizes.length; i++) {
      final size = sizes[i];
      final src = data.sublist(sampleOffsets[i], sampleOffsets[i] + size);
      samples.add(i < ivs.length ? _aesCtr(keyBytes, ivs[i], src) : src);
    }

    final ftyp = _findBox(data, 'ftyp');
    final draftMoov = _cleanBoxChildren(
      data,
      moov.offset + 8,
      moov.offset + moov.size,
      sizes: sizes,
      stsc: stscEntries,
      chunkCount: chunkCount,
      mdatOffset: 0,
    );
    final mdatOffset = (ftyp?.size ?? 0) + draftMoov.length + 16;
    final cleanMoovData = _cleanBoxChildren(
      data,
      moov.offset + 8,
      moov.offset + moov.size,
      sizes: sizes,
      stsc: stscEntries,
      chunkCount: chunkCount,
      mdatOffset: mdatOffset,
    );
    final cleanMoov = _concat([
      _u32Bytes(cleanMoovData.length + 8),
      ascii.encode('moov'),
      cleanMoovData,
    ]);
    final cleanMdatData = _concat(samples);
    final cleanMdat = _concat([
      _u32Bytes(cleanMdatData.length + 8),
      ascii.encode('mdat'),
      cleanMdatData,
    ]);
    final out = _concat([
      if (ftyp != null) data.sublist(ftyp.offset, ftyp.offset + ftyp.size),
      cleanMoov,
      cleanMdat,
    ]);
    return QishuiDecryptResult(bytes: out, extension: 'm4a');
  }

  static Uint8List _resolveKey(String playAuth) {
    final hex = _extractKey(playAuth);
    if (hex == null || hex.length != 32) {
      throw StateError('汽水音频密钥无效');
    }
    final key = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      key[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return key;
  }

  /// Spade：与 OpenMusic `decodeSpadeA` / musicdl `extractkey` 同一公式。
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
        while (byte < 0) {
          byte += 255;
        }
        decoded[i] = byte & 0xff;
      }
      final skip = _decodeBase36(decoded[0]);
      // OpenMusic: end = 1 + source.length - padding - 2 - skip == input.length - skip
      final endIndex = input.length - skip;
      if (endIndex <= 1 || endIndex > decoded.length) return null;
      final hex =
          utf8.decode(decoded.sublist(1, endIndex), allowMalformed: true);
      if (!RegExp(r'^[0-9a-f]{32}$', caseSensitive: false).hasMatch(hex)) {
        return null;
      }
      return hex.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  static List<int> _sampleSizes(_Box stsz) {
    final fixed = _u32(stsz.body, 4);
    final count = _u32(stsz.body, 8);
    // JS 里 !fixed 把 0 当假；Dart 的 ! 是空断言，int 不能当 bool。
    if (count > 200000 || (fixed == 0 && 12 + count * 4 > stsz.body.length)) {
      throw StateError('汽水音频样本数据无效');
    }
    if (fixed != 0) {
      return List<int>.filled(count, fixed);
    }
    return List<int>.generate(count, (i) => _u32(stsz.body, 12 + i * 4));
  }

  static List<_StscEntry> _sampleToChunk(_Box stsc) {
    final count = _u32(stsc.body, 4);
    if (count > 20000 || 8 + count * 12 > stsc.body.length) {
      throw StateError('汽水音频 chunk 数据无效');
    }
    return List<_StscEntry>.generate(count, (i) {
      final o = 8 + i * 12;
      return _StscEntry(
        firstChunk: _u32(stsc.body, o),
        samplesPerChunk: _u32(stsc.body, o + 4),
      );
    });
  }

  static int _samplesInChunk(int chunk, List<_StscEntry> entries) {
    for (var i = 0; i < entries.length; i++) {
      final current = entries[i];
      final next = i + 1 < entries.length ? entries[i + 1] : null;
      if (chunk >= current.firstChunk &&
          (next == null || chunk < next.firstChunk)) {
        return current.samplesPerChunk;
      }
    }
    return 0;
  }

  static List<int> _rebuiltChunkOffsets({
    required List<int> sizes,
    required List<_StscEntry> stsc,
    required int chunkCount,
    required int mdatOffset,
  }) {
    final offsets = <int>[];
    var sampleIndex = 0;
    var offset = mdatOffset;
    for (var chunk = 1; chunk <= chunkCount; chunk++) {
      offsets.add(offset);
      final count = _samplesInChunk(chunk, stsc);
      for (var j = 0; j < count && sampleIndex < sizes.length; j++) {
        offset += sizes[sampleIndex];
        sampleIndex += 1;
      }
    }
    return offsets;
  }

  static Uint8List _rewriteStco(Uint8List body, List<int> offsets) {
    final count = _u32(body, 4);
    if (count > offsets.length) throw StateError('汽水音频 chunk 偏移无效');
    final output = Uint8List(8 + count * 4);
    output.setRange(0, 8, body.sublist(0, 8));
    for (var i = 0; i < count; i++) {
      final v = offsets[i];
      final o = 8 + i * 4;
      output[o] = (v >> 24) & 0xff;
      output[o + 1] = (v >> 16) & 0xff;
      output[o + 2] = (v >> 8) & 0xff;
      output[o + 3] = v & 0xff;
    }
    return output;
  }

  static Uint8List _cleanBoxChildren(
    Uint8List source,
    int start,
    int end, {
    required List<int> sizes,
    required List<_StscEntry> stsc,
    required int chunkCount,
    required int mdatOffset,
  }) {
    final parts = <Uint8List>[];
    var offset = start;
    while (offset < end) {
      if (offset + 8 > end) {
        parts.add(source.sublist(offset, end));
        break;
      }
      final size = _u32(source, offset);
      if (size < 8 || offset + size > end) {
        parts.add(source.sublist(offset, end));
        break;
      }
      final type = ascii.decode(source.sublist(offset + 4, offset + 8));
      if (_encryptedBoxTypes.contains(type)) {
        offset += size;
        continue;
      }
      if (type == 'enca') {
        final fixedEnd = offset + size < offset + 36 ? offset + size : offset + 36;
        final fixed = source.sublist(offset + 8, fixedEnd);
        final inner = _cleanBoxChildren(
          source,
          fixedEnd,
          offset + size,
          sizes: sizes,
          stsc: stsc,
          chunkCount: chunkCount,
          mdatOffset: mdatOffset,
        );
        parts.add(_u32Bytes(fixed.length + inner.length + 8));
        parts.add(ascii.encode('mp4a'));
        parts.add(fixed);
        parts.add(inner);
      } else if (type == 'stco') {
        final body = _rewriteStco(
          source.sublist(offset + 8, offset + size),
          _rebuiltChunkOffsets(
            sizes: sizes,
            stsc: stsc,
            chunkCount: chunkCount,
            mdatOffset: mdatOffset,
          ),
        );
        parts.add(_u32Bytes(body.length + 8));
        parts.add(ascii.encode('stco'));
        parts.add(body);
      } else if (_containerBoxTypes.contains(type)) {
        final fixedSize = type == 'stsd' ? 8 : 0;
        final fixedEnd = offset + size < offset + 8 + fixedSize
            ? offset + size
            : offset + 8 + fixedSize;
        final fixed = source.sublist(offset + 8, fixedEnd);
        final inner = _cleanBoxChildren(
          source,
          fixedEnd,
          offset + size,
          sizes: sizes,
          stsc: stsc,
          chunkCount: chunkCount,
          mdatOffset: mdatOffset,
        );
        parts.add(_u32Bytes(fixed.length + inner.length + 8));
        parts.add(ascii.encode(type));
        parts.add(fixed);
        parts.add(inner);
      } else {
        parts.add(source.sublist(offset, offset + size));
      }
      offset += size;
    }
    return _concat(parts);
  }

  static Uint8List? _findFlacMetadata(_Box stsd) {
    final marker = ascii.encode('dfLa');
    final body = stsd.body;
    for (var i = 4; i + 4 <= body.length; i++) {
      if (body[i] != marker[0] ||
          body[i + 1] != marker[1] ||
          body[i + 2] != marker[2] ||
          body[i + 3] != marker[3]) {
        continue;
      }
      final size = _u32(body, i - 4);
      if (size >= 8 && i - 4 + size <= body.length) {
        return body.sublist(i + 4, i - 4 + size);
      }
    }
    return null;
  }

  static Uint8List _concat(List<Uint8List> parts) {
    final total = parts.fold<int>(0, (a, b) => a + b.length);
    final out = Uint8List(total);
    var o = 0;
    for (final p in parts) {
      out.setRange(o, o + p.length, p);
      o += p.length;
    }
    return out;
  }

  static Uint8List _u32Bytes(int value) {
    return Uint8List.fromList([
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
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

class _StscEntry {
  _StscEntry({required this.firstChunk, required this.samplesPerChunk});
  final int firstChunk;
  final int samplesPerChunk;
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
