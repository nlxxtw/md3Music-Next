import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/discover_source_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/discovery_api/discovery_api_client.dart';
import '../../widgets/discovery_cover_image.dart';
import '../../widgets/song_list_item.dart';
import 'remote_fm_section.dart';
import 'remote_playlist_page.dart';
import 'remote_toplist_page.dart';

/// 发现页 · QQ / 汽水 / 网易云远程内容。
class RemoteDiscoverBody extends StatelessWidget {
  const RemoteDiscoverBody({super.key});

  void _openFmAll(BuildContext context, DiscoverSourceProvider ds) {
    if (ds.fmSongs.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _RemoteFmDetailPage(
          title: '${ds.source.label} · ${ds.fmModeLabel}',
          songs: List<Song>.from(ds.fmSongs),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.watch<DiscoverSourceProvider>();
    final cs = Theme.of(context).colorScheme;
    final hasContent =
        ds.playlists.isNotEmpty || ds.toplists.isNotEmpty || ds.fmSongs.isNotEmpty;

    if (ds.loading && !hasContent) {
      return const Center(child: CircularProgressIndicator());
    }

    if (ds.error != null && !hasContent) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '加载失败\n${ds.error}',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => ds.refreshRemote(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: ds.refreshRemote,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          if (ds.loading && hasContent)
            const LinearProgressIndicator(minHeight: 2),
          RemoteFmSection(
            onOpenAll: () => _openFmAll(context, ds),
          ),
          if (ds.toplists.isNotEmpty) ...[
            const _SectionTitle(title: '排行榜'),
            SizedBox(
              height: 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: ds.toplists.length.clamp(0, 20),
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  final t = ds.toplists[i];
                  return _CoverCard(
                    title: t.name,
                    cover: t.cover,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RemoteToplistPage(toplist: t),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
          _SectionTitle(
            title: ds.source == DiscoverMusicSource.soda ? '推荐歌单' : '热门歌单',
          ),
          if (ds.playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '暂无推荐',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: ds.playlists.length.clamp(0, 30),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.78,
                ),
                itemBuilder: (context, i) {
                  final p = ds.playlists[i];
                  return _PlaylistTile(
                    playlist: p,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RemotePlaylistPage(playlist: p),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _RemoteFmDetailPage extends StatelessWidget {
  final String title;
  final List<Song> songs;

  const _RemoteFmDetailPage({
    required this.title,
    required this.songs,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: songs.length,
        itemBuilder: (context, i) {
          return SongListItem(
            song: songs[i],
            onTap: () {
              final ds = context.read<DiscoverSourceProvider>();
              ds.playFmSongs(context.read<PlayerProvider>(), songs, i);
            },
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const _SectionTitle({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _CoverCard extends StatelessWidget {
  final String title;
  final String cover;
  final VoidCallback onTap;

  const _CoverCard({
    required this.title,
    required this.cover,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 110,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 1,
                child: cover.isEmpty
                    ? ColoredBox(
                        color: cs.surfaceContainerHighest,
                        child: const Icon(Icons.music_note),
                      )
                    : DiscoveryCoverImage(
                        url: cover,
                        memCacheWidth: 220,
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final DiscoveryPlaylist playlist;
  final VoidCallback onTap;

  const _PlaylistTile({required this.playlist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: playlist.cover.isEmpty
                  ? ColoredBox(
                      color: cs.surfaceContainerHighest,
                      child: const Icon(Icons.queue_music),
                    )
                  : DiscoveryCoverImage(
                      url: playlist.cover,
                      memCacheWidth: 400,
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }
}
