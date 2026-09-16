import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../providers/discover_source_provider.dart';
import '../../services/discovery_api/discovery_api_client.dart';
import '../../widgets/discovery_cover_image.dart';
import 'remote_playlist_page.dart';

/// 发现页 · 搜索歌单（网易 cloudsearch；QQ/汽水在推荐池按名过滤）。
class RemotePlaylistSearchPage extends StatefulWidget {
  final DiscoverMusicSource source;

  const RemotePlaylistSearchPage({super.key, required this.source});

  @override
  State<RemotePlaylistSearchPage> createState() =>
      _RemotePlaylistSearchPageState();
}

class _RemotePlaylistSearchPageState extends State<RemotePlaylistSearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  bool _loading = false;
  String? _error;
  String _query = '';
  List<DiscoveryPlaylist> _playlists = const [];

  String get _apiSource => widget.source.apiSource!;
  String get _label => widget.source.label;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    setState(() {
      _query = q;
      _loading = true;
      _error = null;
    });
    try {
      final list = await context
          .read<DiscoverSourceProvider>()
          .client
          .searchPlaylists(source: _apiSource, keyword: q);
      if (!mounted) return;
      setState(() {
        _playlists = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _playlists = const [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索$_label歌单',
            border: InputBorder.none,
            hintStyle: TextStyle(color: cs.onSurfaceVariant),
          ),
          onSubmitted: _search,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _search(_controller.text),
          ),
        ],
      ),
      body: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => _search(_query),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_query.isEmpty) {
      return Center(
        child: Text(
          widget.source == DiscoverMusicSource.netease
              ? '输入关键词搜索歌单'
              : '输入关键词，在推荐歌单中筛选',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    if (_playlists.isEmpty) {
      return Center(
        child: Text('无结果', style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: _playlists.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final p = _playlists[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: p.cover.isEmpty
                  ? ColoredBox(
                      color: cs.surfaceContainerHighest,
                      child: const Icon(Icons.queue_music),
                    )
                  : DiscoveryCoverImage(
                      url: p.cover,
                      memCacheWidth: 168,
                      error: ColoredBox(
                        color: cs.surfaceContainerHighest,
                        child: const Icon(Icons.queue_music),
                      ),
                    ),
            ),
          ),
          title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (p.creator.isNotEmpty) p.creator,
              if (p.trackCount > 0) '${p.trackCount} 首',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => RemotePlaylistPage(playlist: p),
              ),
            );
          },
        );
      },
    );
  }
}
