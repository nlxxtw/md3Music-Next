import 'package:dio/dio.dart';

import '../../data/models/song.dart';

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

  /// 解析可播 URL（服务端需提供 `/api/v1/resolve`；未部署时返回 null）。
  Future<String?> resolvePlayUrl({
    required String source,
    required String id,
  }) async {
    try {
      final res = await _dio.get(
        '$baseUrl/api/v1/resolve',
        queryParameters: {
          'source': source,
          'id': id,
        },
        // 502 时服务端仍可能带 error 字段，不要直接抛掉
        options: Options(
          validateStatus: (code) => code != null && code < 600,
        ),
      );
      final data = res.data;
      if (data is! Map) return null;
      var url = data['url']?.toString();
      // Android 禁明文；QQ CDN https 可用，强制升格。
      if (url != null && url.startsWith('http://')) {
        url = 'https://${url.substring(7)}';
      }
      if (url != null && url.startsWith('http')) return url;
      // ignore: avoid_print
      print('[DiscoveryApi] resolve empty source=$source id=$id '
          'status=${res.statusCode} error=${data['error']}');
    } catch (e) {
      // ignore: avoid_print
      print('[DiscoveryApi] resolve failed source=$source id=$id err=$e');
    }
    return null;
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
