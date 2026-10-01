import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/services/output_mode_coordinator.dart';
import '../core/services/usb_audio_service.dart';
import '../core/utils/app_toast.dart';
import 'direct_pcm_section.dart';

/// USB bit-perfect 输出设置板块（设置页 / 歌曲信息页共用）。
///
/// **两层开关**（见 [OutputModeCoordinator]）：
/// 1. 外层「USB 独占输出」总开关 —— 关闭即系统默认。
/// 2. 内层「改用系统 Direct PCM」—— 仅总开关打开时出现。
///
/// 直写侧保留音量 / MV 自动关独占；Direct PCM 侧见 [DirectPcmSection]。
class UsbExclusiveSection extends StatefulWidget {
  final VoidCallback? onAutoPause;

  const UsbExclusiveSection({super.key, this.onAutoPause});

  @override
  State<UsbExclusiveSection> createState() => _UsbExclusiveSectionState();
}

class _UsbExclusiveSectionState extends State<UsbExclusiveSection> {
  Map<String, dynamic> _status = const {};
  bool _loading = false;
  bool _wasDeviceConnected = false;
  int _lostPolls = 0;
  double _usbVolume = 1.0;

  StreamSubscription<Map<String, dynamic>>? _statusSub;
  Timer? _pollTimer;
  VoidCallback? _modeListener;

  @override
  void initState() {
    super.initState();
    _status = UsbAudioService.instance.lastStatus;
    _statusSub = UsbAudioService.instance.statusStream.listen(_onStatus);
    _wasDeviceConnected = _status['deviceConnected'] == true;
    _modeListener = () {
      if (mounted) setState(() {});
    };
    OutputModeCoordinator.instance.addListener(_modeListener!);
    _usbVolume =
        (UsbAudioService.instance.usbVolumePercent / 100).clamp(0.0, 1.0);
    UsbAudioService.instance.refresh();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      UsbAudioService.instance.refresh();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _statusSub?.cancel();
    if (_modeListener != null) {
      OutputModeCoordinator.instance.removeListener(_modeListener!);
    }
    super.dispose();
  }

  void _onStatus(Map<String, dynamic> s) {
    if (!mounted) return;
    setState(() => _status = s);
    final nowConnected = s['deviceConnected'] == true;
    if (OutputModeCoordinator.instance.enabled) {
      if (!nowConnected) {
        _lostPolls++;
        if (_lostPolls >= 2) {
          widget.onAutoPause?.call();
          OutputModeCoordinator.instance.onDeviceLost().then((_) {
            final notice =
                OutputModeCoordinator.instance.consumeFallbackNotice();
            if (notice != null && mounted) showToast(notice);
          });
          _lostPolls = 0;
        }
      } else {
        _lostPolls = 0;
      }
    }
    _wasDeviceConnected = nowConnected;
  }

  Future<void> _toggleMaster(bool value) async {
    setState(() => _loading = true);
    try {
      HapticFeedback.lightImpact();
      await OutputModeCoordinator.instance.setEnabled(value);
      if (value && !OutputModeCoordinator.instance.enabled) {
        showToast(
          OutputModeCoordinator.instance.consumeFallbackNotice() ??
              'USB 独占开启失败',
          long: true,
        );
      } else {
        OutputModeCoordinator.instance.consumeFallbackNotice();
      }
      final s = await UsbAudioService.instance.getStatus();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) showToast('输出模式切换失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleViaSystem(bool value) async {
    setState(() => _loading = true);
    try {
      HapticFeedback.lightImpact();
      await OutputModeCoordinator.instance.setViaSystem(value);
      if (!OutputModeCoordinator.instance.enabled) {
        showToast(
          OutputModeCoordinator.instance.consumeFallbackNotice() ??
              '输出模式切换失败',
          long: true,
        );
      } else {
        final notice = OutputModeCoordinator.instance.consumeFallbackNotice();
        if (notice != null) showToast(notice, long: true);
      }
      final s = await UsbAudioService.instance.getStatus();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) showToast('方案切换失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final mode = OutputModeCoordinator.instance;
    final modeEnabled = mode.enabled;
    final viaSystem = mode.viaSystem;
    final viaSystemActive = mode.isDirectPcmActive;
    final connected = _status['deviceConnected'] == true;
    final deviceName = _status['deviceName'] as String? ?? '未知设备';
    final canEnable = connected || viaSystem || modeEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          title: const Text('USB 独占输出'),
          subtitle: Text(
            modeEnabled
                ? (viaSystemActive
                    ? '系统 Direct PCM · bit-perfect 兼容路径'
                    : 'usbdevfs 直写 · 绕开 AudioFlinger')
                : (connected
                    ? '已检测到 USB 音频设备，可开启 bit-perfect'
                    : '未检测到 USB 音频设备'),
          ),
          value: modeEnabled,
          onChanged: (_loading || !canEnable) ? null : _toggleMaster,
        ),
        if (modeEnabled) ...[
          SwitchListTile(
            title: const Text('改用系统 Direct PCM'),
            subtitle: const Text(
              '兼容性更好；关闭则走 USB 直写（音质最好，挑 DAC）',
            ),
            value: viaSystem,
            onChanged: _loading ? null : _toggleViaSystem,
          ),
          if (viaSystemActive)
            const DirectPcmSection()
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connected ? deviceName : '等待 USB DAC',
                      style: textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _statusLine(),
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            FutureBuilder<bool>(
              future: UsbAudioService.instance.getAutoDisableForMv(),
              builder: (context, snap) {
                final v = snap.data ?? true;
                return SwitchListTile(
                  title: const Text('播放 MV 时自动关闭独占'),
                  subtitle: const Text('避免与视频解码抢 USB 音频设备'),
                  value: v,
                  onChanged: (nv) async {
                    HapticFeedback.lightImpact();
                    await UsbAudioService.instance.setAutoDisableForMv(nv);
                    if (mounted) setState(() {});
                  },
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('USB 音量', style: textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Slider(
                value: _usbVolume,
                onChanged: (v) {
                  setState(() => _usbVolume = v);
                  UsbAudioService.instance.setUsbVolume(v * 100);
                },
                label: '${(_usbVolume * 100).round()}%',
              ),
            ),
          ],
        ],
      ],
    );
  }

  String _statusLine() {
    final enabled = _status['enabled'] == true;
    final ready = _status['streamReady'] == true;
    final rate = (_status['sampleRate'] as num?)?.toInt() ?? 0;
    final ch = (_status['channelCount'] as num?)?.toInt() ?? 0;
    final bits = (_status['dacBitDepth'] as num?)?.toInt() ?? 0;
    if (!enabled) return '直写未激活';
    if (!ready) return '建流中…';
    final parts = <String>[];
    if (rate > 0) parts.add('$rate Hz');
    if (ch > 0) parts.add('${ch}ch');
    if (bits > 0) parts.add('${bits}bit');
    return parts.isEmpty ? '流已就绪' : parts.join(' · ');
  }
}
