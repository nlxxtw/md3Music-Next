import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/song.dart';
import 'qqovo_resolver.dart';

/// musicdl 云端发现 API（推荐 / 排行 / 歌单详情 / 解析播放）。
class DiscoveryApiClient {
  DiscoveryApiClient({String? baseUrl, Dio? dio})
      : baseUrl = (baseUrl ?? defaultBaseUrl).replaceAll(RegExp(r'/+$'), ''),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 45),
              headers: {'Accept': 'application/json'},
            ));

  /// 默认云端地址（可在设置里覆盖）。
  static const String defaultBaseUrl = 'https://music.20262050.xyz';

  final String baseUrl;
  final Dio _dio;

  static const _lunaHeaders = {
    'User-Agent':
        'com.luna.music/100198030 (Linux; U; Android 15; zh_CN_#Hans; '
            'ABR-AL80; Build/V417IR;tt-ok/3.12.13.19)',
    'Referer': 'https://www.qishui.com/',
    'Accept': '*/*',
  };

  Future<List<Song>> searchSongs({
    required String source,
    required String keyword,
    int page = 1,
    int limit = 20,
  }) async {
    final res = await _dio.get('$baseUrl/api/v1/search', queryParameters: {
      'source': source,
      'q': keyword,
      'page': page,
      'limit': limit,
    });
    final list = (res.data['songs'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => songFromDiscovery(Map<String, dynamic>.from(e), source))
        .toList();
  }

  Future<List<DiscoveryPlaylist>> getRecommend(String source) async {
    final res = await _dio.get('$baseUrl/api/v1/recommend', queryParameters: {
      'sources': source,
    });
    final results = (res.data['results'] as List?) ?? const [];
    for (final item in results) {
      if (item is Map && item['source'] == source) {
        final list = (item['playlists'] as List?) ?? const [];
        return list
            .whereType<Map>()
            .map((e) => DiscoveryPlaylist.fromJson(
                Map<String, dynamic>.from(e), source))
            .toList();
      }
    }
    return const [];
  }

  Future<List<DiscoveryToplist>> getToplists({String source = 'qq'}) async {
    final res = await _dio.get('$baseUrl/api/v1/toplist', queryParameters: {
      'source': source,
    });
    final list = (res.data['toplists'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => DiscoveryToplist.fromJson(
              Map<String, dynamic>.from(e),
              source: source,
            ))
        .toList();
  }

  Future<List<Song>> getToplistSongs(
    String id, {
    String source = 'qq',
    int num = 50,
  }) async {
    final res = await _dio.get('$baseUrl/api/v1/toplist/songs',
        queryParameters: {'source': source, 'id': id, 'num': num});
    final list = (res.data['songs'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => songFromDiscovery(Map<String, dynamic>.from(e), source))
        .toList();
  }

  Future<({DiscoveryPlaylist? playlist, List<Song> songs})> getPlaylistDetail({
    required String source,
    required String id,
  }) async {
    final res = await _dio.get('$baseUrl/api/v1/playlist/detail',
        queryParameters: {'source': source, 'id': id});
    final data = res.data as Map;
    final pl = data['playlist'];
    final songs = ((data['songs'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => songFromDiscovery(Map<String, dynamic>.from(e), source))
        .toList();
    return (
      playlist: pl is Map
          ? DiscoveryPlaylist.fromJson(Map<String, dynamic>.from(pl), source)
          : null,
      songs: songs,
    );
  }

  /// 解析可播 URL。
  /// QQ/汽水优先走国内 qqovo（music.qqovo.cn）；[quality] 对齐播放器音质偏好。
  /// 汽水直链在 ExoPlayer 上常「有进度无声」，落盘成本地文件再播。
  Future<String?> resolvePlayUrl({
    required String source,
    required String id,
    String quality = '320',
  }) async {
    String? url;
    if (source == 'qq') {
      url = await QqovoResolver().resolve(
        server: 'tencent',
        id: id,
        preference: quality,
      );
    } else if (source == 'soda') {
      url = await QqovoResolver().resolve(
        server: 'qishui',
        id: id,
        preference: quality,
      );
    }

    if (url == null) {
      try {
        final res = await _dio.get(
          '$baseUrl/api/v1/resolve',
          queryParameters: {
            'source': source,
            'id': id,
            'quality': quality,
          },
          // 502 时服务端仍可能带 error 字段，不要直接抛掉
          options: Options(
            validateStatus: (code) => code != null && code < 600,
          ),
        );
        final data = res.data;
        if (data is Map) {
          var remote = data['url']?.toString();
          // Android 禁明文；QQ CDN https 可用，强制升格。
          if (remote != null && remote.startsWith('http://')) {
            remote = 'https://${remote.substring(7)}';
          }
          if (remote != null && remote.startsWith('http')) {
            url = remote;
          } else {
            debugPrint('[DiscoveryApi] resolve empty source=$source id=$id '
                'status=${res.statusCode} error=${data['error']}');
          }
        }
      } catch (e) {
        debugPrint('[DiscoveryApi] resolve failed source=$source id=$id err=$e');
      }
    }

    if (url == null) return null;
    if (source == 'soda' && !kIsWeb) {
      final local = await _materializeSodaStream(url, id);
      if (local != null) return local;
    }
    return url;
  }

  /// 用 Luna 头把汽水 CDN 流拉到临时文件，规避 ExoPlayer 直链无声。
  Future<String?> _materializeSodaStream(String url, String id) async {
    try {
      final dir = await getTemporaryDirectory();
      final safe = id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final file = File('${dir.path}/soda_$safe.m4a');
      await _dio.download(
        url,
        file.path,
        options: Options(
          headers: _lunaHeaders,
          receiveTimeout: const Duration(seconds: 90),
          validateStatus: (code) => code != null && code < 500,
        ),
      );
      final len = await file.length();
      if (len < 2048) {
        debugPrint('[DiscoveryApi] soda cache too small ($len) id=$id');
        try {
          await file.delete();
        } catch (_) {}
        return null;
      }
      debugPrint('[DiscoveryApi] soda cached ${len}B → ${file.path}');
      return file.uri.toString();
    } catch (e) {
      debugPrint('[DiscoveryApi] soda materialize failed: $e');
      return null;
    }
  }
}

class DiscoveryPlaylist {
  final String id;
  final String name;
  final String cover;
  final int trackCount;
  final int playCount;
  final String creator;
  final String source;

  const DiscoveryPlaylist({
    required this.id,
    required this.name,
    required this.cover,
    required this.trackCount,
    required this.playCount,
    required this.creator,
    required this.source,
  });

  factory DiscoveryPlaylist.fromJson(Map<String, dynamic> json, String source) {
    return DiscoveryPlaylist(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      cover: '${json['cover'] ?? ''}',
      trackCount: (json['track_count'] as num?)?.toInt() ?? 0,
      playCount: (json['play_count'] as num?)?.toInt() ?? 0,
      creator: '${json['creator'] ?? ''}',
      source: source,
    );
  }
}

class DiscoveryToplist {
  final String id;
  final String name;
  final String cover;
  final String group;
  final String source;

  const DiscoveryToplist({
    required this.id,
    required this.name,
    required this.cover,
    required this.group,
    this.source = 'qq',
  });

  factory DiscoveryToplist.fromJson(
    Map<String, dynamic> json, {
    String source = 'qq',
  }) {
    return DiscoveryToplist(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      cover: '${json['cover'] ?? ''}',
      group: '${json['group'] ?? ''}',
      source: '${json['source'] ?? source}',
    );
  }
}

Song songFromDiscovery(Map<String, dynamic> json, String source) {
  final rawId = '${json['id'] ?? ''}';
  final durationSec = (json['duration'] as num?)?.toInt() ?? 0;
  final coverRaw = (json['cover'] as String?)?.trim() ?? '';
  // Luna 曾返回残缺前缀 …/img/，不当作有效封面
  final cover = (coverRaw.isNotEmpty && !coverRaw.endsWith('/img/') && !coverRaw.endsWith('/img'))
      ? coverRaw
      : null;
  return Song(
    id: '$source:$rawId',
    title: '${json['name'] ?? ''}',
    artist: '${json['artist'] ?? ''}',
    album: '${json['album'] ?? ''}',
    duration: Duration(seconds: durationSec > 0 ? durationSec : 0),
    artworkUri: cover,
    isOnline: true,
    albumId: json['album_id']?.toString(),
    source: source,
  );
}
