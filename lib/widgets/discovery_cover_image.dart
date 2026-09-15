import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 发现页封面：汽水 CDN 对部分模板/无 UA 会 403。
class DiscoveryCoverImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final int? memCacheWidth;
  final Widget? error;

  const DiscoveryCoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.memCacheWidth,
    this.error,
  });

  static const _lunaUa =
      'com.luna.music/100198030 (Linux; U; Android 15; zh_CN_#Hans; '
      'ABR-AL80; Build/V417IR;tt-ok/3.12.13.19)';

  /// http → https（网易封面常返回 http://p*.music.126.net，Android 禁明文会空白）。
  static String httpsify(String url) {
    final u = url.trim();
    if (u.startsWith('http://')) return 'https://${u.substring(7)}';
    return u;
  }

  static Map<String, String>? headersFor(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.contains('douyinpic') ||
        host.contains('douyinvod') ||
        host.contains('byteimg') ||
        host.contains('qishui') ||
        host.contains('luna')) {
      return {
        'User-Agent': _lunaUa,
        'Referer': 'https://www.qishui.com/',
      };
    }
    if (host.contains('qq.com') ||
        host.contains('gtimg') ||
        host.contains('qpic')) {
      return {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        'Referer': 'https://y.qq.com/',
      };
    }
    if (host.contains('music.126.net') || host.contains('163.com')) {
      return {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        'Referer': 'https://music.163.com/',
      };
    }
    if (host.contains('qqovo')) {
      return {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        'Referer': 'https://music.qqovo.cn/',
      };
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = error ??
        ColoredBox(
          color: cs.surfaceContainerHighest,
          child: const Icon(Icons.music_note),
        );
    if (url.isEmpty) return fallback;
    final imageUrl = httpsify(url);
    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: fit,
      memCacheWidth: memCacheWidth,
      httpHeaders: headersFor(imageUrl),
      errorWidget: (_, __, ___) => fallback,
    );
  }
}
