import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import 'discovery_api_client.dart';

/// 在线歌曲下载（可选音质）：解析直链 → 写入公共 Download/MD3Music。
class SongDownloadService {
  SongDownloadService._();
  static final SongDownloadService instance = SongDownloadService._();

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 120),
  ));

  /// 按音源给出可选下载音质（value → 展示名）。
  static List<({String value, String label})> qualitiesFor(Song song) {
    switch (song.source) {
      case 'qq':
        return const [
          (value: 'flac', label: 'SQ 无损'),
          (value: '320', label: 'HQ 高品质'),
          (value: '128', label: '标准'),
        ];
      case 'soda':
        return const [
          (value: 'exhigh', label: '极高'),
          (value: 'standard', label: '标准'),
        ];
      case 'netease':
        return const [
          (value: 'jymaster', label: '高清臻音'),
          (value: 'hires', label: 'Hi-Res'),
          (value: 'lossless', label: '无损'),
          (value: 'exhigh', label: '极高'),
          (value: 'standard', label: '标准'),
        ];
      default:
        return AudioQuality.values
            .map((q) => (value: q.value, label: q.label))
            .toList();
    }
  }

  Future<File> download(Song song, {required String quality}) async {
    if (kIsWeb) throw StateError('Web 不支持下载');
    await _ensureStoragePermission();

    String? url;
    if (song.isRemoteDiscovery) {
      url = await DiscoveryApiClient().resolvePlayUrl(
        source: song.source!,
        id: song.remoteTrackId,
        quality: quality,
      );
    } else if (song.source == 'kugou' || (song.isOnline && song.source == null)) {
      final result = await KugouApiClient().getSongUrlWithFallback(
        song.id,
        quality: quality,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );
      url = result?.url;
    } else if (song.url != null && song.url!.startsWith('http')) {
      url = song.url;
    } else {
      throw StateError('当前歌曲无法解析下载地址');
    }
    if (url == null || url.isEmpty) {
      throw StateError('无法获取下载地址（可能需会员）');
    }

    // 汽水解密后是本地文件：复制到 Download
    if (url.startsWith('file:') || !url.startsWith('http')) {
      final src = url.startsWith('file:')
          ? File(Uri.parse(url).toFilePath())
          : File(url);
      if (!await src.exists()) throw StateError('本地缓存已失效，请重试');
      final dest = await _destFile(song, quality, src.path.split('.').last);
      await src.copy(dest.path);
      return dest;
    }

    final ext = _guessExt(url, quality);
    final dest = await _destFile(song, quality, ext);
    await _dio.download(
      url,
      dest.path,
      options: Options(headers: _cdnHeaders(url)),
    );
    if (await dest.length() < 1024) {
      try {
        await dest.delete();
      } catch (_) {}
      throw StateError('下载文件过小，可能失败');
    }
    return dest;
  }

  Map<String, String>? _cdnHeaders(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    const chromeUa =
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Mobile Safari/537.36';
    if (host.contains('qq.com') ||
        host.contains('gtimg') ||
        host.contains('qqmusic') ||
        host.contains('tencentmusic')) {
      return {'User-Agent': chromeUa, 'Referer': 'https://y.qq.com/'};
    }
    if (host.contains('music.126.net') ||
        host.contains('163.com') ||
        host.contains('netease')) {
      return {'User-Agent': chromeUa, 'Referer': 'https://music.163.com/'};
    }
    if (host.contains('qqovo')) {
      return {'User-Agent': chromeUa, 'Referer': 'https://music.qqovo.cn/'};
    }
    return {'User-Agent': chromeUa};
  }

  Future<void> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return;
    // Android 13+ 媒体权限；更早用存储权限
    final photos = await Permission.photos.request();
    if (photos.isGranted) return;
    final storage = await Permission.storage.request();
    if (!storage.isGranted && !storage.isLimited) {
      // 仍继续尝试应用专属目录
      debugPrint('[SongDownload] storage permission: $storage');
    }
  }

  Future<File> _destFile(Song song, String quality, String ext) async {
    Directory dir;
    try {
      dir = Directory(
        '${(await getExternalStorageDirectory())?.path ?? (await getApplicationDocumentsDirectory()).path}/MD3Music',
      );
      // 优先公共 Download（若可写）
      final publicDl = Directory('/storage/emulated/0/Download/MD3Music');
      if (await publicDl.parent.exists()) {
        try {
          if (!await publicDl.exists()) await publicDl.create(recursive: true);
          final probe = File('${publicDl.path}/.probe');
          await probe.writeAsString('ok');
          await probe.delete();
          dir = publicDl;
        } catch (_) {}
      }
    } catch (_) {
      dir = await getApplicationDocumentsDirectory();
      dir = Directory('${dir.path}/MD3Music');
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    final safe = '${song.artist} - ${song.displayName}'
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    return File('${dir.path}/${safe}_$quality.$ext');
  }

  String _guessExt(String url, String quality) {
    final lower = url.toLowerCase();
    if (lower.contains('.flac') || quality == 'flac' || quality == 'lossless') {
      return 'flac';
    }
    if (lower.contains('.m4a') || lower.contains('audio_mp4')) return 'm4a';
    if (lower.contains('.ogg')) return 'ogg';
    return 'mp3';
  }

  /// 弹出音质选择并下载。
  static Future<void> pickAndDownload(BuildContext context, Song song) async {
    if (!song.isOnline) {
      showToast('本地歌曲无需下载');
      return;
    }
    final options = qualitiesFor(song);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Center(child: Text('选择下载音质'))),
              const Divider(height: 1),
              ...options.map(
                (o) => ListTile(
                  title: Text(o.label),
                  onTap: () => Navigator.pop(ctx, o.value),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (chosen == null || !context.mounted) return;
    showToast('正在下载…');
    try {
      final file = await SongDownloadService.instance.download(
        song,
        quality: chosen,
      );
      if (!context.mounted) return;
      showToast('已保存：${file.path}', long: true);
    } catch (e) {
      if (!context.mounted) return;
      showToast('下载失败：$e', long: true);
    }
  }
}
