import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/discovery_cover_image.dart';
import '../../widgets/scroll_aware_app_bar.dart';

/// QQ / 汽水发现曲的本地收藏（不进酷狗「我喜欢」）。
class RemoteFavoritesPage extends StatefulWidget {
  const RemoteFavoritesPage({super.key});

  @override
  State<RemoteFavoritesPage> createState() => _RemoteFavoritesPageState();
}

class _RemoteFavoritesPageState extends State<RemoteFavoritesPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _sourceLabel(Song s) => s.sourceLabel;

  @override
  Widget build(BuildContext context) {
    final fav = context.watch<FavoritesProvider>();
    final songs = fav.remoteDiscoveryFavorites;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '发现收藏',
        scrollController: _scroll,
        opaque: true,
        actions: [
          if (songs.isNotEmpty)
            IconButton(
              tooltip: '播放全部',
              icon: const Icon(Icons.play_arrow),
              onPressed: () {
                context.read<PlayerProvider>().playOnlinePlaylist(songs, 0);
              },
            ),
        ],
      ),
      body: songs.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.favorite_border,
                      size: 56,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.35),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '还没有发现收藏',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '在 QQ / 汽水里点红心，会保存在本机，不会同步到酷狗。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.only(
                bottom: 100 + MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: songs.length,
              itemBuilder: (context, i) {
                final s = songs[i];
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: s.artworkUri == null || s.artworkUri!.isEmpty
                          ? ColoredBox(
                              color: cs.surfaceContainerHighest,
                              child: const Icon(Icons.music_note),
                            )
                          : DiscoveryCoverImage(
                              url: s.artworkUri!,
                              memCacheWidth: 96,
                            ),
                    ),
                  ),
                  title: Text(
                    s.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${s.artist} · ${_sourceLabel(s)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: '取消收藏',
                    icon: Icon(Icons.favorite, color: cs.error),
                    onPressed: () => fav.toggleFavorite(s),
                  ),
                  onTap: () {
                    context.read<PlayerProvider>().playOnlinePlaylist(songs, i);
                  },
                );
              },
            ),
    );
  }
}
