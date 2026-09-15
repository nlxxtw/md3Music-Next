import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/discover_source_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/discovery_api/discovery_api_client.dart';
import '../../widgets/scroll_aware_app_bar.dart';

class RemoteToplistPage extends StatefulWidget {
  final DiscoveryToplist toplist;

  const RemoteToplistPage({super.key, required this.toplist});

  @override
  State<RemoteToplistPage> createState() => _RemoteToplistPageState();
}

class _RemoteToplistPageState extends State<RemoteToplistPage> {
  final _scroll = ScrollController();
  bool _loading = true;
  String? _error;
  List<Song> _songs = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = context.read<DiscoverSourceProvider>().client;
      final songs = await client.getToplistSongs(widget.toplist.id);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: widget.toplist.name,
        scrollController: _scroll,
        opaque: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      TextButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: _songs.length,
                  itemBuilder: (context, i) {
                    final s = _songs[i];
                    return ListTile(
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: i < 3
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                            ),
                          ),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: s.artworkUri == null
                                  ? const ColoredBox(
                                      color: Colors.black12,
                                      child: Icon(Icons.music_note),
                                    )
                                  : CachedNetworkImage(
                                      imageUrl: s.artworkUri!,
                                      fit: BoxFit.cover,
                                      memCacheWidth: 96,
                                    ),
                            ),
                          ),
                        ],
                      ),
                      title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        context.read<PlayerProvider>().playOnlinePlaylist(_songs, i);
                      },
                    );
                  },
                ),
    );
  }
}
