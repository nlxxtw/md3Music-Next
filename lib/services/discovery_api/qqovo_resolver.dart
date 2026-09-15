import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// qqovo meting 直链解析（国内优先 music.qqovo.cn，失败再试 qqovo.top）。
class QqovoResolver {
  QqovoResolver({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
            ));

  final Dio _dio;

  static const _bases = <String>[
    'https://music.qqovo.cn',
    'https://qqovo.top',
  ];

  /// 复用 bootstrap，避免每切一首都重新握手（切歌延迟主因之一）。
  static final Map<String, _QqovoSession> _sessions = {};

  Future<String?> resolve({
    required String server,
    required String id,
    List<String> qualities = const ['320', '128', 'exhigh', 'standard'],
  }) async {
    final songId = id.trim();
    if (songId.isEmpty) return null;

    for (final base in _bases) {
      final url = await _resolveOnBase(
        base: base,
        server: server,
        songId: songId,
        qualities: qualities,
      );
      if (url != null) return url;
    }
    return null;
  }

  Future<String?> _resolveOnBase({
    required String base,
    required String server,
    required String songId,
    required List<String> qualities,
  }) async {
    try {
      final session = await _ensureSession(base);
      if (session == null) return null;

      for (final quality in qualities) {
        final trackUrl =
            '$base/api/meting?server=$server&type=url&id=$songId&quality=$quality';
        final trackResp = await _dio.get(
          trackUrl,
          options: Options(headers: _signedHeaders(base, trackUrl, session.key)),
        );
        final data = trackResp.data;
        if (data is! Map) continue;

        // QQ：meting 直接给播放直链；汽水：先给 source url 再二次取流
        var playUrl = '${data['url'] ?? ''}';
        if (playUrl.startsWith('http') &&
            (playUrl.contains('qqovo.') || playUrl.contains('/api/'))) {
          final sourceResp = await _dio.get(
            playUrl,
            options:
                Options(headers: _signedHeaders(base, playUrl, session.key)),
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
      debugPrint('[QqovoResolver] $base $server/$songId failed: $e');
      _sessions.remove(base);
    }
    return null;
  }

  Future<_QqovoSession?> _ensureSession(String base) async {
    final cached = _sessions[base];
    if (cached != null && !cached.isExpired) return cached;

    final boot = await _dio.post(
      '$base/api/session/bootstrap',
      data: {'deviceId': _uuid()},
      options: Options(
        contentType: 'application/json',
        headers: _browserHeaders(base),
      ),
    );
    final apiSignKey = '${boot.data?['apiSignKey'] ?? ''}';
    if (apiSignKey.isEmpty) return null;
    final session = _QqovoSession(
      key: apiSignKey,
      expiresAt: DateTime.now().add(const Duration(minutes: 8)),
    );
    _sessions[base] = session;
    return session;
  }

  Map<String, String> _browserHeaders(String base) => {
        'Accept': '*/*',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        'Referer': '$base/',
        'Origin': base,
      };

  Map<String, String> _signedHeaders(
    String base,
    String url,
    String apiSignKey,
  ) {
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
      ..._browserHeaders(base),
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

class _QqovoSession {
  _QqovoSession({required this.key, required this.expiresAt});
  final String key;
  final DateTime expiresAt;
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
