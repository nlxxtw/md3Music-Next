import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/discovery_api/discovery_api_client.dart';

enum DiscoverMusicSource { kugou, qq, soda }

extension DiscoverMusicSourceX on DiscoverMusicSource {
  String get label {
    switch (this) {
      case DiscoverMusicSource.kugou:
        return '酷狗';
      case DiscoverMusicSource.qq:
        return 'QQ';
      case DiscoverMusicSource.soda:
        return '汽水';
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
    }
  }
}

/// 发现页音源切换 + QQ/汽水远程推荐/榜单缓存。
class DiscoverSourceProvider extends ChangeNotifier {
  DiscoverSourceProvider({DiscoveryApiClient? client})
      : _client = client ?? DiscoveryApiClient();

  static const _prefsKey = 'discover_music_source';

  final DiscoveryApiClient _client;

  DiscoverMusicSource _source = DiscoverMusicSource.kugou;
  bool _loading = false;
  String? _error;

  List<DiscoveryPlaylist> _playlists = const [];
  List<DiscoveryToplist> _toplists = const [];

  DiscoverMusicSource get source => _source;
  bool get isKugou => _source == DiscoverMusicSource.kugou;
  bool get loading => _loading;
  String? get error => _error;
  List<DiscoveryPlaylist> get playlists => _playlists;
  List<DiscoveryToplist> get toplists => _toplists;
  DiscoveryApiClient get client => _client;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final matched = DiscoverMusicSource.values.where((e) => e.name == raw);
    if (matched.isNotEmpty) {
      _source = matched.first;
      notifyListeners();
    }
    if (!isKugou) {
      await refreshRemote();
    }
  }

  Future<void> setSource(DiscoverMusicSource next) async {
    if (_source == next) return;
    _source = next;
    _error = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, next.name);
    if (!isKugou) {
      await refreshRemote();
    }
  }

  Future<void> refreshRemote() async {
    final apiSource = _source.apiSource;
    if (apiSource == null) return;

    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final playlists = await _client.getRecommend(apiSource);
      List<DiscoveryToplist> toplists = const [];
      try {
        toplists = await _client.getToplists(source: apiSource);
      } catch (_) {
        toplists = const [];
      }
      if (_source.apiSource == apiSource) {
        _playlists = playlists;
        _toplists = toplists;
      }
    } catch (e) {
      if (_source.apiSource == apiSource) {
        _error = e.toString();
        _playlists = const [];
        _toplists = const [];
      }
    } finally {
      if (_source.apiSource == apiSource) {
        _loading = false;
        notifyListeners();
      }
    }
  }
}
