import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// 远程版本配置（仓库根目录 [update.json]，经 raw.githubusercontent 拉取）。
///
/// 操作方式：改 `update.json` 后推到 `main` 即可生效，无需发新包改弹框逻辑。
/// - [force] true：强制更新，不可关闭，只能点「立即更新」跳转 [url]
/// - [minBuild]/[minVersion]：低于此版本一律强制
/// - [url]：跳转目标（Release 页 / 网盘 / 任意 https 链接）
class AppUpdateInfo {
  final String latestVersion;
  final int latestBuild;
  final String minVersion;
  final int minBuild;
  final bool force;
  final String url;
  final String title;
  final String message;

  const AppUpdateInfo({
    required this.latestVersion,
    required this.latestBuild,
    required this.minVersion,
    required this.minBuild,
    required this.force,
    required this.url,
    required this.title,
    required this.message,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      latestVersion: json['latestVersion']?.toString() ?? '0.0.0',
      latestBuild: (json['latestBuild'] as num?)?.toInt() ?? 0,
      minVersion: json['minVersion']?.toString() ?? '0.0.0',
      minBuild: (json['minBuild'] as num?)?.toInt() ?? 0,
      force: json['force'] == true,
      url: json['url']?.toString() ??
          'https://github.com/nlxxtw/md3Music-Next/releases/latest',
      title: json['title']?.toString() ?? '发现新版本',
      message: json['message']?.toString() ?? '有新版本可用，请更新后继续使用。',
    );
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

  /// 改这个地址即可换配置源（须为可公网访问的 JSON）。
  static const configUrl =
      'https://raw.githubusercontent.com/nlxxtw/md3Music-Next/main/update.json';

  static const _fallbackUrl =
      'https://github.com/nlxxtw/md3Music-Next/releases/latest';

  bool _checking = false;

  /// 启动后调用一次：拉取配置 → 比较版本 → 弹框。
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

  /// 打开配置里的跳转地址（设置页「更新最新版本」也可调）。
  /// 返回是否成功唤起外部浏览器。
  Future<bool> openUpdateUrl({String? overrideUrl}) async {
    final url = overrideUrl ??
        (await _fetchInfo())?.url ??
        _fallbackUrl;
    return launchExternalUrl(url);
  }

  /// 直接尝试打开链接。Android 11+ 上 [canLaunchUrl] 常误报 false，故不作为前置条件。
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
    final uri = Uri.parse(configUrl).replace(
      queryParameters: {'t': '${DateTime.now().millisecondsSinceEpoch}'},
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) return null;
    return AppUpdateInfo.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// 当前是否低于目标：优先比 versionCode（build），再比 semver。
  static bool _isOlder(
    String curVer,
    int curBuild,
    String targetVer,
    int targetBuild,
  ) {
    if (targetBuild > 0 && curBuild > 0) {
      if (curBuild < targetBuild) return true;
      if (curBuild > targetBuild) return false;
    }
    return _compareSemver(curVer, targetVer) < 0;
  }

  static int _compareSemver(String a, String b) {
    List<int> parts(String v) {
      final core = v.split('+').first.split('-').first;
      return core
          .split('.')
          .map((e) => int.tryParse(e) ?? 0)
          .toList();
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
              '最新：${info.latestVersion} (${info.latestBuild})',
            ),
            actions: [
              if (!force)
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('稍后'),
                ),
              FilledButton(
                onPressed: () async {
                  final ok = await launchExternalUrl(info.url);
                  if (!ok) {
                    debugPrint('showUpdateDialog: failed to open ${info.url}');
                  }
                  // 强制更新：跳转后仍留在弹框，避免继续使用旧版
                  if (!force && ctx.mounted) {
                    Navigator.of(ctx).pop();
                  }
                },
                child: const Text('立即更新'),
              ),
            ],
          ),
        );
      },
    );
  }
}
