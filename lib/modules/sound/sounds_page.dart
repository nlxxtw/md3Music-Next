import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart' hide M3EPullToRefreshIndicator;

import '../../core/services/convolution_service.dart';
import '../../core/utils/app_toast.dart';

/// 本地 IRS 卷积音效页：使用内置蝰蛇/杜比脉冲包做真卷积。
class SoundsPage extends StatefulWidget {
  const SoundsPage({super.key});

  @override
  State<SoundsPage> createState() => _SoundsPageState();
}

class _SoundsPageState extends State<SoundsPage> {
  final ConvolutionService _conv = ConvolutionService.instance;
  String? _tagFilter;
  bool _loading = true;

  static const _tagOrder = ['全部', '8D', '双耳3D', '杜比', 'SRS', 'DTS', '蝰蛇', '环绕'];

  @override
  void initState() {
    super.initState();
    _conv.addListener(_onChanged);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (!_conv.ready) {
      await _conv.init();
    }
    if (mounted) setState(() => _loading = false);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _conv.removeListener(_onChanged);
    super.dispose();
  }

  List<LocalSoundPreset> get _visible {
    final all = _conv.presets;
    if (_tagFilter == null || _tagFilter == '全部') return all;
    return all.where((e) => e.tag == _tagFilter).toList();
  }

  Future<void> _apply(LocalSoundPreset item) async {
    try {
      await _conv.apply(item);
      if (!mounted) return;
      showToast('已应用「${item.name}」· 卷积脉冲');
    } catch (e) {
      showToast('应用失败：$e');
    }
  }

  Future<void> _unapply() async {
    await _conv.clear();
    if (!mounted) return;
    showToast('已关闭卷积音效');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('音效'),
        actions: [
          if (_conv.appliedFile != null)
            TextButton(
              onPressed: _unapply,
              child: const Text('关闭'),
            ),
        ],
      ),
      body: !_conv.isSupported
          ? Center(
              child: Text(
                '卷积音效仅支持 Android',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            )
          : _loading
              ? const Center(child: M3ELoadingIndicator())
              : Column(
                  children: [
                    _buildBanner(cs),
                    _buildTags(cs),
                    Expanded(child: _buildList(cs)),
                  ],
                ),
    );
  }

  Widget _buildBanner(ColorScheme cs) {
    final name = _conv.appliedName;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(Icons.surround_sound, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name == null ? '未应用卷积音效' : '当前：$_nameSafe',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '内置 ${_conv.presets.length} 个脉冲 · 真卷积（非均衡器模拟）',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            if (_conv.appliedFile != null)
              Switch(
                value: _conv.enabled,
                onChanged: (v) async {
                  await _conv.setEnabled(v);
                  showToast(v ? '已开启卷积' : '已暂停卷积');
                },
              ),
          ],
        ),
      ),
    );
  }

  String get _nameSafe => _conv.appliedName ?? '';

  Widget _buildTags(ColorScheme cs) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: _tagOrder.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final tag = _tagOrder[i];
          final selected =
              (_tagFilter == null && tag == '全部') || _tagFilter == tag;
          return FilterChip(
            label: Text(tag),
            selected: selected,
            onSelected: (_) {
              setState(() => _tagFilter = tag == '全部' ? null : tag);
            },
          );
        },
      ),
    );
  }

  Widget _buildList(ColorScheme cs) {
    final list = _visible;
    if (list.isEmpty) {
      return Center(
        child: Text(
          '暂无脉冲文件',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final it = list[i];
        final applied = _conv.appliedFile == it.file && _conv.enabled;
        return ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          tileColor: applied
              ? cs.primaryContainer.withValues(alpha: 0.45)
              : cs.surfaceContainerLow,
          leading: CircleAvatar(
            backgroundColor: cs.secondaryContainer,
            child: Text(
              it.tag.characters.first,
              style: TextStyle(color: cs.onSecondaryContainer),
            ),
          ),
          title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${it.tag} · ${it.file}'),
          trailing: applied
              ? FilledButton.tonal(
                  onPressed: _unapply,
                  child: const Text('取消'),
                )
              : FilledButton(
                  onPressed: () => _apply(it),
                  child: const Text('应用'),
                ),
          onTap: () => _showDetail(it, applied),
        );
      },
    );
  }

  void _showDetail(LocalSoundPreset it, bool applied) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(it.name, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('分类：${it.tag}'),
              Text('文件：${it.file}'),
              const SizedBox(height: 8),
              Text(
                '通过播放链路内 FIR 卷积加载该脉冲，听感接近蝰蛇/杜比类 IRS 效果（取决于脉冲本身）。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        if (applied) {
                          _unapply();
                        } else {
                          _apply(it);
                        }
                      },
                      child: Text(applied ? '取消应用' : '应用卷积'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
