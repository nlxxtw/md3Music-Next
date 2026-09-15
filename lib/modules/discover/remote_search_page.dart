import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/discover_source_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/song_list_item.dart';

/// QQ / 汽水 / 网易云搜索：列表先出，点播再解析直链。
class RemoteSearchPage extends StatefulWidget {
  final DiscoverMusicSource source;

  const RemoteSearchPage({super.key, required this.source});

  @override
  State<RemoteSearchPage> createState() => _RemoteSearchPageState();
}

class _RemoteSearchPageState extends State<RemoteSearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  bool _loading = false;
  String? _error;
  String _query = '';
  List<Song> _songs = const [];

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
      final songs = await context.read<DiscoverSourceProvider>().client.searchSongs(
            source: _apiSource,
            keyword: q,
            limit: 30,
          );
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _songs = const [];
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
            hintText: '搜索$_label歌曲',
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
          '输入关键词搜索',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    if (_songs.isEmpty) {
      return Center(
        child: Text('无结果', style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: _songs.length,
      itemBuilder: (context, i) {
        return SongListItem(
          song: _songs[i],
          onTap: () {
            context.read<PlayerProvider>().playOnlinePlaylist(_songs, i);
          },
          onMoreTap: () {},
        );
      },
    );
  }
}
