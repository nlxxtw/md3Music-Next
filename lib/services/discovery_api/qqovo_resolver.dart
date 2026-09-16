import 'dart:convert';
import 'dart:math';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';

/// qqovo meting 直链解析（国内优先 music.qqovo.cn，失败再试 qqovo.top）。
///
/// 重要：bootstrap 会下发 `openmusic_*` Cookie，后续 meting 必须带上，
/// 否则仅有签名也会 403（表现为汽水/网易「无音源」）。
class QqovoResolver {
  QqovoResolver({Dio? dio}) : _dio = dio ?? _sharedDio;

  final Dio _dio;

  /// 全应用共用 CookieJar，保证 bootstrap → meting 同会话。
  static final CookieJar _cookieJar = CookieJar();
  static final Dio _sharedDio = () {
    final d = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
    ));
    d.interceptors.add(CookieManager(_cookieJar));
    return d;
  }();

  static const _bases = <String>[
    'https://music.qqovo.cn',
    'https://qqovo.top',
  ];

  /// 复用 bootstrap，避免每切一首都重新握手。
  static final Map<String, _QqovoSession> _sessions = {};

  static List<String> qualitiesFor({
    required String server,
    String preference = '320',
  }) {
    final pref = preference.trim();
    final wantLossless = pref == 'flac' || pref == 'high';
    final wantHigh = wantLossless || pref == '320' || pref.isEmpty;
    if (server == 'tencent') {
      if (wantLossless) return const ['flac', 'ogg', '320', '128'];
      if (wantHigh) return const ['320', '128'];
      return const ['128', '320'];
    }
    if (server == 'qishui') {
      if (wantLossless) {
        return const [
          'lossless',
          'hires',
          'exhigh',
          '320',
          'higher',
          'standard',
          '128',
        ];
      }
      if (wantHigh) {
        return const ['exhigh', '320', 'higher', 'standard', '128'];
      }
      return const ['standard', '128', 'exhigh'];
    }
    // netease：优先标准码率，兼容性最好
    if (wantLossless) {
      return const [
        'jymaster',
        'sky',
        'hires',
        'lossless',
        'exhigh',
        'higher',
        'standard',
        '128',
      ];
    }
    if (wantHigh) {
      return const ['exhigh', 'higher', 'standard', '128'];
    }
    return const ['standard', '128', 'higher', 'exhigh'];
  }

  Future<dynamic> meting({
    required String server,
    required String type,
    String id = '',
    String? quality,
  }) async {
    final songId = id.trim();
    // fm / recommend 类接口可不带 id；其它类型仍要求 id。
    if (songId.isEmpty && type != 'fm') return null;
    for (final base in _bases) {
      try {
        final session = await _ensureSession(base);
        if (session == null) continue;
        final q = quality == null ? '' : '&quality=${Uri.encodeQueryComponent(quality)}';
        final idPart = songId.isEmpty
            ? ''
            : '&id=${Uri.encodeQueryComponent(songId)}';
        final url =
            '$base/api/meting?server=$server&type=$type$idPart$q';
        final resp = await _dio.get(
          url,
          options: Options(
            headers: _signedHeaders(base, url, session.key),
            validateStatus: (c) => c != null && c < 500,
          ),
        );
        if (resp.statusCode == 403) {
          _sessions.remove(base);
          await _cookieJar.delete(Uri.parse(base));
          continue;
        }
        return resp.data;
      } catch (e) {
        debugPrint('[QqovoResolver] meting $server/$type failed: $e');
        _sessions.remove(base);
      }
    }
    return null;
  }

  /// OpenMusic 平台热榜：`GET /api/music/hot`（全站点播完成次数，需签名会话）。
  Future<List<Map<String, dynamic>>> getPlatformHot({int limit = 50}) async {
    final n = limit.clamp(1, 100);
    for (final base in _bases) {
      try {
        final session = await _ensureSession(base);
        if (session == null) continue;
        final url = '$base/api/music/hot?limit=$n';
        final resp = await _dio.get(
          url,
          options: Options(
            headers: _signedHeaders(base, url, session.key),
            validateStatus: (c) => c != null && c < 500,
          ),
        );
        if (resp.statusCode == 403) {
          _sessions.remove(base);
          await _cookieJar.delete(Uri.parse(base));
          continue;
        }
        final data = resp.data;
        if (data is! List) continue;
        return data
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      } catch (e) {
        debugPrint('[QqovoResolver] platform hot failed: $e');
        _sessions.remove(base);
      }
    }
    return const [];
  }

  Future<String?> resolve({
    required String server,
    required String id,
    List<String>? qualities,
    String preference = '320',
  }) async {
    return (await resolveHit(
      server: server,
      id: id,
      qualities: qualities,
      preference: preference,
    ))
        ?.url;
  }

  /// 汽水二次解析会带 [QqovoHit.auth]（AES-CTR 密钥）。
  Future<QqovoHit?> resolveHit({
    required String server,
    required String id,
    List<String>? qualities,
    String preference = '320',
  }) async {
    final songId = id.trim();
    if (songId.isEmpty) return null;
    final tryQualities =
        qualities ?? qualitiesFor(server: server, preference: preference);

    for (final base in _bases) {
      final hit = await _resolveOnBase(
        base: base,
        server: server,
        songId: songId,
        qualities: tryQualities,
      );
      if (hit != null) return hit;
    }
    return null;
  }

  Future<QqovoHit?> _resolveOnBase({
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
          options: Options(
            headers: _signedHeaders(base, trackUrl, session.key),
            validateStatus: (c) => c != null && c < 500,
          ),
        );
        if (trackResp.statusCode == 403) {
          debugPrint('[QqovoResolver] 403 on $base — clear session/cookies');
          _sessions.remove(base);
          await _cookieJar.delete(Uri.parse(base));
          return null;
        }
        final data = trackResp.data;
        if (data is! Map) continue;

        var playUrl = '${data['url'] ?? ''}'.trim();
        var auth = '${data['auth'] ?? ''}'.trim();
        // 相对路径补全
        if (playUrl.startsWith('/')) {
          playUrl = '$base$playUrl';
        }
        // 汽水：先给 /api/qishui-source，再二次取 CDN + auth
        if (playUrl.startsWith('http') &&
            (playUrl.contains('qqovo.') ||
                playUrl.contains('/api/qishui') ||
                playUrl.contains('/api/'))) {
          final sourceResp = await _dio.get(
            playUrl,
            options: Options(
              headers: _signedHeaders(base, playUrl, session.key),
              validateStatus: (c) => c != null && c < 500,
            ),
          );
          final sourceData = sourceResp.data;
          if (sourceData is Map) {
            playUrl = '${sourceData['url'] ?? ''}'.trim();
            final nestedAuth = '${sourceData['auth'] ?? ''}'.trim();
            if (nestedAuth.isNotEmpty) auth = nestedAuth;
          }
        }
        if (playUrl.startsWith('http://')) {
          playUrl = 'https://${playUrl.substring(7)}';
        }
        if (playUrl.startsWith('http')) {
          debugPrint(
            '[QqovoResolver] hit $server/$songId q=$quality auth=${auth.isNotEmpty}',
          );
          return QqovoHit(url: playUrl, auth: auth.isEmpty ? null : auth);
        }
      }
    } catch (e) {
      debugPrint('[QqovoResolver] $base $server/$songId failed: $e');
      _sessions.remove(base);
    }
    return null;
  }

  /// 解析封面直链：qqovo `type=pic` 需签名，Image / MediaSession 用不了代理 URL。
  /// 返回最终 CDN（如 `p*.music.126.net` / gtimg），失败返回 null。
  Future<String?> resolvePicUrl({
    required String server,
    required String id,
  }) async {
    final songId = id.trim();
    if (songId.isEmpty) return null;
    if (server == 'netease') {
      final map = await resolveNeteasePicUrls([songId]);
      final hit = map[songId];
      if (hit != null && hit.isNotEmpty) return hit;
      // 官方 detail 被墙/失败时：先走 meting song 取 CDN，再 type=pic 跟跳转
      final fromSong = await _picFromMetingSong(server: server, id: songId);
      if (fromSong != null && fromSong.isNotEmpty) return fromSong;
    }
    for (final base in _bases) {
      try {
        final session = await _ensureSession(base);
        if (session == null) continue;
        final url =
            '$base/api/meting?server=$server&type=pic&id=${Uri.encodeQueryComponent(songId)}';
        final resp = await _dio.get(
          url,
          options: Options(
            headers: _signedHeaders(base, url, session.key),
            followRedirects: false,
            validateStatus: (c) => c != null && c < 500,
          ),
        );
        if (resp.statusCode == 403) {
          _sessions.remove(base);
          await _cookieJar.delete(Uri.parse(base));
          continue;
        }
        final loc = resp.headers.value('location')?.trim();
        if (loc != null && loc.isNotEmpty) {
          final absolute = loc.startsWith('http')
              ? loc
              : (loc.startsWith('/') ? '$base$loc' : loc);
          return _httpsifyPic(absolute);
        }
        final data = resp.data;
        if (data is String) {
          final s = data.trim();
          if (s.startsWith('http')) return _httpsifyPic(s);
          // 偶发返回 JSON 字符串
          if (s.startsWith('{')) {
            try {
              final decoded = jsonDecode(s);
              if (decoded is Map) {
                final u = '${decoded['url'] ?? decoded['pic'] ?? ''}'.trim();
                if (u.startsWith('http')) return _httpsifyPic(u);
              }
            } catch (_) {}
          }
        }
        if (data is Map) {
          final u = '${data['url'] ?? data['pic'] ?? ''}'.trim();
          if (u.startsWith('http')) return _httpsifyPic(u);
        }
      } catch (e) {
        debugPrint('[QqovoResolver] resolvePic $server/$id failed: $e');
        _sessions.remove(base);
      }
    }
    return null;
  }

  /// meting `type=song` 常直接带回 CDN pic（比 type=pic 跟跳更稳）。
  Future<String?> _picFromMetingSong({
    required String server,
    required String id,
  }) async {
    try {
      final data = await meting(server: server, type: 'song', id: id);
      Map? raw;
      if (data is Map) {
        raw = data;
      } else if (data is List && data.isNotEmpty && data.first is Map) {
        raw = Map<String, dynamic>.from(data.first as Map);
      }
      if (raw == null) return null;
      var pic = '${raw['pic'] ?? raw['cover'] ?? raw['album_pic'] ?? ''}'.trim();
      if (pic.isEmpty) return null;
      pic = _httpsifyPic(pic);
      final host = Uri.tryParse(pic)?.host.toLowerCase() ?? '';
      // 仍是代理则不可用（Image/MediaSession 会 403）
      if (host.contains('qqovo') ||
          host == '127.0.0.1' ||
          host == 'localhost') {
        return null;
      }
      if (pic.startsWith('http')) return pic;
    } catch (e) {
      debugPrint('[QqovoResolver] meting song pic $server/$id failed: $e');
    }
    return null;
  }

  /// 网易官方公开详情接口批量取封面（无需 qqovo 签名，可直接给 Image/MediaSession）。
  Future<Map<String, String>> resolveNeteasePicUrls(List<String> ids) async {
    final clean = ids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (clean.isEmpty) return const {};
    final out = <String, String>{};
    // 官方 ids 一次不宜过大
    const chunk = 40;
    // music.163.com 在部分网络会被墙/超时，多镜像兜底。
    const hosts = <String>[
      'https://music.163.com',
      'https://interface.music.163.com',
      'https://api.music.163.com',
    ];
    for (var i = 0; i < clean.length; i += chunk) {
      final slice = clean.sublist(
        i,
        i + chunk > clean.length ? clean.length : i + chunk,
      );
      final pending = slice.where((id) => !out.containsKey(id)).toList();
      if (pending.isEmpty) continue;
      final idsParam = '[${pending.join(',')}]';
      for (final host in hosts) {
        if (pending.every(out.containsKey)) break;
        try {
          final resp = await _dio.get(
            '$host/api/song/detail',
            queryParameters: {'ids': idsParam},
            options: Options(
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                'Referer': 'https://music.163.com/',
              },
              validateStatus: (c) => c != null && c < 500,
              receiveTimeout: const Duration(seconds: 8),
              sendTimeout: const Duration(seconds: 8),
            ),
          );
          final songs = resp.data is Map ? (resp.data['songs'] as List?) : null;
          if (songs == null) continue;
          for (final raw in songs) {
            if (raw is! Map) continue;
            final sid = '${raw['id'] ?? ''}'.trim();
            final al = raw['al'] ?? raw['album'];
            var pic = '';
            if (al is Map) {
              pic = '${al['picUrl'] ?? al['blurPicUrl'] ?? ''}'.trim();
            }
            if (pic.isEmpty) pic = '${raw['album_pic'] ?? ''}'.trim();
            if (sid.isNotEmpty && pic.startsWith('http')) {
              out[sid] = _httpsifyPic(pic);
            }
          }
        } catch (e) {
          debugPrint('[QqovoResolver] netease song detail $host failed: $e');
        }
      }
    }
    return out;
  }

  static String _httpsifyPic(String url) {
    var u = url.trim();
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
    return u;
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
        validateStatus: (c) => c != null && c < 500,
      ),
    );
    final apiSignKey = '${boot.data?['apiSignKey'] ?? ''}'.trim();
    if (apiSignKey.isEmpty) {
      debugPrint('[QqovoResolver] bootstrap empty key status=${boot.statusCode}');
      return null;
    }
    final session = _QqovoSession(
      key: apiSignKey,
      expiresAt: DateTime.now().add(const Duration(minutes: 8)),
    );
    _sessions[base] = session;
    debugPrint('[QqovoResolver] bootstrap ok $base');
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

  /// 签名：body 段对 GET 用空字符串（与 music.qqovo.cn 实测一致；勿用 sha256('')）。
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

class QqovoHit {
  const QqovoHit({required this.url, this.auth});
  final String url;
  final String? auth;
}

class _QqovoSession {
  _QqovoSession({required this.key, required this.expiresAt});
  final String key;
  final DateTime expiresAt;
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
