import 'package:flutter/material.dart';

/// 音质角标配色：顶级 VIP 用金属/宝石色区分，普通档用中性色。
class QualityBadgeStyle {
  const QualityBadgeStyle({
    required this.foreground,
    required this.background,
    required this.border,
  });

  final Color foreground;
  final Color background;
  final Color border;

  /// 按角标文案取色（不依赖 ColorScheme，保证各主题下 VIP 档辨识度一致）。
  static QualityBadgeStyle of(String? badge, {Brightness brightness = Brightness.light}) {
    final b = (badge ?? '').trim().toLowerCase();
    final dark = brightness == Brightness.dark;

    Color fg(int rgb, [double a = 1]) => Color(rgb).withValues(alpha: a);
    Color bg(int rgb, double a) => Color(rgb).withValues(alpha: a);

    // 全景声 · 琥珀金（最显眼）
    if (b.contains('全景')) {
      return QualityBadgeStyle(
        foreground: dark ? fg(0xFFFBBF24) : fg(0xFF92400E),
        background: bg(0xFFF59E0B, dark ? 0.28 : 0.18),
        border: fg(0xFFF59E0B, dark ? 0.95 : 0.9),
      );
    }
    // 母带 · 赤铜橙
    if (b.contains('母带')) {
      return QualityBadgeStyle(
        foreground: dark ? fg(0xFFFB923C) : fg(0xFF9A3412),
        background: bg(0xFFEA580C, dark ? 0.26 : 0.15),
        border: fg(0xFFF97316, dark ? 0.95 : 0.88),
      );
    }
    // 环绕 · 青绿
    if (b.contains('环绕')) {
      return QualityBadgeStyle(
        foreground: dark ? fg(0xFF2DD4BF) : fg(0xFF0F766E),
        background: bg(0xFF14B8A6, dark ? 0.26 : 0.14),
        border: fg(0xFF14B8A6, dark ? 0.95 : 0.88),
      );
    }
    // 杜比 · 靛蓝
    if (b.contains('杜比')) {
      return QualityBadgeStyle(
        foreground: dark ? fg(0xFF93C5FD) : fg(0xFF1E3A8A),
        background: bg(0xFF3B82F6, dark ? 0.28 : 0.14),
        border: fg(0xFF60A5FA, dark ? 0.95 : 0.88),
      );
    }
    // 蝰蛇 · 翠绿
    if (b.contains('蝰蛇')) {
      return QualityBadgeStyle(
        foreground: dark ? fg(0xFF6EE7B7) : fg(0xFF065F46),
        background: bg(0xFF10B981, dark ? 0.26 : 0.14),
        border: fg(0xFF34D399, dark ? 0.95 : 0.88),
      );
    }
    // 臻音 / 录音室 · 香槟金
    if (b.contains('臻音') || b.contains('录音室')) {
      return QualityBadgeStyle(
        foreground: dark ? fg(0xFFFDE68A) : fg(0xFF854D0E),
        background: bg(0xFFEAB308, dark ? 0.24 : 0.14),
        border: fg(0xFFFACC15, dark ? 0.9 : 0.85),
      );
    }
    // Hi-Res · 矢车菊蓝
    if (b.contains('hi-res') || b.contains('hires')) {
      return QualityBadgeStyle(
        foreground: dark ? fg(0xFF93C5FD) : fg(0xFF1E40AF),
        background: bg(0xFF60A5FA, dark ? 0.22 : 0.12),
        border: fg(0xFF3B82F6, 0.85),
      );
    }
    // SQ / 无损 · 松绿
    if (b == 'sq' || b.contains('无损')) {
      return QualityBadgeStyle(
        foreground: dark ? fg(0xFF86EFAC) : fg(0xFF166534),
        background: bg(0xFF22C55E, dark ? 0.20 : 0.11),
        border: fg(0xFF16A34A, 0.8),
      );
    }
    // HQ / 极高 · 琥珀
    if (b == 'hq' || b.contains('极高') || b.contains('高品')) {
      return QualityBadgeStyle(
        foreground: dark ? fg(0xFFFCD34D) : fg(0xFFB45309),
        background: bg(0xFFFBBF24, dark ? 0.20 : 0.11),
        border: fg(0xFFD97706, 0.75),
      );
    }
    // 标准 · 中性灰
    return QualityBadgeStyle(
      foreground: dark ? fg(0xFFCBD5E1) : fg(0xFF64748B),
      background: dark ? bg(0xFF94A3B8, 0.14) : bg(0xFF94A3B8, 0.10),
      border: dark ? fg(0xFF94A3B8, 0.55) : fg(0xFF94A3B8, 0.65),
    );
  }

  /// 播放页音质 pill：VIP 用彩色字+色晕边，普通档白字半透明底。
  static QualityBadgeStyle forPlayerPill(String? label) {
    final base = of(label, brightness: Brightness.dark);
    final b = (label ?? '').trim().toLowerCase();
    final isVip = b.contains('全景') ||
        b.contains('母带') ||
        b.contains('环绕') ||
        b.contains('杜比') ||
        b.contains('蝰蛇') ||
        b.contains('臻音') ||
        b.contains('录音室');
    if (!isVip) {
      return const QualityBadgeStyle(
        foreground: Colors.white,
        background: Color(0x26FFFFFF),
        border: Color(0x00FFFFFF),
      );
    }
    return QualityBadgeStyle(
      foreground: Colors.white,
      background: base.border.withValues(alpha: 0.42),
      border: base.border.withValues(alpha: 0.95),
    );
  }
}
