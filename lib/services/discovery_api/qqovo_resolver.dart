import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// qqovo meting 直链解析（与云端 soda/qq 同源，作客户端兜底）。
class QqovoResolver {
  QqovoResolver({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                'Accept': '*/*',
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                'Referer': 'https://qqovo.top/room/4SVWQK',
                'Origin': 'https://qqovo.top',
              },
            ));

  final Dio _dio;

  Future<String?> resolve({
    required String server,
    required String id,
    List<String> qualities = const ['320', '128', 'exhigh', 'standard'],
  }) async {
    final songId = id.trim();
    if (songId.isEmpty) return null;
    try {
      final boot = await _dio.post(
        'https://qqovo.top/api/session/bootstrap',
        data: {'deviceId': _uuid()},
        options: Options(contentType: 'application/json'),
      );
      final apiSignKey = '${boot.data?['apiSignKey'] ?? ''}';
      if (apiSignKey.isEmpty) return null;

      for (final quality in qualities) {
        final trackUrl =
            'https://qqovo.top/api/meting?server=$server&type=url&id=$songId&quality=$quality';
        final trackResp = await _dio.get(
          trackUrl,
          options: Options(headers: _signedHeaders(trackUrl, apiSignKey)),
        );
        final data = trackResp.data;
        if (data is! Map) continue;

        // QQ：meting 直接给播放直链；汽水：先给 source url 再二次取流
        var playUrl = '${data['url'] ?? ''}';
        if (playUrl.startsWith('http') &&
            (playUrl.contains('qqovo.top') || playUrl.contains('/api/'))) {
          final sourceResp = await _dio.get(
            playUrl,
            options: Options(headers: _signedHeaders(playUrl, apiSignKey)),
          );
          final sourceData = sourceResp.data;
          if (sourceData is Map) {
            playUrl = '${sourceData['url'] ?? ''}';
          }
        }
        if (playUrl.startsWith('http://')) {
          playUrl = 'https://${playUrl.substring(7)}';
        }
        if (playUrl.startsWith('http')) return playUrl;
      }
    } catch (e) {
      debugPrint('[QqovoResolver] $server/$id failed: $e');
    }
    return null;
  }

  Map<String, String> _signedHeaders(String url, String apiSignKey) {
    final uri = Uri.parse(url);
    final timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final nonce = _uuid();
    final entries = uri.queryParameters.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final query = entries.map((e) => '${e.key}=${e.value}').join('&');
    final payload = ['GET', uri.path, query, '', timestamp, nonce].join('\n');
    final digest = Hmac(sha256, utf8.encode(apiSignKey))
        .convert(utf8.encode(payload))
        .bytes;
    final sign = base64Url.encode(digest).replaceAll('=', '');
    return {
      'Accept': '*/*',
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Referer': 'https://qqovo.top/room/4SVWQK',
      'Origin': 'https://qqovo.top',
      'X-OM-Ts': timestamp,
      'X-OM-Nonce': nonce,
      'X-OM-Sign': sign,
    };
  }

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
        '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
  }
}
