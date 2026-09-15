/// 私人漫游模式 —— 对齐 OpenMusic `fmMode.ts` / `metingFm.js`。
/// 网易 / 汽水：模式作为 meting `id` 传递；QQ 仅默认猜你喜欢。
class FmModeOption {
  const FmModeOption({
    required this.value,
    required this.label,
    this.description = '',
  });
  final String value;
  final String label;
  final String description;
}

class FmModes {
  static const defaultMode = 'DEFAULT';

  static const netease = <FmModeOption>[
    FmModeOption(
      value: 'DEFAULT',
      label: '默认漫游',
      description: '综合听歌记录，常规个性化推荐',
    ),
    FmModeOption(
      value: 'FAMILIAR',
      label: '熟悉模式',
      description: '多推收藏、常听与相似曲风',
    ),
    FmModeOption(
      value: 'EXPLORE',
      label: '探索模式',
      description: '多推新歌、冷门歌，拓展曲库',
    ),
    FmModeOption(
      value: 'SCENE_RCMD:EXERCISE',
      label: '运动场景',
      description: '节奏明快，适合锻炼',
    ),
    FmModeOption(
      value: 'SCENE_RCMD:FOCUS',
      label: '专注场景',
      description: '适合工作、学习，偏轻音乐',
    ),
    FmModeOption(
      value: 'SCENE_RCMD:NIGHT_EMO',
      label: '深夜场景',
      description: '夜晚情绪向慢歌',
    ),
    FmModeOption(
      value: 'aidj',
      label: 'AI DJ',
      description: 'AI 串烧混剪，曲间带过渡衔接',
    ),
  ];

  static const qq = <FmModeOption>[
    FmModeOption(
      value: 'DEFAULT',
      label: '猜你喜欢',
      description: 'QQ 音乐个性化推荐',
    ),
  ];

  static const soda = <FmModeOption>[
    FmModeOption(
      value: 'DEFAULT',
      label: '推荐模式',
      description: '综合你的听歌偏好，智能推荐歌曲',
    ),
    FmModeOption(
      value: 'FAMILIAR',
      label: '熟悉模式',
      description: '更多你听过或相似风格的歌曲',
    ),
    FmModeOption(
      value: 'FRESH',
      label: '新鲜模式',
      description: '发现更多没听过的新歌',
    ),
    FmModeOption(
      value: 'SCENE_MODE_ID:2',
      label: '动感健身',
      description: '节奏明快，适合运动锻炼',
    ),
    FmModeOption(
      value: 'SCENE_MODE_ID:3',
      label: 'Chill 放松',
      description: '舒缓放松，适合安静聆听',
    ),
    FmModeOption(
      value: 'SCENE_MODE_ID:5',
      label: '快乐时光',
      description: '轻松明快，保持好心情',
    ),
    FmModeOption(
      value: 'SCENE_MODE_ID:40',
      label: '夜晚',
      description: '适合夜间聆听的氛围歌曲',
    ),
    FmModeOption(
      value: 'SCENE_MODE_ID:21',
      label: '治愈',
      description: '温柔舒缓，陪你放松心情',
    ),
    FmModeOption(
      value: 'SCENE_MODE_ID:18',
      label: '小酒馆',
      description: '微醺氛围感歌曲',
    ),
  ];

  static List<FmModeOption> optionsFor(String apiSource) {
    switch (apiSource) {
      case 'soda':
        return soda;
      case 'qq':
        return qq;
      case 'netease':
        return netease;
      default:
        return const [
          FmModeOption(value: 'DEFAULT', label: '默认漫游'),
        ];
    }
  }

  static String normalize(String? raw, String apiSource) {
    final v = (raw ?? '').trim();
    if (v.isEmpty) return defaultMode;
    final opts = optionsFor(apiSource);
    for (final o in opts) {
      if (o.value == v) return v;
    }
    return defaultMode;
  }

  static String labelOf(String? raw, String apiSource) {
    final v = normalize(raw, apiSource);
    for (final o in optionsFor(apiSource)) {
      if (o.value == v) return o.label;
    }
    return '默认漫游';
  }

  /// 传给 qqovo meting 的 id：DEFAULT / QQ 不传。
  static String? metingId(String mode, String apiSource) {
    final v = normalize(mode, apiSource);
    if (apiSource == 'qq' || v == defaultMode) return null;
    return v;
  }
}
