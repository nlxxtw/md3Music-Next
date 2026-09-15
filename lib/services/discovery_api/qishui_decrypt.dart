import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 汽水 CDN 返回的是 CENC/AES-CTR 加密 MP4（有进度无声）。
/// 算法对齐 OpenMusic `client/src/workers/qishuiDecryptWorker.ts`。
class QishuiDecryptResult {
  QishuiDecryptResult({required this.bytes, required this.extension});
  final Uint8List bytes;
  final String extension;
}

class QishuiDecrypt {
  static QishuiDecryptResult decrypt(Uint8List data, String rawKey) {
    final moov = _box(data, 'moov');
    if (moov == null) throw StateError('汽水音频缺少 moov');
    final trak = _boxIn(data, 'trak', moov);
    final mdia = trak == null ? null : _boxIn(data, 'mdia', trak);
    final minf = mdia == null ? null : _boxIn(data, 'minf', mdia);
    final stbl = minf == null ? null : _boxIn(data, 'stbl', minf);
    final stsd = stbl == null ? null : _boxIn(data, 'stsd', stbl);
    final stsz = stbl == null ? null : _boxIn(data, 'stsz', stbl);
    final stsc = stbl == null ? null : _boxIn(data, 'stsc', stbl);
    final stco = stbl == null ? null : _boxIn(data, 'stco', stbl);
    var senc = stbl == null ? null : _boxIn(data, 'senc', stbl);
    senc ??= _boxIn(data, 'senc', moov);
    final mdat = _box(data, 'mdat');
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
      throw StateError('汽水音频容器不完整（缺加密盒，直链无法出声）');
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
    final ivCount = _u32(senc.body, 4);
    if (ivCount > 200000 || 8 + ivCount * 8 > senc.body.length) {
      throw StateError('汽水音频 IV 数据无效');
    }
    if (sizes.length > ivCount) {
      throw StateError('汽水音频样本范围无效');
    }

    final sampleOffsets = Uint32List(sizes.length);
    var sampleIndex = 0;
    for (var chunk = 1;
        chunk <= chunkCount && sampleIndex < sizes.length;
        chunk++) {
      var offset = sourceChunkOffsets[chunk - 1];
      final count = _samplesInChunk(chunk, stscEntries);
      if (count == 0) throw StateError('汽水音频 chunk 映射无效');
      for (var i = 0; i < count && sampleIndex < sizes.length; i++) {
        final size = sizes[sampleIndex];
        if (offset + size > data.length) {
          throw StateError('汽水音频样本范围无效');
        }
        sampleOffsets[sampleIndex] = offset;
        offset += size;
        sampleIndex++;
      }
    }
    if (sampleIndex != sizes.length) {
      throw StateError('汽水音频样本与 chunk 映射不一致');
    }

    final key = _resolveKey(rawKey);
    final metadata = _findFlacMetadata(stsd);
    final counter = Uint8List(16);

    if (metadata != null) {
      const header = [0x66, 0x4c, 0x61, 0x43]; // fLaC
      var total = header.length + metadata.length;
      for (final s in sizes) {
        total += s;
      }
      final output = Uint8List(total);
      output.setAll(0, header);
      output.setAll(header.length, metadata);
      var writeAt = header.length + metadata.length;
      for (var i = 0; i < sizes.length; i++) {
        final size = sizes[i];
        final srcOff = sampleOffsets[i];
        counter.fillRange(0, 16, 0);
        counter.setRange(0, 8, senc.body.sublist(8 + i * 8, 16 + i * 8));
        final decrypted = _aesCtr(key, counter, data.sublist(srcOff, srcOff + size));
        output.setAll(writeAt, decrypted);
        writeAt += size;
      }
      return QishuiDecryptResult(bytes: output, extension: 'flac');
    }

    final samples = <Uint8List>[];
    for (var i = 0; i < sizes.length; i++) {
      final size = sizes[i];
      final srcOff = sampleOffsets[i];
      counter.fillRange(0, 16, 0);
      counter.setRange(0, 8, senc.body.sublist(8 + i * 8, 16 + i * 8));
      samples.add(_aesCtr(key, counter, data.sublist(srcOff, srcOff + size)));
    }

    final ftyp = _box(data, 'ftyp');
    final ctx0 = _CleanCtx(
      sizes: sizes,
      stsc: stscEntries,
      chunkCount: chunkCount,
      mdatOffset: 0,
    );
    final draftMoov = _cleanBoxChildren(
      data,
      moov.offset + 8,
      moov.offset + moov.size,
      ctx0,
    );
    final mdatOffset = (ftyp?.size ?? 0) + draftMoov.length + 16;
    final ctx = _CleanCtx(
      sizes: sizes,
      stsc: stscEntries,
      chunkCount: chunkCount,
      mdatOffset: mdatOffset,
    );
    final cleanMoovData = _cleanBoxChildren(
      data,
      moov.offset + 8,
      moov.offset + moov.size,
      ctx,
    );
    final cleanMoov = _concat([
      _u32Bytes(cleanMoovData.length + 8),
      _ascii('moov'),
      cleanMoovData,
    ]);
    final cleanMdatData = _concat(samples);
    final cleanMdat = _concat([
      _u32Bytes(cleanMdatData.length + 8),
      _ascii('mdat'),
      cleanMdatData,
    ]);
    final ftypBytes = ftyp == null
        ? Uint8List(0)
        : data.sublist(ftyp.offset, ftyp.offset + ftyp.size);
    return QishuiDecryptResult(
      bytes: _concat([ftypBytes, cleanMoov, cleanMdat]),
      extension: 'm4a',
    );
  }

  static const _encrypted = {
    'senc',
    'saio',
    'saiz',
    'sinf',
    'schi',
    'tenc',
    'schm',
    'frma',
  };
  static const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'stsd'};

  static int _u32(Uint8List data, int offset) {
    return ByteData.sublistView(data).getUint32(offset, Endian.big);
  }

  static String _text(Uint8List data) => utf8.decode(data, allowMalformed: true);

  static _Box? _box(Uint8List data, String wanted, [int start = 0, int? end]) {
    final limit = end ?? data.length;
    var offset = start;
    while (offset + 8 <= limit) {
      final size = _u32(data, offset);
      if (size < 8 || offset + size > limit) return null;
      if (_text(data.sublist(offset + 4, offset + 8)) == wanted) {
        return _Box(
          size: size,
          offset: offset,
          body: data.sublist(offset + 8, offset + size),
        );
      }
      offset += size;
    }
    return null;
  }

  static _Box? _boxIn(Uint8List data, String wanted, _Box parent) {
    return _box(data, wanted, parent.offset + 8, parent.offset + parent.size);
  }

  static int _bitCount(int input) {
    var value = input & 0xffffffff;
    value -= (value >> 1) & 0x55555555;
    value = (value & 0x33333333) + ((value >> 2) & 0x33333333);
    return (((value + (value >> 4)) & 0x0f0f0f0f) * 0x01010101) >> 24;
  }

  static String _decodeSpadeA(String value) {
    final source = base64.decode(value);
    if (source.length < 3) return '';
    final padding = (source[0] ^ source[1] ^ source[2]) - 48;
    if (padding < 0 || source.length < padding + 2) return '';
    final input = source.sublist(1, source.length - padding);
    final working = Uint8List(input.length + 2);
    working[0] = 0xfa;
    working[1] = 0x55;
    working.setRange(2, 2 + input.length, input);
    final decoded = Uint8List(input.length);
    for (var i = 0; i < decoded.length; i++) {
      var byte = (input[i] ^ working[i]) - _bitCount(i) - 21;
      while (byte < 0) {
        byte += 0xff;
      }
      decoded[i] = byte & 0xff;
    }
    final first = decoded[0];
    final skip = first >= 48 && first <= 57
        ? first - 48
        : first >= 97 && first <= 122
            ? first - 87
            : 255;
    final end = 1 + source.length - padding - 2 - skip;
    if (end > 1 && end <= decoded.length) {
      return utf8.decode(decoded.sublist(1, end), allowMalformed: true);
    }
    return '';
  }

  static Uint8List _resolveKey(String value) {
    final raw = value.trim();
    final hex = RegExp(r'^[0-9a-f]{32}$', caseSensitive: false).hasMatch(raw)
        ? raw
        : _decodeSpadeA(raw);
    if (!RegExp(r'^[0-9a-f]{32}$', caseSensitive: false).hasMatch(hex)) {
      throw StateError('汽水音频密钥无效');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static Uint8List _aesCtr(Uint8List key, Uint8List iv, Uint8List data) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), Uint8List.fromList(iv)));
    return cipher.process(data);
  }

  static Uint32List _sampleSizes(_Box stsz) {
    final fixed = _u32(stsz.body, 4);
    final count = _u32(stsz.body, 8);
    // JS 里 !fixed 把 0 当假；Dart 里 fixed 是 int，要用 == 0
    if (count > 200000 ||
        (fixed == 0 && 12 + count * 4 > stsz.body.length)) {
      throw StateError('汽水音频样本数据无效');
    }
    if (fixed != 0) {
      return Uint32List(count)..fillRange(0, count, fixed);
    }
    final sizes = Uint32List(count);
    for (var i = 0; i < count; i++) {
      sizes[i] = _u32(stsz.body, 12 + i * 4);
    }
    return sizes;
  }

  static List<_Stsc> _sampleToChunk(_Box stsc) {
    final count = _u32(stsc.body, 4);
    if (count > 20000 || 8 + count * 12 > stsc.body.length) {
      throw StateError('汽水音频 chunk 数据无效');
    }
    return List<_Stsc>.generate(count, (i) {
      final o = 8 + i * 12;
      return _Stsc(
        firstChunk: _u32(stsc.body, o),
        samplesPerChunk: _u32(stsc.body, o + 4),
      );
    });
  }

  static int _samplesInChunk(int chunk, List<_Stsc> entries) {
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

  static List<int> _rebuiltChunkOffsets(
    Uint32List sizes,
    List<_Stsc> entries,
    int chunkCount,
    int mdatOffset,
  ) {
    final offsets = <int>[];
    var sampleIndex = 0;
    var offset = mdatOffset;
    for (var chunk = 1; chunk <= chunkCount; chunk++) {
      offsets.add(offset);
      final count = _samplesInChunk(chunk, entries);
      for (var i = 0; i < count && sampleIndex < sizes.length; i++) {
        offset += sizes[sampleIndex];
        sampleIndex++;
      }
    }
    return offsets;
  }

  static Uint8List _rewriteStco(Uint8List data, List<int> offsets) {
    final count = _u32(data, 4);
    if (count > offsets.length) throw StateError('汽水音频 chunk 偏移无效');
    final output = Uint8List(8 + count * 4);
    output.setRange(0, 8, data);
    final view = ByteData.sublistView(output);
    for (var i = 0; i < count; i++) {
      view.setUint32(8 + i * 4, offsets[i], Endian.big);
    }
    return output;
  }

  static Uint8List _cleanBoxChildren(
    Uint8List source,
    int start,
    int end,
    _CleanCtx context,
  ) {
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
      final type = _text(source.sublist(offset + 4, offset + 8));
      if (_encrypted.contains(type)) {
        offset += size;
        continue;
      }
      if (type == 'enca') {
        final fixedEnd = (offset + size) < (offset + 36) ? offset + size : offset + 36;
        final fixed = source.sublist(offset + 8, fixedEnd);
        final inner = _cleanBoxChildren(source, fixedEnd, offset + size, context);
        parts.add(_u32Bytes(fixed.length + inner.length + 8));
        parts.add(_ascii('mp4a'));
        parts.add(fixed);
        parts.add(inner);
      } else if (type == 'stco') {
        final body = _rewriteStco(
          source.sublist(offset + 8, offset + size),
          _rebuiltChunkOffsets(
            context.sizes,
            context.stsc,
            context.chunkCount,
            context.mdatOffset,
          ),
        );
        parts.add(_u32Bytes(body.length + 8));
        parts.add(_ascii('stco'));
        parts.add(body);
      } else if (_containers.contains(type)) {
        final fixedSize = type == 'stsd' ? 8 : 0;
        final maxFixed = offset + 8 + fixedSize;
        final fixedEnd = (offset + size) < maxFixed ? offset + size : maxFixed;
        final fixed = source.sublist(offset + 8, fixedEnd);
        final inner = _cleanBoxChildren(source, fixedEnd, offset + size, context);
        parts.add(_u32Bytes(fixed.length + inner.length + 8));
        parts.add(_ascii(type));
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
    final marker = [0x64, 0x66, 0x4c, 0x61]; // dfLa
    for (var i = 4; i + 4 <= stsd.body.length; i++) {
      if (stsd.body[i] != marker[0] ||
          stsd.body[i + 1] != marker[1] ||
          stsd.body[i + 2] != marker[2] ||
          stsd.body[i + 3] != marker[3]) {
        continue;
      }
      final size = _u32(stsd.body, i - 4);
      if (size >= 8 && i - 4 + size <= stsd.body.length) {
        return stsd.body.sublist(i + 4, i - 4 + size);
      }
    }
    return null;
  }

  static Uint8List _u32Bytes(int value) {
    final out = Uint8List(4);
    ByteData.sublistView(out).setUint32(0, value, Endian.big);
    return out;
  }

  static Uint8List _ascii(String s) => Uint8List.fromList(ascii.encode(s));

  static Uint8List _concat(List<Uint8List> parts) {
    var length = 0;
    for (final p in parts) {
      length += p.length;
    }
    final output = Uint8List(length);
    var offset = 0;
    for (final p in parts) {
      output.setAll(offset, p);
      offset += p.length;
    }
    return output;
  }
}

class _Box {
  _Box({required this.size, required this.offset, required this.body});
  final int size;
  final int offset;
  final Uint8List body;
}

class _Stsc {
  _Stsc({required this.firstChunk, required this.samplesPerChunk});
  final int firstChunk;
  final int samplesPerChunk;
}

class _CleanCtx {
  _CleanCtx({
    required this.sizes,
    required this.stsc,
    required this.chunkCount,
    required this.mdatOffset,
  });
  final Uint32List sizes;
  final List<_Stsc> stsc;
  final int chunkCount;
  final int mdatOffset;
}

Map<String, dynamic> qishuiDecryptIsolate(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final auth = args['auth'] as String;
  final result = QishuiDecrypt.decrypt(bytes, auth);
  return {
    'bytes': result.bytes,
    'extension': result.extension,
  };
}
