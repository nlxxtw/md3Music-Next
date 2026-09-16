import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/song.dart';
import '../modules/discover/remote_fm_refill.dart';
import '../providers/player_provider.dart';
import '../services/discovery_api/discovery_api_client.dart';
import '../services/discovery_api/fm_modes.dart';

enum DiscoverMusicSource { kugou, qq, soda, netease }

extension DiscoverMusicSourceX on DiscoverMusicSource {
  String get label {
    switch (this) {
      case DiscoverMusicSource.kugou:
        return '酷狗';
      case DiscoverMusicSource.qq:
        return 'QQ';
      case DiscoverMusicSource.soda:
        return '汽水';
      case DiscoverMusicSource.netease:
        return '网易云';
    }
  }

  String? get apiSource {
    switch (this) {
      case DiscoverMusicSource.kugou:
        return null;
      case DiscoverMusicSource.qq:
        return 'qq';
      case DiscoverMusicSource.soda:
        return 'soda';
      case DiscoverMusicSource.netease:
        return 'netease';
    }
  }
}

class _RemoteCache {
  const _RemoteCache({
    this.playlists = const [],
    this.toplists = const [],
    this.fmSongs = const [],
    this.fmMode = FmModes.defaultMode,
    this.savedAtMs = 0,
  });
  final List<DiscoveryPlaylist> playlists;
  final List<DiscoveryToplist> toplists;
  final List<Song> fmSongs;
  final String fmMode;
  final int savedAtMs;

  bool get hasContent =>
      playlists.isNotEmpty || toplists.isNotEmpty || fmSongs.isNotEmpty;

  /// 网易云固定歌单可长缓存；QQ/汽水推荐稍短。
  bool isFresh(DiscoverMusicSource source) {
    if (savedAtMs <= 0 || !hasContent) return false;
    final age = DateTime.now().millisecondsSinceEpoch - savedAtMs;
    final ttl = source == DiscoverMusicSource.netease
        ? const Duration(hours: 24)
        : const Duration(hours: 3);
    return age < ttl.inMilliseconds;
  }
}

/// 发现页音源切换 + QQ/汽水/网易远程推荐/榜单/私人漫游缓存。
class DiscoverSourceProvider extends ChangeNotifier {
  DiscoverSourceProvider({DiscoveryApiClient? client})
      : _client = client ?? DiscoveryApiClient();

  static const _prefsKey = 'discover_music_source';
  static const _fmModePrefsPrefix = 'discover_fm_mode_';
  static const _autoRoamingPrefsKey = 'discover_auto_roaming';
  static const _diskCachePrefix = 'discover_remote_cache_v1_';

  final DiscoveryApiClient _client;
  final Map<DiscoverMusicSource, _RemoteCache> _cache = {};
  final Map<DiscoverMusicSource, String> _fmModes = {
    DiscoverMusicSource.qq: FmModes.defaultMode,
    DiscoverMusicSource.soda: FmModes.defaultMode,
    DiscoverMusicSource.netease: FmModes.defaultMode,
  };

  DiscoverMusicSource _source = DiscoverMusicSource.kugou;
  bool _loading = false;
  bool _fmLoading = false;
  bool _refreshing = false;
  bool _autoRoaming = true;
  String? _error;
  RemoteFmRefill? _fmRefill;

  List<DiscoveryPlaylist> _playlists = const [];
  List<DiscoveryToplist> _toplists = const [];
  List<Song> _fmSongs = const [];

  DiscoverMusicSource get source => _source;
  bool get isKugou => _source == DiscoverMusicSource.kugou;
  bool get loading => _loading;
  bool get fmLoading => _fmLoading;
  bool get autoRoaming => _autoRoaming;
  String? get error => _error;
  List<DiscoveryPlaylist> get playlists => _playlists;
  List<DiscoveryToplist> get toplists => _toplists;
  List<Song> get fmSongs => _fmSongs;
  DiscoveryApiClient get client => _client;

  String get fmMode {
    final api = _source.apiSource;
    if (api == null) return FmModes.defaultMode;
    return FmModes.normalize(_fmModes[_source], api);
  }

  List<FmModeOption> get fmModeOptions {
    final api = _source.apiSource;
    if (api == null) return const [];
    return FmModes.optionsFor(api);
  }

  String get fmModeLabel {
    final api = _source.apiSource;
    if (api == null) return '私人漫游';
    return FmModes.labelOf(fmMode, api);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final matched = DiscoverMusicSource.values.where((e) => e.name == raw);
    if (matched.isNotEmpty) {
      _source = matched.first;
    }
    for (final s in [
      DiscoverMusicSource.qq,
      DiscoverMusicSource.soda,
      DiscoverMusicSource.netease,
    ]) {
      final saved = prefs.getString('$_fmModePrefsPrefix${s.name}');
      if (saved != null && s.apiSource != null) {
        _fmModes[s] = FmModes.normalize(saved, s.apiSource!);
      }
      await _loadDiskCache(s, prefs);
    }
    _autoRoaming = prefs.getBool(_autoRoamingPrefsKey) ?? true;
    _restoreFromCache(_source);
    notifyListeners();
    if (!isKugou) {
      await _refreshIfNeeded(awaitNetwork: false);
    }
  }

  Future<void> setAutoRoaming(bool enabled) async {
    if (_autoRoaming == enabled) return;
    _autoRoaming = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoRoamingPrefsKey, enabled);
    if (!enabled) {
      _fmRefill?.retire();
      _fmRefill = null;
    }
  }

  /// 播放私人漫游列表并挂上自动续播（对齐 OpenMusic「自动漫游」）。
  Future<void> playFmSongs(
    PlayerProvider player,
    List<Song> songs,
    int startIndex,
  ) async {
    if (songs.isEmpty) return;
    await player.playOnlinePlaylist(songs, startIndex);
    // playOnlinePlaylist 内 enrich 后的 CDN 封面写回漫游列表
    final artById = <String, String>{
      for (final s in player.playlist)
        if (s.artworkUri != null && s.artworkUri!.isNotEmpty)
          s.id: s.artworkUri!,
    };
    if (artById.isNotEmpty) {
      var changed = false;
      final next = <Song>[];
      for (final s in _fmSongs) {
        final art = artById[s.id];
        if (art != null && s.artworkUri != art) {
          next.add(s.copyWith(artworkUri: art));
          changed = true;
        } else {
          next.add(s);
        }
      }
      if (changed) {
        _fmSongs = next;
        final prev = _cache[_source];
        if (prev != null) {
          _cache[_source] = _RemoteCache(
            playlists: prev.playlists,
            toplists: prev.toplists,
            fmSongs: _fmSongs,
            fmMode: prev.fmMode,
            savedAtMs: prev.savedAtMs,
          );
          // ignore: discarded_futures
          _persistDiskCache(_source, _cache[_source]!);
        }
        notifyListeners();
      }
    }
    bindFmRefill(player, seed: _fmSongs.isNotEmpty ? _fmSongs : songs);
  }

  void bindFmRefill(PlayerProvider player, {required List<Song> seed}) {
    _fmRefill?.retire();
    _fmRefill = null;
    if (!_autoRoaming || isKugou || seed.isEmpty) return;
    _fmRefill = RemoteFmRefill(
      discover: this,
      player: player,
      seed: seed,
    );
    player.onPlaylistEnd = _fmRefill!.onQueueEnd;
  }

  /// 漫游续播追加：与酷狗 [KugouProvider.appendFmSongs] 对齐，
  /// 卡片列表必须跟播放队列一起变长，否则播放到续播段时
  /// `indexWhere` 失败会卡在第 0 首封面。
  void appendFmSongs(List<Song> songs) {
    if (songs.isEmpty) return;
    final existing = _fmSongs.map((s) => s.id).toSet();
    final unique = songs.where((s) => !existing.contains(s.id)).toList();
    if (unique.isEmpty) return;
    _fmSongs = [..._fmSongs, ...unique];
    final prev = _cache[_source];
    if (prev != null) {
      _cache[_source] = _RemoteCache(
        playlists: prev.playlists,
        toplists: prev.toplists,
        fmSongs: _fmSongs,
        fmMode: prev.fmMode,
        savedAtMs: prev.savedAtMs,
      );
      // ignore: discarded_futures
      _persistDiskCache(_source, _cache[_source]!);
    }
    notifyListeners();
  }

  /// 播放器补到 CDN 封面后回写漫游列表，避免卡仍显示音符占位。
  void patchFmArtwork(Song song) {
    final art = song.artworkUri;
    if (art == null || art.isEmpty) return;
    final i = _fmSongs.indexWhere((s) => s.id == song.id);
    if (i < 0) return;
    if (_fmSongs[i].artworkUri == art) return;
    final next = List<Song>.from(_fmSongs);
    next[i] = next[i].copyWith(artworkUri: art);
    _fmSongs = next;
    final prev = _cache[_source];
    if (prev != null) {
      _cache[_source] = _RemoteCache(
        playlists: prev.playlists,
        toplists: prev.toplists,
        fmSongs: _fmSongs,
        fmMode: prev.fmMode,
        savedAtMs: prev.savedAtMs,
      );
      // ignore: discarded_futures
      _persistDiskCache(_source, _cache[_source]!);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _fmRefill?.retire();
    _fmRefill = null;
    super.dispose();
  }

  Future<void> setSource(DiscoverMusicSource next) async {
    if (_source == next) return;
    _source = next;
    _error = null;
    _restoreFromCache(next);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, next.name);
    if (!isKugou) {
      // 切源：有缓存秒开；后台补拉，不挡 UI
      await _refreshIfNeeded(awaitNetwork: false);
    } else {
      _loading = false;
      _fmLoading = false;
      notifyListeners();
    }
  }

  Future<void> setFmMode(String mode) async {
    final api = _source.apiSource;
    if (api == null) return;
    final next = FmModes.normalize(mode, api);
    if (_fmModes[_source] == next) return;
    _fmModes[_source] = next;
    _fmSongs = const [];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_fmModePrefsPrefix${_source.name}', next);
    await refreshFmOnly();
  }

  void _restoreFromCache(DiscoverMusicSource source) {
    final hit = _cache[source];
    if (hit == null) {
      _playlists = const [];
      _toplists = const [];
      _fmSongs = const [];
      return;
    }
    _playlists = hit.playlists;
    _toplists = hit.toplists;
    // 模式变了则不复用旧漫游列表
    if (hit.fmMode == (_fmModes[source] ?? FmModes.defaultMode)) {
      _fmSongs = hit.fmSongs;
    } else {
      _fmSongs = const [];
    }
  }

  /// [awaitNetwork] 为 false 时：有内容立刻返回，过期则后台刷新。
  Future<void> _refreshIfNeeded({required bool awaitNetwork}) async {
    final cached = _cache[_source];
    final hasContent = cached?.hasContent == true;
    final fresh = cached != null && cached.isFresh(_source);
    if (hasContent && fresh) return;
    if (hasContent && !awaitNetwork) {
      // ignore: discarded_futures
      refreshRemote(force: true);
      return;
    }
    await refreshRemote(force: true);
  }

  Future<void> refreshRemote({bool force = true}) async {
    final apiSource = _source.apiSource;
    if (apiSource == null) return;
    final sourceKey = _source;
    final mode = fmMode;

    // 未强制刷新且内存/磁盘缓存仍新鲜：直接展示，不转圈
    final existing = _cache[sourceKey];
    if (!force && existing != null && existing.isFresh(sourceKey)) {
      _restoreFromCache(sourceKey);
      _loading = false;
      _fmLoading = false;
      _error = null;
      notifyListeners();
      return;
    }

    if (_refreshing) return;
    _refreshing = true;

    final hadContent = existing?.hasContent == true ||
        _playlists.isNotEmpty ||
        _toplists.isNotEmpty ||
        _fmSongs.isNotEmpty;
    // 有缓存时只顶栏细条，避免整页转圈把界面卡住
    _loading = !hadContent;
    _fmLoading = _fmSongs.isEmpty;
    _error = null;
    notifyListeners();

    try {
      final playlistsFuture = () async {
        try {
          return await _client.getRecommend(apiSource);
        } catch (_) {
          return existing?.playlists ?? _playlists;
        }
      }();
      final toplistsFuture = () async {
        try {
          return await _client.getToplists(source: apiSource);
        } catch (_) {
          return existing?.toplists ?? _toplists;
        }
      }();
      final fmFuture = () async {
        try {
          return await _client.getFmSongs(apiSource, mode: mode);
        } catch (_) {
          return existing?.fmSongs ?? _fmSongs;
        }
      }();
      final results = await Future.wait([
        playlistsFuture.timeout(
          const Duration(seconds: 12),
          onTimeout: () => existing?.playlists ?? _playlists,
        ),
        toplistsFuture.timeout(
          const Duration(seconds: 12),
          onTimeout: () => existing?.toplists ?? _toplists,
        ),
        fmFuture.timeout(
          const Duration(seconds: 10),
          onTimeout: () => existing?.fmSongs ?? _fmSongs,
        ),
      ]);
      if (_source != sourceKey) return;
      final nextPlaylists = results[0] as List<DiscoveryPlaylist>;
      final nextToplists = results[1] as List<DiscoveryToplist>;
      final nextFm = results[2] as List<Song>;
      final gotAnything = nextPlaylists.isNotEmpty ||
          nextToplists.isNotEmpty ||
          nextFm.isNotEmpty;
      if (!gotAnything && hadContent) {
        _restoreFromCache(sourceKey);
        return;
      }
      _playlists = nextPlaylists.isNotEmpty ? nextPlaylists : _playlists;
      _toplists = nextToplists.isNotEmpty ? nextToplists : _toplists;
      _fmSongs = nextFm.isNotEmpty ? nextFm : _fmSongs;
      final entry = _RemoteCache(
        playlists: _playlists,
        toplists: _toplists,
        fmSongs: _fmSongs,
        fmMode: mode,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      _cache[sourceKey] = entry;
      // ignore: discarded_futures
      _persistDiskCache(sourceKey, entry);
    } catch (e) {
      if (_source != sourceKey) return;
      // 有旧缓存时失败不盖空白页
      if (!hadContent) {
        _error = e.toString();
      } else {
        debugPrint('[DiscoverSource] refresh failed, keep cache: $e');
      }
    } finally {
      _refreshing = false;
      if (_source == sourceKey) {
        _loading = false;
        _fmLoading = false;
        notifyListeners();
      }
    }
  }

  /// 仅刷新私人漫游（切模式时用，避免整页闪）。
  Future<void> refreshFmOnly() async {
    final apiSource = _source.apiSource;
    if (apiSource == null) return;
    final sourceKey = _source;
    final mode = fmMode;
    _fmLoading = true;
    notifyListeners();
    try {
      final songs = await _client.getFmSongs(apiSource, mode: mode);
      if (_source != sourceKey) return;
      _fmSongs = songs;
      final prev = _cache[sourceKey];
      final entry = _RemoteCache(
        playlists: prev?.playlists ?? _playlists,
        toplists: prev?.toplists ?? _toplists,
        fmSongs: songs,
        fmMode: mode,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      _cache[sourceKey] = entry;
      // ignore: discarded_futures
      _persistDiskCache(sourceKey, entry);
    } catch (e) {
      debugPrint('[DiscoverSource] refreshFmOnly failed: $e');
    } finally {
      if (_source == sourceKey) {
        _fmLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadDiskCache(
    DiscoverMusicSource source,
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString('$_diskCachePrefix${source.name}');
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return;
      final playlists = ((map['playlists'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => DiscoveryPlaylist.fromJson(
                Map<String, dynamic>.from(e),
                source.apiSource ?? source.name,
              ))
          .toList();
      final toplists = ((map['toplists'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => DiscoveryToplist.fromJson(
                Map<String, dynamic>.from(e),
                source: source.apiSource ?? source.name,
              ))
          .toList();
      final fmSongs = ((map['fmSongs'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final fmMode = '${map['fmMode'] ?? FmModes.defaultMode}';
      final savedAtMs = (map['savedAtMs'] as num?)?.toInt() ?? 0;
      if (playlists.isEmpty && toplists.isEmpty && fmSongs.isEmpty) return;
      _cache[source] = _RemoteCache(
        playlists: playlists,
        toplists: toplists,
        fmSongs: fmSongs,
        fmMode: fmMode,
        savedAtMs: savedAtMs,
      );
    } catch (e) {
      debugPrint('[DiscoverSource] disk cache load ${source.name} failed: $e');
    }
  }

  Future<void> _persistDiskCache(
    DiscoverMusicSource source,
    _RemoteCache entry,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode({
        'savedAtMs': entry.savedAtMs,
        'fmMode': entry.fmMode,
        'playlists': entry.playlists.map((e) => e.toJson()).toList(),
        'toplists': entry.toplists.map((e) => e.toJson()).toList(),
        // 漫游列表截断，避免 SharedPreferences 过大
        'fmSongs': entry.fmSongs.take(40).map((e) => e.toJson()).toList(),
      });
      await prefs.setString('$_diskCachePrefix${source.name}', payload);
    } catch (e) {
      debugPrint('[DiscoverSource] disk cache save ${source.name} failed: $e');
    }
  }
}
