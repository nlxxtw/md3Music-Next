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
  });
  final List<DiscoveryPlaylist> playlists;
  final List<DiscoveryToplist> toplists;
  final List<Song> fmSongs;
  final String fmMode;
}

/// 发现页音源切换 + QQ/汽水/网易远程推荐/榜单/私人漫游缓存。
class DiscoverSourceProvider extends ChangeNotifier {
  DiscoverSourceProvider({DiscoveryApiClient? client})
      : _client = client ?? DiscoveryApiClient();

  static const _prefsKey = 'discover_music_source';
  static const _fmModePrefsPrefix = 'discover_fm_mode_';
  static const _autoRoamingPrefsKey = 'discover_auto_roaming';

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
    }
    _autoRoaming = prefs.getBool(_autoRoamingPrefsKey) ?? true;
    _restoreFromCache(_source);
    notifyListeners();
    if (!isKugou) {
      await refreshRemote();
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
          );
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
      );
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
      );
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
      await refreshRemote();
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

  Future<void> refreshRemote() async {
    final apiSource = _source.apiSource;
    if (apiSource == null) return;
    final sourceKey = _source;
    final mode = fmMode;

    _loading = true;
    _fmLoading = true;
    _error = null;
    notifyListeners();

    try {
      final playlistsFuture = _client.getRecommend(apiSource);
      final toplistsFuture = () async {
        try {
          return await _client.getToplists(source: apiSource);
        } catch (_) {
          return const <DiscoveryToplist>[];
        }
      }();
      final fmFuture = () async {
        try {
          return await _client.getFmSongs(apiSource, mode: mode);
        } catch (_) {
          return const <Song>[];
        }
      }();
      final results = await Future.wait([
        playlistsFuture,
        toplistsFuture,
        fmFuture,
      ]);
      if (_source != sourceKey) return;
      _playlists = results[0] as List<DiscoveryPlaylist>;
      _toplists = results[1] as List<DiscoveryToplist>;
      _fmSongs = results[2] as List<Song>;
      _cache[sourceKey] = _RemoteCache(
        playlists: _playlists,
        toplists: _toplists,
        fmSongs: _fmSongs,
        fmMode: mode,
      );
    } catch (e) {
      if (_source != sourceKey) return;
      _error = e.toString();
    } finally {
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
      _cache[sourceKey] = _RemoteCache(
        playlists: prev?.playlists ?? _playlists,
        toplists: prev?.toplists ?? _toplists,
        fmSongs: songs,
        fmMode: mode,
      );
    } catch (e) {
      debugPrint('[DiscoverSource] refreshFmOnly failed: $e');
    } finally {
      if (_source == sourceKey) {
        _fmLoading = false;
        notifyListeners();
      }
    }
  }
}
