import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// GitHub 国内加速（用户提供的 fuck123 节点）。
///
/// 用法：`GithubAccel.wrap('https://github.com/...')`
/// → `https://github.fuck123.de5.net/https://github.com/...`
class GithubAccel {
  static const host = 'https://github.fuck123.de5.net';

  /// 把任意 GitHub / raw.githubusercontent 链接包一层加速。
  static String wrap(String url) {
    final u = url.trim();
    if (u.isEmpty) return u;
    if (u.contains('fuck123.de5.net')) return u;
    final normalized = u.startsWith('http') ? u : 'https://$u';
    return '$host/$normalized';
  }

  static bool isGithubAsset(String url) {
    final u = url.toLowerCase();
    return u.contains('github.com') || u.contains('githubusercontent.com');
  }
}

/// 远程版本配置（仓库根目录 [update.json]）。
class AppUpdateInfo {
  final String latestVersion;
  final int latestBuild;
  final String minVersion;
  final int minBuild;
  final bool force;
  final String url;
  final String? apkUrl;
  final String title;
  final String message;

  const AppUpdateInfo({
    required this.latestVersion,
    required this.latestBuild,
    required this.minVersion,
    required this.minBuild,
    required this.force,
    required this.url,
    this.apkUrl,
    required this.title,
    required this.message,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    final version = json['latestVersion']?.toString() ?? '0.0.0';
    final releaseUrl = json['url']?.toString() ??
        'https://github.com/nlxxtw/md3Music-Next/releases/latest';
    final apk = json['apkUrl']?.toString();
    return AppUpdateInfo(
      latestVersion: version,
      latestBuild: (json['latestBuild'] as num?)?.toInt() ?? 0,
      minVersion: json['minVersion']?.toString() ?? '0.0.0',
      minBuild: (json['minBuild'] as num?)?.toInt() ?? 0,
      force: json['force'] == true,
      url: releaseUrl,
      apkUrl: (apk != null && apk.isNotEmpty)
          ? apk
          : 'https://github.com/nlxxtw/md3Music-Next/releases/download/v$version/app-arm64-v8a-release.apk',
      title: json['title']?.toString() ?? '发现新版本',
      message: json['message']?.toString() ?? '有新版本可用，请更新后继续使用。',
    );
  }

  /// 经国内加速的 APK 直链（在线安装用）。
  String get acceleratedApkUrl {
    final raw = apkUrl ??
        'https://github.com/nlxxtw/md3Music-Next/releases/download/v$latestVersion/app-arm64-v8a-release.apk';
    return GithubAccel.wrap(raw);
  }
}

enum AppUpdateKind { none, soft, force }

class AppUpdateDecision {
  final AppUpdateKind kind;
  final AppUpdateInfo info;
  final String currentVersion;
  final int currentBuild;

  const AppUpdateDecision({
    required this.kind,
    required this.info,
    required this.currentVersion,
    required this.currentBuild,
  });
}

/// 启动时检查远程 [update.json]，弹出可选 / 强制更新对话框。
class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const _installChannel = MethodChannel('com.md3music.md3music/apk_install');

  static const _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/120.0.0.0 Mobile Safari/537.36',
    'Accept': '*/*',
  };

  /// 主源 + 国内加速镜像（fuck123 优先）。
  static const configUrls = <String>[
    'https://github.fuck123.de5.net/https://raw.githubusercontent.com/nlxxtw/md3Music-Next/main/update.json',
    'https://cdn.jsdelivr.net/gh/nlxxtw/md3Music-Next@main/update.json',
    'https://ghproxy.net/https://raw.githubusercontent.com/nlxxtw/md3Music-Next/main/update.json',
    'https://raw.githubusercontent.com/nlxxtw/md3Music-Next/main/update.json',
  ];

  static const fallbackReleaseUrl =
      'https://github.com/nlxxtw/md3Music-Next/releases/latest';

  bool _checking = false;

  Future<void> checkAndPrompt(BuildContext context) async {
    if (kIsWeb || _checking) return;
    _checking = true;
    try {
      final decision = await evaluate();
      if (decision == null || decision.kind == AppUpdateKind.none) return;
      if (!context.mounted) return;
      await showUpdateDialog(context, decision);
    } catch (e, st) {
      debugPrint('AppUpdateService.checkAndPrompt failed: $e\n$st');
    } finally {
      _checking = false;
    }
  }

  /// 打开下载页 / 加速直链。
  /// [skipRemoteLookup]：网络已失败时不要再等 update.json。
  Future<bool> openUpdateUrl({
    String? overrideUrl,
    bool skipRemoteLookup = false,
    bool preferAccelApk = true,
  }) async {
    String url = overrideUrl ?? fallbackReleaseUrl;
    if (overrideUrl == null && !skipRemoteLookup) {
      final info = await _fetchInfo();
      if (info != null) {
        url = preferAccelApk ? info.acceleratedApkUrl : info.url;
      } else {
        url = GithubAccel.wrap(fallbackReleaseUrl);
      }
    } else if (overrideUrl != null &&
        preferAccelApk &&
        GithubAccel.isGithubAsset(overrideUrl) &&
        !overrideUrl.contains('fuck123.de5.net')) {
      url = GithubAccel.wrap(overrideUrl);
    }
    return launchExternalUrl(url);
  }

  static Future<bool> launchExternalUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, st) {
      debugPrint('launchExternalUrl failed: $e\n$st');
      return false;
    }
  }

  Future<AppUpdateDecision?> evaluate() async {
    final info = await _fetchInfo();
    if (info == null) return null;

    final pkg = await PackageInfo.fromPlatform();
    final currentVersion = pkg.version;
    final currentBuild = int.tryParse(pkg.buildNumber) ?? 0;

    final belowMin = _isOlder(
      currentVersion,
      currentBuild,
      info.minVersion,
      info.minBuild,
    );
    final belowLatest = _isOlder(
      currentVersion,
      currentBuild,
      info.latestVersion,
      info.latestBuild,
    );

    if (!belowLatest && !belowMin) {
      return AppUpdateDecision(
        kind: AppUpdateKind.none,
        info: info,
        currentVersion: currentVersion,
        currentBuild: currentBuild,
      );
    }

    final force = belowMin || (info.force && belowLatest);
    return AppUpdateDecision(
      kind: force ? AppUpdateKind.force : AppUpdateKind.soft,
      info: info,
      currentVersion: currentVersion,
      currentBuild: currentBuild,
    );
  }

  Future<AppUpdateInfo?> _fetchInfo() async {
    final stamp = '${DateTime.now().millisecondsSinceEpoch}';
    final futures = configUrls.map((base) async {
      final uri = Uri.parse(base).replace(queryParameters: {'t': stamp});
      final resp = await http
          .get(uri, headers: _browserHeaders)
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        throw StateError('HTTP ${resp.statusCode} $base');
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map) throw StateError('bad json $base');
      return AppUpdateInfo.fromJson(Map<String, dynamic>.from(decoded));
    }).toList();

    try {
      return await Future.any(futures);
    } catch (_) {
      for (final base in configUrls) {
        try {
          final uri = Uri.parse(base).replace(queryParameters: {'t': stamp});
          final resp = await http
              .get(uri, headers: _browserHeaders)
              .timeout(const Duration(seconds: 10));
          if (resp.statusCode != 200) continue;
          final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
          if (decoded is! Map) continue;
          return AppUpdateInfo.fromJson(Map<String, dynamic>.from(decoded));
        } catch (e) {
          debugPrint('AppUpdateService fetch miss $base: $e');
        }
      }
    }
    return null;
  }

  /// 经加速节点下载 APK 并调起系统安装器。
  Future<void> downloadAndInstall(
    BuildContext context,
    AppUpdateInfo info,
  ) async {
    if (kIsWeb) {
      await openUpdateUrl(overrideUrl: info.acceleratedApkUrl);
      return;
    }

    final apkUrl = info.acceleratedApkUrl;
    final progress = ValueNotifier<double?>(0);
    var cancelled = false;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('正在下载更新'),
            content: ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (_, p, __) {
                final pct = p == null ? null : (p * 100).clamp(0, 100);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      pct == null
                          ? '连接加速节点…'
                          : '已下载 ${pct.toStringAsFixed(0)}%',
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: p),
                    const SizedBox(height: 8),
                    Text(
                      '经 github.fuck123.de5.net 加速\n${info.latestVersion}',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                );
              },
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.of(ctx).pop();
                },
                child: const Text('取消'),
              ),
            ],
          ),
        );
      },
    );

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/md3music-update.apk');
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }

      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(apkUrl));
        req.headers.addAll(_browserHeaders);
        req.headers['Referer'] = '${GithubAccel.host}/';
        final streamed = await client.send(req).timeout(
              const Duration(seconds: 30),
            );
        if (streamed.statusCode != 200) {
          throw StateError('下载失败 HTTP ${streamed.statusCode}');
        }
        final total = streamed.contentLength ?? 0;
        final sink = file.openWrite();
        var received = 0;
        await for (final chunk in streamed.stream) {
          if (cancelled) {
            await sink.close();
            try {
              await file.delete();
            } catch (_) {}
            return;
          }
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            progress.value = received / total;
          } else {
            progress.value = null;
          }
        }
        await sink.close();
      } finally {
        client.close();
      }

      if (cancelled) return;
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

      final ok = await _installChannel.invokeMethod<bool>('installApk', {
        'path': file.path,
      });
      if (ok != true && context.mounted) {
        // 安装器唤起失败：退回浏览器打开加速直链
        await openUpdateUrl(overrideUrl: apkUrl, preferAccelApk: false);
      }
    } catch (e, st) {
      debugPrint('downloadAndInstall failed: $e\n$st');
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败：$e，改用浏览器打开…')),
        );
      }
      await openUpdateUrl(overrideUrl: apkUrl, preferAccelApk: false);
    } finally {
      progress.dispose();
    }
  }

  static bool _isOlder(
    String curVer,
    int curBuild,
    String targetVer,
    int targetBuild,
  ) {
    final semver = _compareSemver(curVer, targetVer);
    if (semver != 0) return semver < 0;
    if (targetBuild > 0 && curBuild > 0) {
      return curBuild < targetBuild;
    }
    return false;
  }

  static int _compareSemver(String a, String b) {
    List<int> parts(String v) {
      final core = v.split('+').first.split('-').first;
      return core.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    }

    final pa = parts(a);
    final pb = parts(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  static Future<void> showUpdateDialog(
    BuildContext context,
    AppUpdateDecision decision,
  ) {
    final force = decision.kind == AppUpdateKind.force;
    final info = decision.info;
    return showDialog<void>(
      context: context,
      barrierDismissible: !force,
      builder: (ctx) {
        return PopScope(
          canPop: !force,
          child: AlertDialog(
            title: Text(info.title),
            content: Text(
              '${info.message}\n\n'
              '当前：${decision.currentVersion} (${decision.currentBuild})\n'
              '最新：${info.latestVersion} (${info.latestBuild})\n\n'
              '将经国内 GitHub 加速下载安装。',
            ),
            actions: [
              if (!force)
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('稍后'),
                ),
              TextButton(
                onPressed: () async {
                  await AppUpdateService.instance.openUpdateUrl(
                    overrideUrl: info.url,
                    preferAccelApk: false,
                  );
                },
                child: const Text('打开网页'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  if (!context.mounted) return;
                  await AppUpdateService.instance
                      .downloadAndInstall(context, info);
                },
                child: const Text('在线安装'),
              ),
            ],
          ),
        );
      },
    );
  }
}
