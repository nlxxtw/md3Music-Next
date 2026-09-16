import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/discover_source_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/discovery_cover_image.dart';
import '../../widgets/wavy_playback_line.dart';
import '../player/full_player_route.dart';

const double _kCardRadius = 20.0;
const double _kCoverRadius = 16.0;
const double _kCoverSize = 112.0;
const double _kCoverGap = 12.0;
const double _kNextCoverSize = 48.0;
const double _kNextCoverRadius = 12.0;
const double _kNextCoverGap = 8.0;
const double _kModeButtonSize = 40.0;
const double _kWaveBandHeight = 10.0;
const double _kWaveBandInset = 3.0;
const double _kPanelPadding = 16.0;
const double _kModeButtonRightInset = 4.0;

const Duration _kDrawerDuration = Duration(milliseconds: 260);
const Curve _kDrawerCurve = Curves.easeInOutCubicEmphasized;

Color _containerColor(ColorScheme cs) => cs.surfaceContainerLow;
Color _drawerColor(ColorScheme cs) => cs.secondaryContainer;
Color _onDrawerColor(ColorScheme cs) => cs.onSecondaryContainer;

/// QQ / 汽水 / 网易发现页顶部的私人漫游卡：布局对齐酷狗 [PersonalFmSection]，
/// 听歌时律动线随播放器同步波动，并带当前平台标识。
class RemoteFmSection extends StatefulWidget {
  const RemoteFmSection({super.key, this.onOpenAll});

  final VoidCallback? onOpenAll;

  @override
  State<RemoteFmSection> createState() => _RemoteFmSectionState();
}

class _RemoteFmSectionState extends State<RemoteFmSection> {
  bool _drawerOpen = false;

  void _toggleDrawer() {
    setState(() => _drawerOpen = !_drawerOpen);
  }

  Future<void> _handlePlay(Song? track) async {
    final ds = context.read<DiscoverSourceProvider>();
    final player = context.read<PlayerProvider>();
    final songs = ds.fmSongs;
    if (songs.isEmpty) {
      await ds.refreshFmOnly();
      return;
    }

    final playingId = player.currentSong?.id;
    final onStation =
        playingId != null && songs.any((s) => s.id == playingId);
    if (onStation) {
      if (player.onPlaylistEnd == null) {
        ds.bindFmRefill(player, seed: songs);
      }
      if (player.isPlaying) {
        await player.pause();
      } else {
        await player.resume();
      }
      return;
    }
    if (track == null) return;
    final i = songs.indexWhere((s) => s.id == track.id);
    await ds.playFmSongs(player, songs, i >= 0 ? i : 0);
  }

  void _openTrack(Song track) {
    final player = context.read<PlayerProvider>();
    if (player.currentSong?.id != track.id) {
      // ignore: discarded_futures
      _handlePlay(track);
    }
    if (activePlayerRoute?.isCurrent ?? false) return;
    openFullPlayer(context);
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.watch<DiscoverSourceProvider>();
    final player = context.watch<PlayerProvider>();
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final fmSongs = ds.fmSongs;

    final playingId = player.currentSong?.id;
    final onStation =
        playingId != null && fmSongs.any((s) => s.id == playingId);

    // 正在听漫游时跟播放器队列走（含随机打乱顺序与续播追加），
    // 否则下一首预览会和左边播放模式不一致，封面也卡在 fmSongs[0]。
    final List<Song> songs;
    final int currentIndex;
    if (onStation && player.playlist.isNotEmpty) {
      songs = player.playlist;
      final idx = player.currentIndex;
      currentIndex = (idx >= 0 && idx < songs.length) ? idx : 0;
    } else {
      songs = fmSongs;
      final playingIndex =
          playingId == null ? -1 : songs.indexWhere((s) => s.id == playingId);
      currentIndex = playingIndex >= 0 ? playingIndex : 0;
    }
    final current = songs.isEmpty ? null : songs[currentIndex];
    final isPlaying = onStation && player.isPlaying;
    final nextTracks =
        songs.isEmpty ? const <Song>[] : songs.sublist(currentIndex + 1);

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Material(
          color: _drawerColor(cs),
          borderRadius: BorderRadius.circular(_kCardRadius),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: _containerColor(cs),
                surfaceTintColor: Colors.transparent,
                elevation: 1,
                borderRadius: BorderRadius.circular(_kCardRadius),
                child: Padding(
                  padding: const EdgeInsets.all(_kPanelPadding),
                  child: _buildNowPlayingRow(
                    cs,
                    textTheme,
                    ds,
                    current,
                    nextTracks,
                    isPlaying,
                    loading: ds.fmLoading && songs.isEmpty,
                  ),
                ),
              ),
              _buildModeDrawer(cs, textTheme, ds),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNowPlayingRow(
    ColorScheme cs,
    TextTheme textTheme,
    DiscoverSourceProvider ds,
    Song? current,
    List<Song> nextTracks,
    bool isPlaying, {
    required bool loading,
  }) {
    final platform = ds.source.label;
    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: _kCoverSize, height: _kCoverSize),
            const SizedBox(width: _kCoverGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              current?.title ?? '点播放，开启$platform漫游',
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (current != null &&
                                current.artist.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                current.artist,
                                style: textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      _buildFavoriteButton(cs, current),
                      _buildPlayButton(cs, current, isPlaying, loading),
                    ],
                  ),
                  const SizedBox(height: _kWaveBandInset),
                  _buildWaveBand(cs, isPlaying),
                  const SizedBox(height: _kWaveBandInset),
                  _buildBottomRow(cs, nextTracks),
                ],
              ),
            ),
          ],
        ),
        Positioned(
          left: 0,
          top: 0,
          child: _buildCurrentCover(cs, current),
        ),
      ],
    );
  }

  Widget _buildWaveBand(ColorScheme cs, bool isPlaying) {
    return SizedBox(
      height: _kWaveBandHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -(_kPanelPadding + _kCoverSize + _kCoverGap),
            right: -_kPanelPadding,
            top: 0,
            height: _kWaveBandHeight,
            child: IgnorePointer(
              child: WavyPlaybackLine(
                isPlaying: isPlaying,
                color: isPlaying ? cs.primary : cs.outlineVariant,
                height: _kWaveBandHeight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentCover(ColorScheme cs, Song? current) {
    final art = current?.artworkUri ?? '';
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(_kCoverRadius),
      child: SizedBox(
        width: _kCoverSize,
        height: _kCoverSize,
        child: art.isEmpty
            ? _coverPlaceholder(cs, 36)
            : DiscoveryCoverImage(
                url: art,
                memCacheWidth: 336,
                error: _coverPlaceholder(cs, 36),
              ),
      ),
    );
    if (current == null) return cover;
    return _tappable(
      cover: cover,
      radius: _kCoverRadius,
      label: '正在播放 ${current.title}',
      tooltip: '打开播放详情',
      onTap: () => _openTrack(current),
    );
  }

  Widget _buildBottomRow(ColorScheme cs, List<Song> nextTracks) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final slot = _kNextCoverSize + _kNextCoverGap;
        final available = constraints.maxWidth -
            _kModeButtonSize -
            _kModeButtonRightInset -
            _kNextCoverGap;
        final fits = ((available + _kNextCoverGap) / slot).floor();
        final count = fits.clamp(0, nextTracks.length);
        return Row(
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) const SizedBox(width: _kNextCoverGap),
              _buildNextCover(cs, nextTracks[i]),
            ],
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(right: _kModeButtonRightInset),
              child: _buildModeButton(cs),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNextCover(ColorScheme cs, Song track) {
    final art = track.artworkUri ?? '';
    return _tappable(
      cover: ClipRRect(
        borderRadius: BorderRadius.circular(_kNextCoverRadius),
        child: SizedBox(
          width: _kNextCoverSize,
          height: _kNextCoverSize,
          child: art.isEmpty
              ? _coverPlaceholder(cs, 18)
              : DiscoveryCoverImage(
                  url: art,
                  memCacheWidth: 144,
                  error: _coverPlaceholder(cs, 18),
                ),
        ),
      ),
      radius: _kNextCoverRadius,
      label: '接下来播放 ${track.title}',
      tooltip: '播放：${track.title}',
      onTap: () => _openTrack(track),
    );
  }

  Widget _buildModeButton(ColorScheme cs) {
    final open = _drawerOpen;
    return MergeSemantics(
      child: Semantics(
        button: true,
        expanded: open,
        label: '漫游模式与设置',
        child: Tooltip(
          message: open ? '收起' : '漫游模式',
          child: Material(
            color: open ? cs.primary : cs.surfaceContainerHigh,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _toggleDrawer,
              child: SizedBox(
                width: _kModeButtonSize,
                height: _kModeButtonSize,
                child: Center(
                  child: Icon(
                    Icons.tune_rounded,
                    size: 20,
                    color: open ? cs.onPrimary : cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeDrawer(
    ColorScheme cs,
    TextTheme textTheme,
    DiscoverSourceProvider ds,
  ) {
    final options = ds.fmModeOptions;
    return ClipRect(
      child: AnimatedAlign(
        alignment: Alignment.topLeft,
        heightFactor: _drawerOpen ? 1.0 : 0.0,
        duration: _kDrawerDuration,
        curve: _kDrawerCurve,
        child: AnimatedOpacity(
          opacity: _drawerOpen ? 1.0 : 0.0,
          duration: _kDrawerDuration,
          curve: Curves.easeInOut,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '漫游模式 · ${ds.source.label}',
                  style: textTheme.labelLarge?.copyWith(
                    color: _onDrawerColor(cs),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in options)
                      ChoiceChip(
                        label: Text(o.label),
                        selected: o.value == ds.fmMode,
                        onSelected: (_) => ds.setFmMode(o.value),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    '自动漫游',
                    style: textTheme.bodyMedium?.copyWith(
                      color: _onDrawerColor(cs),
                    ),
                  ),
                  subtitle: Text(
                    '队列见底时按当前模式继续推歌',
                    style: textTheme.bodySmall?.copyWith(
                      color: _onDrawerColor(cs).withValues(alpha: 0.75),
                    ),
                  ),
                  value: ds.autoRoaming,
                  onChanged: (v) => ds.setAutoRoaming(v),
                ),
                if (widget.onOpenAll != null && ds.fmSongs.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: widget.onOpenAll,
                      child: const Text('查看全部'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFavoriteButton(ColorScheme cs, Song? current) {
    if (current == null) {
      return IconButton(
        tooltip: '收藏',
        onPressed: null,
        icon: const Icon(Icons.favorite_border),
        color: cs.onSurfaceVariant,
      );
    }
    return Selector<FavoritesProvider, bool>(
      selector: (_, fav) => fav.isFavorite(current.id),
      builder: (context, isFavorite, _) {
        return IconButton(
          tooltip: isFavorite ? '取消收藏' : '收藏',
          onPressed: () =>
              context.read<FavoritesProvider>().toggleFavorite(current),
          icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
          color: isFavorite ? cs.primary : cs.onSurfaceVariant,
        );
      },
    );
  }

  Widget _buildPlayButton(
    ColorScheme cs,
    Song? current,
    bool isPlaying,
    bool loading,
  ) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _handlePlay(current),
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: loading
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: cs.primary,
                    ),
                  )
                : Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: cs.primary,
                    size: 28,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _tappable({
    required Widget cover,
    required double radius,
    required String label,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return MergeSemantics(
      child: Semantics(
        label: label,
        child: Tooltip(
          message: tooltip,
          child: Stack(
            children: [
              cover,
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(radius),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(onTap: onTap),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs, double iconSize) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note,
          size: iconSize,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
