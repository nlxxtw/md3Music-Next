import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/song.dart';
import 'fm_modes.dart';
import 'qishui_decrypt.dart';
import 'qqovo_resolver.dart';

String _httpsify(String url) {
  final u = url.trim();
  if (u.startsWith('http://')) return 'https://${u.substring(7)}';
  return u;
}

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
    if (source == 'netease') {
      return _searchViaQqovo(server: 'netease', source: source, keyword: keyword);
    }
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
    if (source == 'netease') return _neteasePlaylists();
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

  /// qqovo OpenMusic 全站「平台热榜」虚拟榜单 id（挂在 QQ 发现页第一位）。
  static const platformHotToplistId = 'qqovo-platform-hot';

  Future<List<DiscoveryToplist>> getToplists({String source = 'qq'}) async {
    if (source == 'netease') return _neteaseToplists();
    final res = await _dio.get('$baseUrl/api/v1/toplist', queryParameters: {
      'source': source,
    });
    final list = (res.data['toplists'] as List?) ?? const [];
    final charts = list
        .whereType<Map>()
        .map((e) => DiscoveryToplist.fromJson(
              Map<String, dynamic>.from(e),
              source: source,
            ))
        .toList();
    if (source != 'qq') return charts;

    var cover = '';
    try {
      final hot = await QqovoResolver().getPlatformHot(limit: 1);
      if (hot.isNotEmpty) {
        cover = _httpsify('${hot.first['pic'] ?? ''}');
      }
    } catch (e) {
      debugPrint('[DiscoveryApi] platform hot cover miss: $e');
    }
    return [
      DiscoveryToplist(
        id: platformHotToplistId,
        name: '平台热榜',
        cover: cover,
        group: 'OpenMusic',
        source: 'qq',
      ),
      ...charts,
    ];
  }

  /// 私人漫游（qqovo `type=fm`；网易/汽水模式作 `id`，对齐 OpenMusic）。
  Future<List<Song>> getFmSongs(String source, {String mode = 'DEFAULT'}) async {
    final server = switch (source) {
      'qq' => 'tencent',
      'soda' => 'qishui',
      'netease' => 'netease',
      _ => '',
    };
    if (server.isEmpty) return const [];
    final modeId = FmModes.metingId(mode, source);
    final data = await QqovoResolver().meting(
      server: server,
      type: 'fm',
      id: modeId ?? '',
    );
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => _songFromMeting(Map<String, dynamic>.from(e), source))
        .where((s) => s.remoteTrackId.isNotEmpty)
        .toList();
  }

  Future<List<Song>> getToplistSongs(
    String id, {
    String source = 'qq',
    int num = 50,
  }) async {
    if (id == platformHotToplistId) {
      return _platformHotSongs(num: num);
    }
    if (source == 'netease') {
      final detail = await getPlaylistDetail(source: source, id: id);
      return detail.songs.take(num).toList();
    }
    final res = await _dio.get('$baseUrl/api/v1/toplist/songs',
        queryParameters: {'source': source, 'id': id, 'num': num});
    final list = (res.data['songs'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => songFromDiscovery(Map<String, dynamic>.from(e), source))
        .toList();
  }

  Future<List<Song>> _platformHotSongs({int num = 50}) async {
    final raw = await QqovoResolver().getPlatformHot(limit: num);
    return raw
        .map(_songFromPlatformHot)
        .where((s) => s.remoteTrackId.isNotEmpty)
        .toList();
  }

  Song _songFromPlatformHot(Map<String, dynamic> raw) {
    final apiSource = '${raw['source'] ?? 'tencent'}'.trim();
    final appSource = switch (apiSource) {
      'tencent' => 'qq',
      'qishui' => 'soda',
      'netease' => 'netease',
      'kugou' => 'kugou',
      _ => 'qq',
    };
    final id = '${raw['id'] ?? ''}'.trim();
    final durationRaw = raw['duration'];
    var durationSec = 0;
    if (durationRaw is num) {
      durationSec = durationRaw > 10000
          ? (durationRaw / 1000).round()
          : durationRaw.toInt();
    }
    var pic = '${raw['pic'] ?? ''}'.trim();
    pic = _rewriteLocalhostMedia(pic, serverForSource(appSource));
    return Song(
      id: '$appSource:$id',
      title: '${raw['name'] ?? raw['title'] ?? ''}',
      artist: '${raw['artist'] ?? raw['author'] ?? ''}',
      album: '${raw['album'] ?? ''}',
      duration: Duration(seconds: durationSec),
      artworkUri: pic.isEmpty ? null : _httpsify(pic),
      isOnline: true,
      source: appSource,
    );
  }

  Future<({DiscoveryPlaylist? playlist, List<Song> songs})> getPlaylistDetail({
    required String source,
    required String id,
  }) async {
    if (source == 'netease') {
      final official = await _neteaseOfficialPlaylist(id);
      if (official.songs.isNotEmpty || official.playlist != null) {
        return official;
      }
      return _playlistViaQqovo(server: 'netease', source: source, id: id);
    }
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
  /// 汽水 CDN 是加密 MP4，必须用 meting 返回的 auth 解密后再播（网页同款）。
  Future<String?> resolvePlayUrl({
    required String source,
    required String id,
    String quality = '320',
  }) async {
    String? url;
    String? sodaAuth;
    if (source == 'qq') {
      url = await QqovoResolver().resolve(
        server: 'tencent',
        id: id,
        preference: quality,
      );
    } else if (source == 'soda') {
      final hit = await QqovoResolver().resolveHit(
        server: 'qishui',
        id: id,
        preference: quality,
      );
      url = hit?.url;
      sodaAuth = hit?.auth;
    } else if (source == 'netease') {
      url = await QqovoResolver().resolve(
        server: 'netease',
        id: id,
        preference: quality,
      );
    }

    // qqovo 失败时，汽水/网易也回退云端 resolve（与 QQ 一致）
    if (url == null) {
      try {
        final res = await _dio.get(
          '$baseUrl/api/v1/resolve',
          queryParameters: {
            'source': source,
            'id': id,
            'quality': quality,
          },
          options: Options(
            validateStatus: (code) => code != null && code < 600,
          ),
        );
        final data = res.data;
        if (data is Map) {
          var remote = data['url']?.toString();
          if (remote != null && remote.startsWith('http://')) {
            remote = 'https://${remote.substring(7)}';
          }
          if (remote != null && remote.startsWith('http')) {
            url = remote;
          } else {
            debugPrint('[DiscoveryApi] resolve empty source=$source id=$id '
                'status=${res.statusCode} error=${data['error']}');
          }
          final remoteAuth = '${data['auth'] ?? data['play_auth'] ?? ''}'.trim();
          if (remoteAuth.isNotEmpty) sodaAuth = remoteAuth;
        }
      } catch (e) {
        debugPrint('[DiscoveryApi] resolve failed source=$source id=$id err=$e');
      }
    }

    if (url == null) return null;
    if (source == 'soda' && !kIsWeb) {
      // 必须解密成本地可播文件；失败绝不能回退密文 CDN（有进度无声）。
      return _materializeSodaStream(url, id, auth: sodaAuth);
    }
    return url;
  }

  /// 下载汽水密文流，用 OpenMusic 同款 AES-CTR 解成可播 m4a/flac。
  Future<String?> _materializeSodaStream(
    String url,
    String id, {
    String? auth,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final safe = id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final rawFile = File('${dir.path}/soda_$safe.bin');
      await _dio.download(
        url,
        rawFile.path,
        options: Options(
          headers: _lunaHeaders,
          receiveTimeout: const Duration(seconds: 90),
          validateStatus: (code) => code != null && code < 500,
        ),
      );
      final len = await rawFile.length();
      if (len < 2048) {
        debugPrint('[DiscoveryApi] soda cache too small ($len) id=$id');
        try {
          await rawFile.delete();
        } catch (_) {}
        return null;
      }

      if (auth == null || auth.isEmpty) {
        debugPrint('[DiscoveryApi] soda missing auth — 密文直链无法出声');
        try {
          await rawFile.delete();
        } catch (_) {}
        return null;
      }

      final encrypted = await rawFile.readAsBytes();
      final decrypted = await compute(qishuiDecryptIsolate, {
        'bytes': Uint8List.fromList(encrypted),
        'auth': auth,
      });
      try {
        await rawFile.delete();
      } catch (_) {}
      final ext = '${decrypted['extension'] ?? 'm4a'}';
      final outBytes = decrypted['bytes'] as Uint8List;
      final out = File('${dir.path}/soda_$safe.$ext');
      await out.writeAsBytes(outBytes, flush: true);
      debugPrint(
        '[DiscoveryApi] soda decrypted ${outBytes.length}B $ext → ${out.path}',
      );
      return out.uri.toString();
    } catch (e) {
      debugPrint('[DiscoveryApi] soda materialize/decrypt failed: $e');
      return null;
    }
  }

  Future<List<Song>> _searchViaQqovo({
    required String server,
    required String source,
    required String keyword,
  }) async {
    final data = await QqovoResolver().meting(
      server: server,
      type: 'search',
      id: keyword.trim(),
    );
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => _songFromMeting(Map<String, dynamic>.from(e), source))
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  Future<({DiscoveryPlaylist? playlist, List<Song> songs})> _playlistViaQqovo({
    required String server,
    required String source,
    required String id,
  }) async {
    final data = await QqovoResolver().meting(
      server: server,
      type: 'playlist',
      id: id,
    );
    if (data is! List) {
      return (playlist: null, songs: const <Song>[]);
    }
    final songs = data
        .whereType<Map>()
        .map((e) => _songFromMeting(Map<String, dynamic>.from(e), source))
        .where((s) => s.remoteTrackId.isNotEmpty)
        .toList();
    final cover = songs.isNotEmpty ? (songs.first.artworkUri ?? '') : '';
    return (
      playlist: DiscoveryPlaylist(
        id: id,
        name: '歌单 $id',
        cover: cover,
        trackCount: songs.length,
        playCount: 0,
        creator: '',
        source: source,
      ),
      songs: songs,
    );
  }

  /// 网易官方榜单（以歌单 ID 形式暴露，与 QQ 排行榜区一致）。
  Future<List<DiscoveryToplist>> _neteaseToplists() async {
    const charts = <(String, String)>[
      ('3778678', '热歌榜'),
      ('19723756', '飙升榜'),
      ('3779629', '新歌榜'),
      ('2884035', '原创榜'),
      ('5453912201', '云音乐说唱榜'),
      ('2809513715', '欧美热歌榜'),
    ];
    final details = await Future.wait(charts.map((c) async {
      try {
        return await _neteaseOfficialPlaylist(c.$1, nameHint: c.$2);
      } catch (_) {
        return (playlist: null, songs: const <Song>[]);
      }
    }));
    return [
      for (var i = 0; i < charts.length; i++)
        DiscoveryToplist(
          id: charts[i].$1,
          name: charts[i].$2,
          cover: details[i].playlist?.cover ?? '',
          group: '官方榜',
          source: 'netease',
        ),
    ];
  }

  Future<List<DiscoveryPlaylist>> _neteasePlaylists() async {
    const ids = <(String, String)>[
      ('2829883282', '每日推荐精选'),
      ('2884035', '原创榜精选'),
      ('5059642708', '私人雷达'),
      ('5300458264', '经典永恒'),
      ('2609222984', '华语流行'),
      ('2801843750', '治愈系'),
    ];
    final details = await Future.wait(ids.map((c) async {
      try {
        return await _neteaseOfficialPlaylist(c.$1, nameHint: c.$2);
      } catch (_) {
        return (playlist: null, songs: const <Song>[]);
      }
    }));
    final out = <DiscoveryPlaylist>[];
    for (var i = 0; i < ids.length; i++) {
      final pl = details[i].playlist;
      if (pl == null) continue;
      // 无封面也保留入口，点进去仍可拉歌
      out.add(DiscoveryPlaylist(
        id: ids[i].$1,
        name: ids[i].$2,
        cover: pl.cover,
        trackCount: pl.trackCount > 0 ? pl.trackCount : details[i].songs.length,
        playCount: pl.playCount,
        creator: pl.creator.isNotEmpty ? pl.creator : '网易云',
        source: 'netease',
      ));
    }
    return out;
  }

  /// 网易云公开歌单详情（不依赖 qqovo playlist，封面/曲目更稳）。
  Future<({DiscoveryPlaylist? playlist, List<Song> songs})>
      _neteaseOfficialPlaylist(String id, {String? nameHint}) async {
    try {
      final res = await _dio.get(
        'https://music.163.com/api/v6/playlist/detail',
        queryParameters: {'id': id, 'n': 100, 's': 8},
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            'Referer': 'https://music.163.com/',
            'Accept': 'application/json',
          },
          validateStatus: (code) => code != null && code < 500,
        ),
      );
      final data = res.data;
      if (data is! Map) {
        return (playlist: null, songs: const <Song>[]);
      }
      final pl = data['playlist'];
      if (pl is! Map) {
        return (playlist: null, songs: const <Song>[]);
      }
      final cover = _httpsify(
        '${pl['coverImgUrl'] ?? pl['picUrl'] ?? ''}'.trim(),
      );
      final name = '${pl['name'] ?? nameHint ?? '歌单 $id'}'.trim();
      final creatorMap = pl['creator'];
      final creator = creatorMap is Map
          ? '${creatorMap['nickname'] ?? ''}'
          : '';
      final trackCount = (pl['trackCount'] as num?)?.toInt() ?? 0;
      final playCount = (pl['playCount'] as num?)?.toInt() ?? 0;

      final tracks = <Map>[];
      final tracksArr = pl['tracks'];
      if (tracksArr is List) {
        tracks.addAll(tracksArr.whereType<Map>());
      }
      if (tracks.isEmpty) {
        final idsArr = pl['trackIds'];
        if (idsArr is List) {
          // 只有 id 列表时，至少先返回空曲目+封面，详情页可再解
          for (final t in idsArr.take(50)) {
            if (t is Map && t['id'] != null) {
              tracks.add({'id': t['id'], 'name': '', 'ar': const []});
            }
          }
        }
      }

      final songs = <Song>[];
      for (final t in tracks) {
        final tid = '${t['id'] ?? ''}'.trim();
        if (tid.isEmpty) continue;
        final ar = t['ar'] ?? t['artists'];
        final artist = ar is List
            ? ar
                .map((e) => e is Map ? '${e['name'] ?? ''}' : '$e')
                .where((s) => s.isNotEmpty)
                .join(' / ')
            : '${t['artist'] ?? ''}';
        final al = t['al'] ?? t['album'];
        final album = al is Map ? '${al['name'] ?? ''}' : '${t['album'] ?? ''}';
        var pic = '';
        if (al is Map) pic = '${al['picUrl'] ?? ''}';
        if (pic.isEmpty) pic = '${t['album_pic'] ?? t['pic'] ?? ''}';
        pic = _httpsify(pic);
        final dt = t['dt'];
        final durationMs = dt is num ? dt.toInt() : 0;
        final title = '${t['name'] ?? ''}'.trim();
        if (title.isEmpty && pic.isEmpty) {
          // 仅有 id 的占位不展示为可播项
          continue;
        }
        songs.add(Song(
          id: 'netease:$tid',
          title: title.isEmpty ? '未知歌曲' : title,
          artist: artist,
          album: album,
          duration: Duration(milliseconds: durationMs),
          artworkUri: pic.isEmpty ? (cover.isEmpty ? null : cover) : pic,
          isOnline: true,
          source: 'netease',
        ));
      }

      return (
        playlist: DiscoveryPlaylist(
          id: id,
          name: name,
          cover: cover,
          trackCount: trackCount > 0 ? trackCount : songs.length,
          playCount: playCount,
          creator: creator,
          source: 'netease',
        ),
        songs: songs,
      );
    } catch (e) {
      debugPrint('[DiscoveryApi] netease playlist $id failed: $e');
      return (playlist: null, songs: const <Song>[]);
    }
  }

  Song _songFromMeting(Map<String, dynamic> raw, String source) {
    final urlStr = '${raw['url'] ?? ''}';
    var id = '${raw['id'] ?? raw['songId'] ?? raw['mid'] ?? ''}'.trim();
    if (id.isEmpty && urlStr.contains('id=')) {
      id = Uri.tryParse(urlStr)?.queryParameters['id'] ?? '';
      if (id.isEmpty) {
        final m = RegExp(r'[?&]id=([^&]+)').firstMatch(urlStr);
        id = m != null ? Uri.decodeComponent(m.group(1)!) : '';
      }
    }
    final artistRaw = raw['artist'] ?? raw['author'];
    final artist = artistRaw is List
        ? artistRaw.map((e) => e is Map ? '${e['name'] ?? ''}' : '$e').join(' / ')
        : '${artistRaw ?? ''}';
    final durationRaw = raw['duration'] ?? raw['dt'];
    var durationSec = 0;
    if (durationRaw is num) {
      durationSec = durationRaw > 10000
          ? (durationRaw / 1000).round()
          : durationRaw.toInt();
    }
    var pic = '${raw['pic'] ?? raw['cover'] ?? raw['album_pic'] ?? ''}'.trim();
    final server = serverForSource(source);
    pic = _rewriteLocalhostMedia(pic, server);
    // 网易 FM 常缺 pic：用 meting type=pic 兜底，否则漫游卡/锁屏全空白。
    if (pic.isEmpty && id.isNotEmpty) {
      pic =
          'https://music.qqovo.cn/api/meting?server=$server&type=pic&id=${Uri.encodeQueryComponent(id)}';
    }
    return Song(
      id: '$source:$id',
      title: '${raw['name'] ?? raw['title'] ?? ''}',
      artist: artist,
      album: '${raw['album'] ?? raw['album_name'] ?? ''}',
      duration: Duration(seconds: durationSec),
      artworkUri: pic.isEmpty ? null : _httpsify(pic),
      isOnline: true,
      source: source,
    );
  }

  static String serverForSource(String source) {
    return switch (source) {
      'qq' => 'tencent',
      'soda' => 'qishui',
      'netease' => 'netease',
      _ => source,
    };
  }

  /// qqovo 偶发返回 127.0.0.1 代理封面，改回公网 meting pic。
  static String _rewriteLocalhostMedia(String url, String server) {
    final u = url.trim();
    if (u.isEmpty) return u;
    final uri = Uri.tryParse(u);
    if (uri == null) return u;
    final host = uri.host.toLowerCase();
    if (host != '127.0.0.1' && host != 'localhost') return u;
    final id = uri.queryParameters['id'] ?? '';
    if (id.isEmpty) return u;
    final type = uri.queryParameters['type'] ?? 'pic';
    return 'https://music.qqovo.cn/api/meting?server=$server&type=$type&id=$id';
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
      ? _httpsify(coverRaw)
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
