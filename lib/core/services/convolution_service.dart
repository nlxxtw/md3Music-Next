import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置 IRS 脉冲条目（assets/sound_presets/manifest.json）。
class LocalSoundPreset {
  final int id;
  final String file;
  final String name;
  final String fullName;
  final String tag;

  const LocalSoundPreset({
    required this.id,
    required this.file,
    required this.name,
    required this.fullName,
    required this.tag,
  });

  factory LocalSoundPreset.fromJson(Map<String, dynamic> json) {
    return LocalSoundPreset(
      id: (json['id'] as num?)?.toInt() ?? 0,
      file: json['file']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      fullName: json['fullName']?.toString() ?? '',
      tag: json['tag']?.toString() ?? '环绕',
    );
  }
}

/// 本地 IRS 卷积服务：Dart 解压内置 zip，再经 MethodChannel 加载到播放链路。
class ConvolutionService extends ChangeNotifier {
  static final ConvolutionService instance = ConvolutionService._();

  ConvolutionService._();

  static const _channel = MethodChannel('com.md3music.md3music/convolution');
  static const _prefsFileKey = 'conv_applied_file';
  static const _prefsNameKey = 'conv_applied_name';
  static const _prefsEnabledKey = 'conv_enabled';
  static const _extractMarker = '.zip_ver';
  static const _extractVer = 'viper_local_v13_1_echomusic_orbit';

  List<LocalSoundPreset> _presets = const [];
  String? _appliedFile;
  String? _appliedName;
  bool _enabled = false;
  bool _ready = false;
  Directory? _presetDir;

  List<LocalSoundPreset> get presets => List.unmodifiable(_presets);
  String? get appliedFile => _appliedFile;
  String? get appliedName => _appliedName;
  bool get enabled => _enabled;
  bool get ready => _ready;
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// 与 EchoMusic 静态 IR 不同：这些条目靠运行时 orbit 做左右绕转。
  static bool isOrbitPreset(LocalSoundPreset preset) {
    if (preset.tag == '8D') return true;
    final f = preset.file;
    return f.startsWith('8D') ||
        f.startsWith('双耳') ||
        f.toLowerCase().contains('vox8d');
  }

  Future<void> init() async {
    if (!isSupported) return;
    try {
      final raw =
          await rootBundle.loadString('assets/sound_presets/manifest.json');
      final list = jsonDecode(raw);
      if (list is List) {
        _presets = list
            .whereType<Map>()
            .map((e) => LocalSoundPreset.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.file.isNotEmpty)
            .toList();
      }
      final prefs = await SharedPreferences.getInstance();
      _appliedFile = prefs.getString(_prefsFileKey);
      _appliedName = prefs.getString(_prefsNameKey);
      _enabled = prefs.getBool(_prefsEnabledKey) ?? false;

      _presetDir = await _ensureExtracted();

      if (_enabled && _appliedFile != null && _appliedFile!.isNotEmpty) {
        await loadFile(_appliedFile!);
        await _channel.invokeMethod('setEnabled', {'enabled': true});
      }
      _ready = true;
      notifyListeners();
    } catch (e, st) {
      debugPrint('ConvolutionService.init failed: $e\n$st');
    }
  }

  Future<Directory> _ensureExtracted() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/sound_presets');
    final marker = File('${dir.path}/$_extractMarker');
    if (await dir.exists() &&
        await marker.exists() &&
        (await marker.readAsString()) == _extractVer) {
      final count = dir
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith(_extractMarker))
          .length;
      if (count >= 10) {
        _presetDir = dir;
        return dir;
      }
    }
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    final bytes =
        (await rootBundle.load('assets/sound_presets/viper_local.zip'))
            .buffer
            .asUint8List();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.split('/').last;
      if (!(name.toLowerCase().endsWith('.irs') ||
          name.toLowerCase().endsWith('.wav'))) {
        continue;
      }
      final out = File('${dir.path}/$name');
      await out.writeAsBytes(entry.content as List<int>, flush: true);
    }
    await marker.writeAsString(_extractVer);
    _presetDir = dir;
    return dir;
  }

  Future<void> loadFile(String fileName) async {
    final dir = _presetDir ?? await _ensureExtracted();
    final file = File('${dir.path}/$fileName');
    if (!await file.exists()) {
      throw StateError('脉冲文件不存在: $fileName');
    }
    await _channel.invokeMethod('loadPath', {'path': file.absolute.path});
    await _configureOrbitForFile(fileName);
  }

  /// Dart 再推一档 orbit/mix，避免只靠文件名在 Java 侧误判。
  Future<void> _configureOrbitForFile(String fileName) async {
    LocalSoundPreset? preset;
    for (final p in _presets) {
      if (p.file == fileName) {
        preset = p;
        break;
      }
    }
    final orbit = preset != null
        ? isOrbitPreset(preset)
        : (fileName.startsWith('8D') ||
            fileName.startsWith('双耳') ||
            fileName.toLowerCase().contains('vox8d'));
    if (!orbit) {
      await _channel.invokeMethod('setOrbit', {
        'enabled': false,
        'hz': 0.12,
        'depth': 0.0,
      });
      return;
    }
    var hz = 0.13;
    if (fileName.contains('深空')) {
      hz = 0.08;
    } else if (fileName.contains('近场')) {
      hz = 0.16;
    } else if (fileName.contains('舞台')) {
      hz = 0.11;
    } else if (fileName.contains('宽景')) {
      hz = 0.14;
    }
    // EchoMusic 偏湿；orbit 几乎全湿，位移才听得见
    await _channel.invokeMethod('setMix', {'wet': 0.92, 'dry': 0.08});
    await _channel.invokeMethod('setOrbit', {
      'enabled': true,
      'hz': hz,
      'depth': 0.95,
    });
  }

  Future<void> apply(LocalSoundPreset preset) async {
    if (!isSupported) return;
    await loadFile(preset.file);
    await _channel.invokeMethod('setEnabled', {'enabled': true});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsFileKey, preset.file);
    await prefs.setString(_prefsNameKey, preset.name);
    await prefs.setBool(_prefsEnabledKey, true);
    _appliedFile = preset.file;
    _appliedName = preset.name;
    _enabled = true;
    notifyListeners();
  }

  Future<void> clear() async {
    if (!isSupported) return;
    await _channel.invokeMethod('clear');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsFileKey);
    await prefs.remove(_prefsNameKey);
    await prefs.setBool(_prefsEnabledKey, false);
    _appliedFile = null;
    _appliedName = null;
    _enabled = false;
    notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    if (!isSupported) return;
    if (enabled && (_appliedFile == null || _appliedFile!.isEmpty)) {
      return;
    }
    if (enabled) {
      await loadFile(_appliedFile!);
    }
    await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabledKey, enabled);
    _enabled = enabled;
    notifyListeners();
  }
}
