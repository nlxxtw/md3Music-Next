import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/player_provider.dart';

/// 回归：QQ/网易/汽水自动下一首时，旧 sequence tag 不得把 currentSong 打回上一首。
///
/// 否则会出现「只有声音切到下一首，歌名/封面/歌词还停在上一首」。
void main() {
  group('shouldIgnoreStaleRemoteSequenceTag', () {
    test('解析下一首远程曲时，旧歌 tag 必须忽略（全部 UI 才能跟声音同步）', () {
      final ignore = shouldIgnoreStaleRemoteSequenceTag(
        tagId: 'netease:111',
        currentSongId: 'netease:222',
        isResolvingUrl: true,
        currentIsRemoteDiscovery: true,
        taggedSongIsRemoteDiscovery: true,
      );
      expect(ignore, isTrue);
    });

    test('远程单曲播放中，任何与当前不一致的旧 tag 都忽略', () {
      final ignore = shouldIgnoreStaleRemoteSequenceTag(
        tagId: 'qq:old',
        currentSongId: 'qq:new',
        isResolvingUrl: false,
        currentIsRemoteDiscovery: true,
        taggedSongIsRemoteDiscovery: true,
      );
      expect(ignore, isTrue);
    });

    test('tag 已是当前曲：不忽略（允许正常对齐）', () {
      final ignore = shouldIgnoreStaleRemoteSequenceTag(
        tagId: 'soda:1',
        currentSongId: 'soda:1',
        isResolvingUrl: true,
        currentIsRemoteDiscovery: true,
        taggedSongIsRemoteDiscovery: true,
      );
      expect(ignore, isFalse);
    });

    test('酷狗 Concatenating 队列推进：非远程时仍应用 sequence（不误伤）', () {
      final ignore = shouldIgnoreStaleRemoteSequenceTag(
        tagId: 'kugou-hash-a',
        currentSongId: 'kugou-hash-b',
        isResolvingUrl: false,
        currentIsRemoteDiscovery: false,
        taggedSongIsRemoteDiscovery: false,
      );
      expect(ignore, isFalse);
    });

    test('正在解析且目标是远程、旧 tag 是远程：忽略', () {
      final ignore = shouldIgnoreStaleRemoteSequenceTag(
        tagId: 'netease:old',
        currentSongId: 'netease:new',
        isResolvingUrl: true,
        currentIsRemoteDiscovery: false,
        taggedSongIsRemoteDiscovery: true,
      );
      expect(ignore, isTrue);
    });

    test('无当前曲时不忽略（避免空列表误伤）', () {
      final ignore = shouldIgnoreStaleRemoteSequenceTag(
        tagId: 'netease:1',
        currentSongId: null,
        isResolvingUrl: true,
        currentIsRemoteDiscovery: true,
        taggedSongIsRemoteDiscovery: true,
      );
      expect(ignore, isFalse);
    });
  });
}
