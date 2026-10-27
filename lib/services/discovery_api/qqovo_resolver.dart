import 'dart:convert';
import 'dart:math';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';

import 'qqovo_auth.dart';

/// qqovo meting 直链解析（国内优先 music.qqovo.cn，失败再试 qqovo.top）。
///
/// 上游改版后**匿名调用已关闭**：`/api/session/bootstrap` 不再下发
/// `apiSignKey`，meting 的 url/lrc/search 与 `/api/music/hot` 一律
/// `401 ACCOUNT_AUTH_REQUIRED`。因此现在优先使用用户在设置里填的
/// 网页登录 Cookie（见 [QqovoAuth]）；没有 Cookie 时仍保留老签名链路，
/// 仅 `type=pic` 这类公开接口还能用。
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

  /// Cookie 登录态专用：不带 CookieManager，避免拦截器覆盖手工设置的
  /// `Cookie` 头（网页登录的 openmusic_* 与匿名会话互不兼容）。
  static final Dio _cookieDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 20),
  ));

  static Dio _dioFor(_QqovoSession session) =>
      session.usesCookie ? _cookieDio : _sharedDio;

  /// 带登录态的 GET：401 时用 `openmusic_account_refresh` 续期一次再重试。
  Future<Response<dynamic>> _authedGet(
    String base,
    String url,
    _QqovoSession session, {
    bool followRedirects = true,
  }) async {
    Future<Response<dynamic>> send(_QqovoSession s) => _dioFor(s).get(
          url,
          options: Options(
            headers: _headersFor(base, url, s),
            followRedirects: followRedirects,
            validateStatus: (c) => c != null && c < 600,
          ),
        );

    var resp = await send(session);
    if (resp.statusCode == 401 && session.usesCookie) {
      final renewed = await QqovoAuth.instance.refreshSession();
      if (!renewed) return resp;
      final next = await _ensureSession(base);
      if (next == null) return resp;
      resp = await send(next);
      _absorbSetCookie(next, resp);
    }
    return resp;
  }

  /// 跟住服务端下发的 Cookie（续期后 session/refresh 值会变）。
  static void _absorbSetCookie(_QqovoSession session, Response<dynamic> resp) {
    if (!session.usesCookie) return;
    final raw = resp.headers.map['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    // 落盘失败不影响本次请求
    // ignore: discarded_futures
    QqovoAuth.instance.mergeSetCookies(raw);
  }

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
    final pref = preference.trim().toLowerCase();
    if (server == 'tencent') {
      const chain = [
        'atmos',
        'master',
        'flac',
        'ogg',
        '320',
        '128',
      ];
      return _qualityCascade(chain, pref, const {
        'atmos': 'atmos',
        'master': 'master',
        'flac': 'flac',
        'high': 'atmos', // AudioQuality.hires.value
        'ogg': 'ogg',
        '320': '320',
        '128': '128',
        'sq': 'flac',
      });
    }
    if (server == 'qishui') {
      const chain = [
        'viper_hifi',
        'viper_atmos',
        'viper_tape',
        'viper_clear',
        'studio',
        'hires',
        'lossless',
        'exhigh',
        '320',
        'higher',
        'standard',
        '128',
      ];
      return _qualityCascade(chain, pref, const {
        'viper_hifi': 'viper_hifi',
        'viper_atmos': 'viper_atmos',
        'viper_tape': 'viper_tape',
        'viper_clear': 'viper_clear',
        'studio': 'studio',
        'atmos': 'viper_hifi',
        'master': 'viper_hifi',
        'hires': 'hires',
        'high': 'viper_hifi',
        'flac': 'lossless',
        'lossless': 'lossless',
        'exhigh': 'exhigh',
        '320': 'exhigh',
        'higher': 'exhigh',
        'standard': 'standard',
        '128': 'standard',
      });
    }
    // netease：VIP 只试顶两档，随后直接无损/极高，避免 10 次串行卡死
    const chain = [
      'sky',
      'jymaster',
      'lossless',
      'exhigh',
      'standard',
    ];
    return _qualityCascade(chain, pref, const {
      'sky': 'sky',
      'jymaster': 'jymaster',
      'dolby': 'sky',
      'jyeffect': 'jymaster',
      'atmos': 'sky',
      'master': 'jymaster',
      'viper_hifi': 'jymaster',
      'hires': 'lossless',
      'high': 'jymaster',
      'flac': 'lossless',
      'lossless': 'lossless',
      'exhigh': 'exhigh',
      '320': 'exhigh',
      'higher': 'exhigh',
      'standard': 'standard',
      '128': 'standard',
    });
  }

  /// 从 [preference] 对应档位起向下试；VIP 档一律从链顶开试（接口有最高就拿最高）。
  static List<String> _qualityCascade(
    List<String> chain,
    String preference,
    Map<String, String> aliases,
  ) {
    final startKey = aliases[preference] ?? preference;
    const vip = {
      'atmos',
      'master',
      'sky',
      'jymaster',
      'dolby',
      'jyeffect',
      'viper_hifi',
      'viper_atmos',
      'viper_tape',
      'viper_clear',
      'studio',
    };
    if (vip.contains(startKey) || vip.contains(preference)) {
      return List<String>.from(chain);
    }
    final idx = chain.indexOf(startKey);
    if (idx <= 0) return List<String>.from(chain);
    return chain.sublist(idx);
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
        final resp = await _authedGet(base, url, session);
        if (resp.statusCode == 401) {
          // 续期也救不回来：新版上游必须带网页登录 Cookie
          QqovoAuth.instance.markAuthRequired();
          return null;
        }
        _absorbSetCookie(session, resp);
        if (resp.statusCode == 403) {
          _sessions.remove(base);
          await _cookieJar.delete(Uri.parse(base));
          continue;
        }
        // pic 匿名也能 200，不能据此判定登录态
        if (resp.statusCode == 200 && type != 'pic') {
          QqovoAuth.instance.markAuthOk();
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
        final resp = await _authedGet(base, url, session);
        if (resp.statusCode == 401) {
          QqovoAuth.instance.markAuthRequired();
          return const [];
        }
        if (resp.statusCode == 403) {
          _sessions.remove(base);
          await _cookieJar.delete(Uri.parse(base));
          continue;
        }
        _absorbSetCookie(session, resp);
        QqovoAuth.instance.markAuthOk();
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

      QqovoHit? best;
      var bestRank = -1;

      for (final quality in qualities) {
        final trackUrl =
            '$base/api/meting?server=$server&type=url&id=$songId&quality=$quality';
        final trackResp = await _authedGet(base, trackUrl, session);
        if (trackResp.statusCode == 401) {
          // 未登录 / 凭证失效：整条音质链都没意义，直接交给上层兜底
          QqovoAuth.instance.markAuthRequired();
          debugPrint('[QqovoResolver] 401 on $base — 需要登录 Cookie');
          return best;
        }
        if (trackResp.statusCode == 403) {
          debugPrint('[QqovoResolver] 403 on $base — clear session/cookies');
          _sessions.remove(base);
          await _cookieJar.delete(Uri.parse(base));
          return best;
        }
        if (trackResp.statusCode != 200) continue;
        _absorbSetCookie(session, trackResp);
        QqovoAuth.instance.markAuthOk();
        final data = trackResp.data;
        if (data is! Map) continue;
        final errText = '${data['error'] ?? ''}'.trim();
        if (errText.isNotEmpty) {
          // 例如「未绑定音乐账号」「该音质需要 VIP」：留给诊断日志排查
          debugPrint('[QqovoResolver] $server/$songId q=$quality -> $errText');
        }

        var playUrl = '${data['url'] ?? ''}'.trim();
        var auth = '${data['auth'] ?? ''}'.trim();
        final returnedLabel = '${data['quality'] ?? ''}'.trim();
        // 相对路径补全
        if (playUrl.startsWith('/')) {
          playUrl = '$base$playUrl';
        }
        // 汽水：先给 /api/qishui-source，再二次取 CDN + auth
        if (playUrl.startsWith('http') &&
            (playUrl.contains('qqovo.') ||
                playUrl.contains('/api/qishui') ||
                playUrl.contains('/api/'))) {
          final sourceResp = await _authedGet(base, playUrl, session);
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
        if (!playUrl.startsWith('http')) continue;

        final label = returnedLabel.isNotEmpty ? returnedLabel : quality;
        final rank = qualityRank(server: server, keyOrLabel: label);
        final reqRank = qualityRank(server: server, keyOrLabel: quality);
        final hit = QqovoHit(
          url: playUrl,
          auth: auth.isEmpty ? null : auth,
          quality: label,
          requestedQuality: quality,
        );
        if (rank > bestRank) {
          best = hit;
          bestRank = rank;
        }
        debugPrint(
          '[QqovoResolver] try $server/$songId q=$quality -> $label '
          'rank=$rank reqRank=$reqRank auth=${auth.isNotEmpty}',
        );
        // 命中请求档，或已有无损级以上可播：立刻收下，避免 VIP 链把起播拖死
        if (rank >= reqRank || bestRank >= 80) {
          return best ?? hit;
        }
      }
      return best;
    } catch (e) {
      debugPrint('[QqovoResolver] $base $server/$songId failed: $e');
      _sessions.remove(base);
    }
    return null;
  }

  /// 音质档位排序：越大越好。兼容 qqovo 返回的中文 `quality` 与请求 key。
  static int qualityRank({
    required String server,
    required String keyOrLabel,
  }) {
    final q = keyOrLabel.trim().toLowerCase();
    if (q.isEmpty) return 0;
    bool has(String s) => q.contains(s);
    if (server == 'tencent') {
      if (has('全景') || q == 'atmos' || has('q000')) return 100;
      if (has('母带') || q == 'master' || has('ai00') || has('臻品母带')) {
        return 95;
      }
      if (has('sq') || q == 'flac' || q == 'ogg' || has('无损')) return 80;
      if (has('hq') || q == '320' || has('高品')) return 50;
      if (has('标准') || q == '128' || q == 'standard') return 20;
      return 10;
    }
    if (server == 'qishui') {
      if (has('viper_hifi') || has('蝰蛇hifi') || has('蝰蛇 hifi')) return 100;
      if (has('viper_atmos') || has('蝰蛇全景')) return 96;
      if (has('viper_tape') || has('蝰蛇母带')) return 94;
      if (has('viper_clear') || has('蝰蛇超清')) return 92;
      if (has('studio') || has('录音室')) return 88;
      if (q == 'hires' || has('hi-res') || has('hires')) return 85;
      if (q == 'lossless' || has('无损') || q == 'flac') return 80;
      if (q == 'exhigh' || q == '320' || q == 'higher' || has('极高')) return 50;
      if (q == 'standard' || q == '128' || has('标准')) return 20;
      return 10;
    }
    // netease
    if (has('环绕') || q == 'sky') return 100;
    if (has('母带') || q == 'jymaster' || has('超清')) return 98;
    if (has('杜比') || q == 'dolby') return 97;
    if (has('臻音') || q == 'jyeffect') return 90;
    if (q == 'hires' || has('hi-res') || has('hires')) return 85;
    if (q == 'lossless' || has('无损') || q == 'flac') return 80;
    if (q == 'exhigh' || q == '320' || q == 'higher' || has('极高')) return 50;
    if (q == 'standard' || q == '128' || has('标准')) return 20;
    return 10;
  }

  /// 远程源歌词：qqovo `type=lrc`（比酷狗按歌名搜稳，QQ/网易/汽水专用 id）。
  /// 返回 LRC/纯文本；失败返回 null。
  Future<String?> resolveLyricLrc({
    required String server,
    required String id,
  }) async {
    final songId = id.trim();
    if (songId.isEmpty || server.isEmpty) return null;
    try {
      final data = await meting(server: server, type: 'lrc', id: songId);
      if (data == null) return null;
      if (data is String) {
        final s = data.trim();
        if (s.isEmpty) return null;
        // 偶发返回直链
        if (s.startsWith('http://') || s.startsWith('https://')) {
          return await _fetchLyricBody(s);
        }
        // 拒绝 HTML/JSON 错误页
        if (s.startsWith('<') || s.startsWith('{')) return null;
        return s;
      }
      if (data is Map) {
        final raw = '${data['lrc'] ?? data['lyric'] ?? data['content'] ?? ''}'.trim();
        if (raw.isEmpty) return null;
        if (raw.startsWith('http://') || raw.startsWith('https://')) {
          return await _fetchLyricBody(raw);
        }
        return raw;
      }
    } catch (e) {
      debugPrint('[QqovoResolver] resolveLyric $server/$id failed: $e');
    }
    return null;
  }

  Future<String?> _fetchLyricBody(String url) async {
    try {
      final resp = await _dio.get(
        url,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (c) => c != null && c < 500,
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      final body = '${resp.data ?? ''}'.trim();
      if (body.isEmpty || body.startsWith('<')) return null;
      return body;
    } catch (e) {
      debugPrint('[QqovoResolver] fetch lyric body failed: $e');
      return null;
    }
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
        final resp = await _authedGet(
          base,
          url,
          session,
          followRedirects: false,
        );
        if (resp.statusCode == 403) {
          _sessions.remove(base);
          await _cookieJar.delete(Uri.parse(base));
          continue;
        }
        _absorbSetCookie(session, resp);
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
    // ① 网页登录 Cookie 优先：新版上游只认凭证，已不需要签名握手
    final cookie = QqovoAuth.instance.cookie;
    if (cookie.isNotEmpty) {
      final cached = _sessions[base];
      if (cached != null &&
          cached.cookie == cookie &&
          !cached.isExpired) {
        return cached;
      }
      final session = _QqovoSession(
        key: '',
        cookie: cookie,
        expiresAt: DateTime.now().add(const Duration(minutes: 30)),
      );
      _sessions[base] = session;
      return session;
    }

    final cached = _sessions[base];
    if (cached != null && !cached.isExpired) return cached;

    // ② 无 Cookie：老匿名链路（上游已关，仅 pic 等公开接口还能用）
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
      // bootstrap 已不再下发 apiSignKey：缓存一个无签名会话，
      // 避免每次取封面都重新握手（url/lrc 会被 401 拦下并提示登录）。
      final session = _QqovoSession(
        key: '',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      _sessions[base] = session;
      debugPrint(
        '[QqovoResolver] bootstrap 无 apiSignKey（上游要求登录）'
        'status=${boot.statusCode} $base',
      );
      return session;
    }
    final session = _QqovoSession(
      key: apiSignKey,
      expiresAt: DateTime.now().add(const Duration(minutes: 8)),
    );
    _sessions[base] = session;
    debugPrint('[QqovoResolver] bootstrap ok $base');
    return session;
  }

  /// 清掉会话缓存（用户改/删了 Cookie 后调用）。
  static void resetSessions() {
    _sessions.clear();
  }

  Map<String, String> _browserHeaders(String base) => {
        'Accept': '*/*',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        'Referer': '$base/',
        'Origin': base,
      };

  /// 请求头：有登录 Cookie 就带上（只发给 qqovo 自己的域，别泄漏给 CDN）；
  /// 没有 Cookie 时退回老的 HMAC 签名（上游已废弃，保留兼容）。
  Map<String, String> _headersFor(
    String base,
    String url,
    _QqovoSession session,
  ) {
    final headers = <String, String>{..._browserHeaders(base)};
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (session.cookie.isNotEmpty &&
        (host.isEmpty || host.contains('qqovo'))) {
      headers['Cookie'] = session.cookie;
    }
    final apiSignKey = session.key;
    if (apiSignKey.isEmpty) return headers;

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
    headers['X-OM-Ts'] = timestamp;
    headers['X-OM-Nonce'] = nonce;
    headers['X-OM-Sign'] = sign;
    return headers;
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
  const QqovoHit({
    required this.url,
    this.auth,
    this.quality,
    this.requestedQuality,
  });
  final String url;
  final String? auth;
  /// 接口实际返回的音质名（中文或 key），用于角标。
  final String? quality;
  final String? requestedQuality;
}

class _QqovoSession {
  _QqovoSession({
    required this.key,
    required this.expiresAt,
    this.cookie = '',
  });
  final String key;

  /// 网页登录 Cookie（新版上游唯一凭证）。
  final String cookie;
  final DateTime expiresAt;
  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get usesCookie => cookie.isNotEmpty;
}
