import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// OpenMusic（music.qqovo.cn）登录凭证。
///
/// 上游改版后取消了匿名访问：
/// - `POST /api/session/bootstrap` 只回 `{authenticated:false, loginRequired:true}`，
///   不再下发 `apiSignKey`，老的 `X-OM-Sign` HMAC 签名链路已废弃；
/// - `GET /api/meting?type=url|lrc|search`、`GET /api/music/hot` 未登录一律
///   `401 {"error":"请先登录账户","code":"ACCOUNT_AUTH_REQUIRED"}`；
/// - 仅 `type=pic`（封面代理）仍可匿名取图。
///
/// 所以现在唯一可行的方式是复用网页登录态：用户在浏览器登录后把 Cookie
/// （`openmusic_token` 等）粘到设置里，客户端请求统一带上该 Cookie。
///
/// 也支持**编译期内置**：构建时传 `--dart-define=QQOVO_COOKIE="..."`，
/// 凭证会被打进包内，首次启动即生效（设置页里仍可覆盖或清空）。
/// 注意内置值可从 APK 中提取，别把带凭证的包公开分发。
class QqovoAuth extends ChangeNotifier {
  QqovoAuth._();

  static final QqovoAuth instance = QqovoAuth._();

  /// 网页端站点（登录页 + 接口域）。
  static const String siteUrl = 'https://music.qqovo.cn';

  /// 登录态核心 Cookie 名（bootstrap 时代的下发值，登录后仍在）。
  static const String tokenCookieName = 'openmusic_token';

  /// 真正的账号会话 Cookie：只带 [tokenCookieName] 会被判 401。
  static const String sessionCookieName = 'openmusic_account_session';

  /// 续期 Cookie：服务端用它换新的会话/令牌。
  static const String refreshCookieName = 'openmusic_account_refresh';

  static const String _prefsKey = 'qqovo_account_cookie';

  /// 编译期内置凭证：`--dart-define=QQOVO_COOKIE="openmusic_token=..."`。
  /// CI 里从仓库 Secrets 注入，用户无需在手机上手动填。
  static const String buildCookieDefine =
      String.fromEnvironment('QQOVO_COOKIE');

  /// 内置凭证归一化后的值（编译期已固定，运行时不再变）。
  static final String _builtInCookie = normalize(buildCookieDefine);

  static const Map<String, String> _browserHeaders = {
    'Accept': '*/*',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Origin': siteUrl,
    'Referer': '$siteUrl/',
  };

  /// 用户在设置里保存的值：`null` = 从未改过（用内置），`''` = 显式清空。
  String? _stored;
  bool _needsLogin = false;
  bool _loaded = false;
  bool _refreshing = false;

  /// 实际生效的 Cookie 请求头（`k=v; k2=v2`），空串表示未配置。
  String get cookie => _stored ?? _builtInCookie;

  bool get hasCookie => cookie.isNotEmpty;

  /// 编译期是否带入了内置凭证。
  bool get hasBuiltIn => _builtInCookie.isNotEmpty;

  /// 当前是否正使用内置凭证（没被设置页覆盖/清空）。
  bool get usingBuiltIn => _stored == null && _builtInCookie.isNotEmpty;

  /// 读取某条 Cookie 的值（没有则 null）。
  String? valueOf(String name) {
    for (final pair in cookie.split(';')) {
      final item = pair.trim();
      final eq = item.indexOf('=');
      if (eq <= 0) continue;
      if (item.substring(0, eq).trim() == name) {
        return item.substring(eq + 1).trim();
      }
    }
    return null;
  }

  /// 账号会话的到期时间：本地解 JWT 的 `exp`，不发请求。
  ///
  /// 实测上游 `openmusic_account_session` 是 EdDSA 的 at+jwt，寿命 3 天；
  /// 响应里不会下发 Set-Cookie（不轮换），到期只能重新登录换一条。
  DateTime? get sessionExpiry {
    final raw = valueOf(sessionCookieName);
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('.');
    if (parts.length < 2) return null;
    try {
      final payload =
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final exp = decoded['exp'];
      if (exp is int) {
        return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      }
    } catch (e) {
      debugPrint('[QqovoAuth] decode session jwt failed: $e');
    }
    return null;
  }

  /// 距离过期还有多久；null 表示无法判断。
  Duration? get sessionRemaining {
    final exp = sessionExpiry;
    if (exp == null) return null;
    return exp.difference(DateTime.now());
  }

  bool get loaded => _loaded;

  /// 上游明确回 401：未登录，或填进去的凭证已失效。
  bool get needsLogin => _needsLogin;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      // 不把 null 归一化成 ''：null 表示「没覆盖过」，要继续用内置凭证
      _stored = prefs.getString(_prefsKey);
    } catch (e) {
      debugPrint('[QqovoAuth] load failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<bool> save(String raw) async {
    final value = normalize(raw);
    _stored = value;
    _loaded = true;
    // 换了新凭证就先当作可用，等真正 401 再提示失效
    _needsLogin = false;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, value);
      return true;
    } catch (e) {
      debugPrint('[QqovoAuth] save failed: $e');
      return false;
    }
  }

  Future<void> clear() async {
    await save('');
  }

  /// 丢掉本地覆盖值，回到编译期内置凭证。
  Future<void> restoreBuiltIn() async {
    _stored = null;
    _loaded = true;
    _needsLogin = false;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (e) {
      debugPrint('[QqovoAuth] restore built-in failed: $e');
    }
  }

  /// 合并服务端下发的 `Set-Cookie`：会话轮换/续期时 token 会变，
  /// 吸收后自动跟着更新，内置凭证也能"活"得更久。
  ///
  /// 只在当前已有凭证时生效——匿名 bootstrap 下发的 guest cookie 不能
  /// 被当成登录态写进来。
  Future<void> mergeSetCookies(List<String> setCookies) async {
    if (!hasCookie || setCookies.isEmpty) return;
    final map = <String, String>{};
    for (final pair in cookie.split(';')) {
      final item = pair.trim();
      final eq = item.indexOf('=');
      if (eq <= 0) continue;
      map[item.substring(0, eq).trim()] = item.substring(eq + 1).trim();
    }
    var changed = false;
    for (final raw in setCookies) {
      final first = raw.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      final key = first.substring(0, eq).trim();
      final value = first.substring(eq + 1).trim();
      if (key.isEmpty) continue;
      final lower = raw.toLowerCase();
      final cleared = value.isEmpty ||
          lower.contains('max-age=0') ||
          lower.contains('expires=thu, 01 jan 1970');
      if (cleared) {
        if (map.remove(key) != null) changed = true;
        continue;
      }
      if (map[key] != value) {
        map[key] = value;
        changed = true;
      }
    }
    if (!changed) return;
    _stored = map.entries.map((e) => '${e.key}=${e.value}').join('; ');
    _needsLogin = false;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _stored!);
    } catch (e) {
      debugPrint('[QqovoAuth] persist rotated cookie failed: $e');
    }
  }

  /// 用 `openmusic_account_refresh` 换一条新的会话（实测接口
  /// `POST /api/auth/refresh`，会话 3 天、refresh 30 天）。
  /// 成功即把服务端下发的新 Cookie 合并保存，返回 true。
  Future<bool> refreshSession() async {
    final current = cookie;
    if (current.isEmpty || !current.contains('$refreshCookieName=')) {
      return false;
    }
    if (_refreshing) return false;
    _refreshing = true;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
      ));
      final resp = await dio.post(
        '$siteUrl/api/auth/refresh',
        data: const <String, dynamic>{},
        options: Options(
          contentType: 'application/json',
          headers: {..._browserHeaders, 'Cookie': current},
          validateStatus: (c) => c != null && c < 600,
        ),
      );
      final fresh = resp.headers.map['set-cookie'] ?? const <String>[];
      if (fresh.isNotEmpty) {
        await mergeSetCookies(fresh);
      } else {
        // 兼容「新值放在 JSON body 里」的实现
        final data = resp.data;
        if (data is Map) {
          final s = '${data['session'] ?? data['sessionToken'] ?? ''}'.trim();
          final r = '${data['refresh'] ?? data['refreshToken'] ?? ''}'.trim();
          final updates = <String>[
            if (s.isNotEmpty) '$sessionCookieName=$s',
            if (r.isNotEmpty) '$refreshCookieName=$r',
          ];
          if (updates.isNotEmpty) await mergeSetCookies(updates);
        }
      }
      final ok = resp.statusCode == 200;
      debugPrint(
        '[QqovoAuth] refresh status=${resp.statusCode} '
        'cookies=${fresh.length}',
      );
      if (ok) markAuthOk();
      return ok;
    } catch (e) {
      debugPrint('[QqovoAuth] refresh failed: $e');
      return false;
    } finally {
      _refreshing = false;
    }
  }

  /// 上游回 401：标记需要登录，UI 据此提示。
  void markAuthRequired() {
    if (_needsLogin) return;
    _needsLogin = true;
    notifyListeners();
  }

  /// 请求成功：清掉「需要登录」标记。
  void markAuthOk() {
    if (!_needsLogin) return;
    _needsLogin = false;
    notifyListeners();
  }

  /// 把用户粘贴的内容规整成 Cookie 请求头。
  ///
  /// 兼容：完整 `Cookie: a=1; b=2`、多行请求头、JSON 对象、
  /// 以及只粘了 `openmusic_token` 的值（形如 `1793113161.xxxx`）。
  static String normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    s = s.replaceFirst(RegExp(r'^cookie\s*:\s*', caseSensitive: false), '');
    if (s.startsWith('{')) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map) {
          final buf = <String>[];
          decoded.forEach((k, v) {
            final key = '$k'.trim();
            final value = '$v'.trim();
            if (key.isEmpty || value.isEmpty) return;
            if (key.startsWith('_')) return;
            buf.add('$key=$value');
          });
          if (buf.isNotEmpty) s = buf.join('; ');
        }
      } catch (_) {
        // 不是 JSON：按普通文本继续
      }
    }
    // DevTools 的 Cookie 表格是「名称<TAB>值」两列，先按行转成 k=v
    if (s.contains('\t') && !s.contains('=')) {
      final rows = <String>[];
      for (final line in s.split(RegExp(r'[\r\n]+'))) {
        final cells = line
            .split('\t')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (cells.length >= 2) rows.add('${cells[0]}=${cells[1]}');
      }
      if (rows.isNotEmpty) s = rows.join('; ');
    }
    // 多行（浏览器复制请求头常见）合并成一行
    s = s.replaceAll(RegExp(r'[\r\n\t]+'), '; ');

    final pairs = <String>[];
    final index = <String, int>{};
    for (final seg in s.split(';')) {
      final item = seg.trim();
      if (item.isEmpty) continue;
      final eq = item.indexOf('=');
      if (eq <= 0) continue;
      final key = item.substring(0, eq).trim();
      final value = item.substring(eq + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      final at = index[key];
      if (at != null) {
        pairs[at] = '$key=$value';
        continue;
      }
      index[key] = pairs.length;
      pairs.add('$key=$value');
    }
    if (pairs.isEmpty) {
      // 只粘了 token 值
      final token = s.replaceAll(RegExp(r'[\s"]+'), '');
      if (token.isEmpty) return '';
      return '$tokenCookieName=$token';
    }
    return pairs.join('; ');
  }

  /// 用账号会话接口探活：`/api/auth/session`（未登录回 401，登录后回账号信息）。
  static Future<QqovoAuthCheck> verify(String raw) async {
    final value = normalize(raw);
    if (value.isEmpty) {
      return const QqovoAuthCheck(false, '没有识别到 Cookie 内容');
    }
    if (!value.contains('$tokenCookieName=') &&
        !value.contains('$sessionCookieName=')) {
      return const QqovoAuthCheck(
        false,
        '缺少 $sessionCookieName / $tokenCookieName，请复制整条 Cookie',
      );
    }
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
    ));
    try {
      final resp = await dio.get(
        '$siteUrl/api/auth/session',
        options: Options(
          headers: {..._browserHeaders, 'Cookie': value},
          validateStatus: (c) => c != null && c < 600,
        ),
      );
      final code = resp.statusCode ?? 0;
      final data = resp.data;
      final map = data is Map ? data : const <String, dynamic>{};
      // 注意：这个接口未登录也回 200，只是 authenticated=false
      final authenticated = map['authenticated'] == true;
      if (code == 200 && authenticated) {
        final account = map['account'];
        final email =
            account is Map ? '${account['email'] ?? ''}'.trim() : '';
        final session = map['session'];
        final expMs = session is Map ? session['expiresAt'] : null;
        var message = email.isEmpty ? '登录态有效' : '登录态有效（$email）';
        if (expMs is num && expMs > 0) {
          final exp = DateTime.fromMillisecondsSinceEpoch(expMs.toInt());
          message = '$message，有效期至 ${_formatTime(exp)}';
        }
        return QqovoAuthCheck(true, message);
      }
      final missingSession = !value.contains('$sessionCookieName=');
      if (missingSession) {
        return QqovoAuthCheck(
          false,
          '只有 $tokenCookieName 不够，请复制整条 Cookie'
              '（关键项 $sessionCookieName）',
        );
      }
      if (code == 401 || code == 403 || code == 200) {
        return const QqovoAuthCheck(
          false,
          '登录态无效或已过期，请重新登录后复制（会话只有 3 天）',
        );
      }
      return QqovoAuthCheck(false, '接口返回 HTTP $code');
    } catch (e) {
      return QqovoAuthCheck(false, '网络错误：$e');
    }
  }

  static String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.month}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// 校验结果：[ok] 为 true 时 [message] 是可展示的说明。
class QqovoAuthCheck {
  const QqovoAuthCheck(this.ok, this.message);

  final bool ok;
  final String message;
}
