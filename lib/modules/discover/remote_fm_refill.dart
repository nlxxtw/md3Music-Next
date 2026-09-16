import 'package:flutter/foundation.dart';

import '../../data/models/song.dart';
import '../../providers/discover_source_provider.dart';
import '../../providers/player_provider.dart';

/// OpenMusic 风格私人漫游续播：队列见底时按当前音源+模式再拉一批 `type=fm`。
class RemoteFmRefill {
  RemoteFmRefill({
    required this.discover,
    required this.player,
    required List<Song> seed,
  }) : _owned = seed.map((s) => s.id).toSet() {
    player.addListener(_onPlayerChanged);
  }

  final DiscoverSourceProvider discover;
  final PlayerProvider player;

  final Set<String> _owned;
  Future<bool>? _inFlight;
  int _lastPrefetchIndex = -1;
  bool _stalledAtQueueEnd = false;
  bool _retired = false;

  static const _prefetchThreshold = 2;
  static const _queueEndRetries = 3;

  bool get _ownsQueue {
    final id = player.currentSong?.id;
    return id != null && _owned.contains(id);
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    player.removeListener(_onPlayerChanged);
    if (player.onPlaylistEnd == onQueueEnd) {
      player.onPlaylistEnd = null;
    }
  }

  void _onPlayerChanged() {
    if (_retired) return;
    if (player.onPlaylistEnd != onQueueEnd) {
      retire();
      return;
    }
    final playingId = player.currentSong?.id;
    if (playingId == null) return;
    if (!_owned.contains(playingId)) {
      retire();
      return;
    }
    final index = player.currentIndex;
    if (index < 0) return;
    if (player.playlist.length - index > _prefetchThreshold) return;
    if (index == _lastPrefetchIndex) return;
    _lastPrefetchIndex = index;
    append().then((ok) {
      if (!ok) {
        if (_lastPrefetchIndex == index) _lastPrefetchIndex = -1;
        return;
      }
      if (_stalledAtQueueEnd && !_retired && _ownsQueue) {
        _stalledAtQueueEnd = false;
        player.next();
      }
    });
  }

  Future<void> onQueueEnd() async {
    if (_retired) return;
    if (!_ownsQueue) {
      retire();
      return;
    }
    for (var attempt = 0; attempt < _queueEndRetries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        if (_retired || !_ownsQueue) return;
      }
      if (await append()) {
        _stalledAtQueueEnd = false;
        await player.next();
        return;
      }
    }
    _stalledAtQueueEnd = true;
    _lastPrefetchIndex = -1;
  }

  Future<bool> append() {
    final inflight = _inFlight;
    if (inflight != null) return inflight;
    final started = _append();
    _inFlight = started;
    return started.whenComplete(() {
      if (_inFlight == started) _inFlight = null;
    });
  }

  Future<bool> _append() async {
    if (_retired || !_ownsQueue) return false;
    if (!discover.autoRoaming || discover.isKugou) return false;
    final api = discover.source.apiSource;
    if (api == null) return false;
    final before = player.playlist.length;
    try {
      final fresh = await discover.client.getFmSongs(
        api,
        mode: discover.fmMode,
      );
      if (_retired || fresh.isEmpty) return false;
      final unique = fresh.where((s) => !_owned.contains(s.id)).toList();
      if (unique.isEmpty) {
        // 全重复时仍尝试追加（fm 池可能很小），用全部
        final fallback = fresh.where((s) => s.remoteTrackId.isNotEmpty).toList();
        if (fallback.isEmpty) return false;
        _owned.addAll(fallback.map((s) => s.id));
        discover.appendFmSongs(fallback);
        await player.appendPlaylist(fallback);
        return player.playlist.length > before;
      }
      _owned.addAll(unique.map((s) => s.id));
      discover.appendFmSongs(unique);
      await player.appendPlaylist(unique);
      return true;
    } catch (e) {
      debugPrint('[RemoteFmRefill] append failed: $e');
      return player.playlist.length > before;
    }
  }
}
