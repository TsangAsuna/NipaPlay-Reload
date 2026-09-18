import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nipaplay/constants/settings_keys.dart';
import 'package:nipaplay/constants/media_extensions.dart';
import 'package:nipaplay/l10n/app_locale_utils.dart';
import 'package:nipaplay/models/danmaku_auto_load_strategy.dart';
import 'package:nipaplay/utils/external_player_utils.dart';
import 'package:nipaplay/utils/globals.dart' as globals;
import 'package:nipaplay/utils/player_event_log.dart';
import 'package:nipaplay/utils/storage_service.dart';

class SettingsProvider with ChangeNotifier {
  late SharedPreferences _prefs;

  // --- Settings ---
  double _blurPower = 0.0; // Default blur power (无模糊)
  static const double _defaultBlur = 0.0;
  static const String _blurPowerKey = 'blurPower';

  // 弹幕转换简体中文设置
  bool _danmakuConvertToSimplified = true; // 默认开启
  // 哈希匹配失败后自动选择搜索第一个结果（避免弹窗）
  bool _autoMatchDanmakuFirstSearchResultOnHashFail = true; // 默认开启

  DanmakuAutoLoadStrategy _danmakuAutoLoadStrategy =
      DanmakuAutoLoadStrategy.remoteAndLocal;
  bool _skipDanmakuMatching = false;
  bool _fastPlaybackStartup = false;

  // 外部播放器设置
  bool _useExternalPlayer = false;
  String _externalPlayerPath = '';
  ExternalPlayerType _externalPlayerType = ExternalPlayerType.unset;
  bool _externalPlayerDanmakuOverlay = true; // 弹幕外挂默认开启
  bool _externalPlayerAutoSwitchToDanmakuConsole = true;
  bool _externalPlayerShrinkWindow = false;
  bool _externalPlayerConsoleWindowMode = false;

  // GitHub 代理设置
  String _githubProxyUrl = '';

  // 弹幕超采样设置：0.0=关闭, 1.5=1.5x, 2.0=2x
  double _danmakuSupersample = 0.0;

  // --- Getters ---
  double get blurPower => _blurPower;
  bool get isBlurEnabled => _blurPower > 0;
  bool get danmakuConvertToSimplified => _danmakuConvertToSimplified;
  bool get autoMatchDanmakuFirstSearchResultOnHashFail =>
      _autoMatchDanmakuFirstSearchResultOnHashFail;
  DanmakuAutoLoadStrategy get danmakuAutoLoadStrategy =>
      _danmakuAutoLoadStrategy;
  bool get skipDanmakuMatching => _skipDanmakuMatching;
  bool get fastPlaybackStartup => _fastPlaybackStartup;
  bool get useExternalPlayer => _useExternalPlayer;
  String get externalPlayerPath => _externalPlayerPath;
  ExternalPlayerType get externalPlayerType => _externalPlayerType;
  bool get externalPlayerDanmakuOverlay => _externalPlayerDanmakuOverlay;
  bool get externalPlayerAutoSwitchToDanmakuConsole =>
      _externalPlayerAutoSwitchToDanmakuConsole;
  bool get externalPlayerShrinkWindow => _externalPlayerShrinkWindow;
  bool get externalPlayerConsoleWindowMode => _externalPlayerConsoleWindowMode;
  String get githubProxyUrl => _githubProxyUrl;
  double get danmakuSupersample => _danmakuSupersample;

  SettingsProvider() {
    // SharedPreferences loads asynchronously. Expose the correct platform
    // default immediately so iPad does not create a transient 2x texture and
    // rebuild it at 1.5x moments later during player startup.
    _danmakuSupersample = _defaultDanmakuSupersample();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _prefs = await SharedPreferences.getInstance();
    // Load blur power, defaulting to 0.0 if not set (无模糊)
    _blurPower = _prefs.getDouble(_blurPowerKey) ?? _defaultBlur;
    // 当用户仍为“自动语言”且系统为繁中时，首次默认关闭“弹幕转简体”。
    final savedDanmakuConvert =
        _prefs.getBool(SettingsKeys.danmakuConvertToSimplified);
    if (savedDanmakuConvert != null) {
      _danmakuConvertToSimplified = savedDanmakuConvert;
    } else {
      final languageMode =
          _prefs.getString(SettingsKeys.appLanguageMode) ?? 'auto';
      if (languageMode == 'auto') {
        final systemLocale = WidgetsBinding.instance.platformDispatcher.locale;
        _danmakuConvertToSimplified =
            !AppLocaleUtils.isTraditionalChineseLocale(systemLocale);
      } else {
        _danmakuConvertToSimplified = true;
      }
    }
    _autoMatchDanmakuFirstSearchResultOnHashFail = _prefs.getBool(
            SettingsKeys.autoMatchDanmakuFirstSearchResultOnHashFail) ??
        true;
    final persistedStrategy =
        _prefs.getString(SettingsKeys.danmakuAutoLoadStrategy);
    final danmakuAutoLoadSettings = resolveDanmakuAutoLoadSettings(
      persistedStrategy: persistedStrategy,
      persistedSkipMatching: _prefs.getBool(SettingsKeys.skipDanmakuMatching),
      legacyAutoMatchOnPlay:
          _prefs.getBool(SettingsKeys.autoMatchDanmakuOnPlay),
    );
    _danmakuAutoLoadStrategy = danmakuAutoLoadSettings.strategy;
    _skipDanmakuMatching = danmakuAutoLoadSettings.skipMatching;
    _fastPlaybackStartup =
        _prefs.getBool(SettingsKeys.fastPlaybackStartup) ?? false;
    if (persistedStrategy != _danmakuAutoLoadStrategy.prefsValue) {
      await _prefs.setString(
        SettingsKeys.danmakuAutoLoadStrategy,
        _danmakuAutoLoadStrategy.prefsValue,
      );
    }
    if (!_prefs.containsKey(SettingsKeys.skipDanmakuMatching)) {
      await _prefs.setBool(
        SettingsKeys.skipDanmakuMatching,
        _skipDanmakuMatching,
      );
    }
    _useExternalPlayer =
        _prefs.getBool(SettingsKeys.useExternalPlayer) ?? false;
    _externalPlayerPath =
        _prefs.getString(SettingsKeys.externalPlayerPath) ?? '';
    final savedExternalPlayerType =
        _prefs.getString(SettingsKeys.externalPlayerType);
    if (savedExternalPlayerType == null) {
      _externalPlayerType = _externalPlayerPath.isEmpty
          ? ExternalPlayerType.unset
          : detectExternalPlayerType(_externalPlayerPath);
      await _prefs.setString(
        SettingsKeys.externalPlayerType,
        _externalPlayerType.name,
      );
    } else {
      _externalPlayerType = ExternalPlayerType.values.firstWhere(
        (type) => type.name == savedExternalPlayerType,
        orElse: () => ExternalPlayerType.unset,
      );
    }
    _externalPlayerDanmakuOverlay =
        _prefs.getBool(SettingsKeys.externalPlayerDanmakuOverlay) ?? true;
    _externalPlayerAutoSwitchToDanmakuConsole =
        _prefs.getBool(SettingsKeys.externalPlayerAutoSwitchToDanmakuConsole) ??
            true;
    _externalPlayerShrinkWindow =
        _prefs.getBool(SettingsKeys.externalPlayerShrinkWindow) ?? false;
    _externalPlayerConsoleWindowMode =
        _prefs.getBool(SettingsKeys.externalPlayerConsoleWindowMode) ?? false;
    _githubProxyUrl = _prefs.getString(SettingsKeys.githubProxyUrl) ?? '';
    // 弹幕超采样：权威存档是字符串键 danmakuSupersampleV2（'0.0'/'1.5'/'2.0'），
    // 旧 double 键（含关闭=0.0 的场景）只作迁移来源；两者在保存时同步写入。
    final v2Stored = _prefs.getString(SettingsKeys.danmakuSupersampleV2);
    final legacyStored = _prefs.getDouble(SettingsKeys.danmakuSupersample);
    _danmakuSupersample = _parseDanmakuSupersample(v2Stored) ??
        (legacyStored ?? _defaultDanmakuSupersample());
    debugPrint('[SettingsProvider] 弹幕超采样加载: v2=$v2Stored '
        'legacy=$legacyStored -> $_danmakuSupersample');
    logPlayerEvent(
      'Danmaku',
      '弹幕超采样加载: v2=$v2Stored legacy=$legacyStored -> '
          '$_danmakuSupersample${_danmakuSupersample == 0.0 ? '（关闭）' : 'x'}',
    );
    // 镜像文件（flush 落盘）比 NSUserDefaults 更能扛住“设置完立刻杀进程”：
    // 若镜像与偏好不一致，以镜像为准并修复偏好存储。
    unawaited(_reconcileSupersampleMirror());
    notifyListeners();
  }

  /// 弹幕超采样镜像文件：flush 落盘，强持久化（NSUserDefaults 在杀进程时
  /// 可能丢失最近写入，这正是“设置关闭后重启不生效、播放视频后才生效”的根因）。
  Future<File> _supersampleMirrorFile() async {
    final baseDir = await StorageService.getAppStorageDirectory();
    return File(p.join(baseDir.path, 'danmaku_supersample.txt'));
  }

  Future<void> _writeSupersampleMirror(double value) async {
    try {
      final file = await _supersampleMirrorFile();
      await file.writeAsString(_encodeDanmakuSupersample(value), flush: true);
    } catch (e) {
      debugPrint('[SettingsProvider] 弹幕超采样镜像写入失败: $e');
    }
  }

  Future<void> _reconcileSupersampleMirror() async {
    try {
      final file = await _supersampleMirrorFile();
      if (!await file.exists()) return;
      final fromFile = _parseDanmakuSupersample(await file.readAsString());
      if (fromFile == null || fromFile == _danmakuSupersample) {
        return;
      }
      _danmakuSupersample = fromFile;
      await _prefs.setString(
        SettingsKeys.danmakuSupersampleV2,
        _encodeDanmakuSupersample(fromFile),
      );
      await _prefs.setDouble(SettingsKeys.danmakuSupersample, fromFile);
      debugPrint('[SettingsProvider] 弹幕超采样以镜像文件为准: $fromFile');
      logPlayerEvent(
        'Danmaku',
        '弹幕超采样以镜像文件为准: ${fromFile == 0.0 ? '关闭(0.0)' : '${fromFile}x'}',
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[SettingsProvider] 弹幕超采样镜像读取失败: $e');
    }
  }

  /// 解析规范化字符串（'0.0'/'1.5'/'2.0'，容忍 '0'/'关闭' 等写法），非法返回 null。
  static double? _parseDanmakuSupersample(String? stored) {
    if (stored == null) return null;
    final trimmed = stored.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed == '关闭') return 0.0;
    final value = double.tryParse(trimmed);
    if (value == null || value < 0 || value > 4) return null;
    return value;
  }

  static String _encodeDanmakuSupersample(double value) => value.toString();

  // --- Setters ---

  /// 判断当前设备默认 DPR 是否低于 2.0
  static bool _defaultDprBelow2() {
    try {
      final dpr = WidgetsBinding
          .instance.platformDispatcher.views.first.devicePixelRatio;
      return dpr < 2.0;
    } catch (_) {
      return false;
    }
  }

  // 默认关闭弹幕超采样（用户选什么就保持什么；首次默认 0，不强制 iPad 1.5x）
  double _defaultDanmakuSupersample() {
    return 0.0;
  }

  /// Toggles the background blur effect.
  ///
  /// If `enable` is true, blurPower is set to a medium blur value.
  /// If `enable` is false, blurPower is set to 0.
  Future<void> setBlurEnabled(bool enable) async {
    _blurPower = enable ? 10.0 : 0.0; // 开启时使用中等模糊强度
    await _prefs.setDouble(_blurPowerKey, _blurPower);
    notifyListeners();
  }

  /// Sets a specific blur power value.
  Future<void> setBlurPower(double value) async {
    _blurPower = value;
    await _prefs.setDouble(_blurPowerKey, _blurPower);
    notifyListeners();
  }

  /// Sets the danmaku convert to simplified Chinese setting.
  Future<void> setDanmakuConvertToSimplified(bool enable) async {
    _danmakuConvertToSimplified = enable;
    await _prefs.setBool(
        SettingsKeys.danmakuConvertToSimplified, _danmakuConvertToSimplified);
    notifyListeners();
  }

  Future<void> setAutoMatchDanmakuFirstSearchResultOnHashFail(
      bool enable) async {
    _autoMatchDanmakuFirstSearchResultOnHashFail = enable;
    await _prefs.setBool(
      SettingsKeys.autoMatchDanmakuFirstSearchResultOnHashFail,
      _autoMatchDanmakuFirstSearchResultOnHashFail,
    );
    notifyListeners();
  }

  Future<void> setDanmakuAutoLoadStrategy(
      DanmakuAutoLoadStrategy strategy) async {
    if (strategy == DanmakuAutoLoadStrategy.manual) {
      await setSkipDanmakuMatching(true);
      return;
    }
    if (_danmakuAutoLoadStrategy == strategy) return;
    _danmakuAutoLoadStrategy = strategy;
    await _prefs.setString(
      SettingsKeys.danmakuAutoLoadStrategy,
      _danmakuAutoLoadStrategy.prefsValue,
    );
    notifyListeners();
  }

  Future<void> setSkipDanmakuMatching(bool skip) async {
    if (_skipDanmakuMatching == skip) return;
    _skipDanmakuMatching = skip;
    await _prefs.setBool(SettingsKeys.skipDanmakuMatching, skip);
    notifyListeners();
  }

  Future<void> setFastPlaybackStartup(bool enable) async {
    if (_fastPlaybackStartup == enable) return;
    _fastPlaybackStartup = enable;
    await _prefs.setBool(SettingsKeys.fastPlaybackStartup, enable);
    notifyListeners();
  }

  Future<void> setUseExternalPlayer(bool enable) async {
    _useExternalPlayer = enable;
    await _prefs.setBool(
      SettingsKeys.useExternalPlayer,
      _useExternalPlayer,
    );
    notifyListeners();
  }

  Future<void> setExternalPlayerPath(String path) async {
    _externalPlayerPath = path.trim();
    await _prefs.setString(
      SettingsKeys.externalPlayerPath,
      _externalPlayerPath,
    );
    notifyListeners();
  }

  Future<void> setExternalPlayerType(ExternalPlayerType type) async {
    if (_externalPlayerType == type) return;
    _externalPlayerType = type;
    await _prefs.setString(SettingsKeys.externalPlayerType, type.name);
    notifyListeners();
  }

  Future<void> setExternalPlayerDanmakuOverlay(bool enable) async {
    if (_externalPlayerDanmakuOverlay == enable) return;
    _externalPlayerDanmakuOverlay = enable;
    await _prefs.setBool(
      SettingsKeys.externalPlayerDanmakuOverlay,
      _externalPlayerDanmakuOverlay,
    );
    notifyListeners();
  }

  Future<void> setExternalPlayerAutoSwitchToDanmakuConsole(bool enable) async {
    if (_externalPlayerAutoSwitchToDanmakuConsole == enable) return;
    _externalPlayerAutoSwitchToDanmakuConsole = enable;

    await _prefs.setBool(
      SettingsKeys.externalPlayerAutoSwitchToDanmakuConsole,
      _externalPlayerAutoSwitchToDanmakuConsole,
    );

    notifyListeners();
  }

  Future<void> setExternalPlayerShrinkWindow(bool enable) async {
    if (_externalPlayerShrinkWindow == enable) return;
    _externalPlayerShrinkWindow = enable;
    await _prefs.setBool(
      SettingsKeys.externalPlayerShrinkWindow,
      _externalPlayerShrinkWindow,
    );
    notifyListeners();
  }

  Future<void> setExternalPlayerConsoleWindowMode(bool enable) async {
    if (_externalPlayerConsoleWindowMode == enable) return;
    _externalPlayerConsoleWindowMode = enable;
    await _prefs.setBool(
      SettingsKeys.externalPlayerConsoleWindowMode,
      _externalPlayerConsoleWindowMode,
    );
    notifyListeners();
  }

  Future<void> setGithubProxyUrl(String url) async {
    _githubProxyUrl = url.trim();
    await _prefs.setString(
      SettingsKeys.githubProxyUrl,
      _githubProxyUrl,
    );
    notifyListeners();
  }

  Future<void> setDanmakuSupersample(double value) async {
    final normalized = value < 0 ? 0.0 : (value > 4 ? 4.0 : value);
    _danmakuSupersample = normalized;
    debugPrint('[SettingsProvider] 弹幕超采样设置: $normalized');
    try {
      // 镜像文件先落盘（flush，强持久化）；偏好存储随后双写以兼容降级。
      // 顺序保证：只要用户看到设置成功，镜像文件一定已持久化。
      await _writeSupersampleMirror(normalized);
      await _prefs.setString(
        SettingsKeys.danmakuSupersampleV2,
        _encodeDanmakuSupersample(normalized),
      );
      await _prefs.setDouble(SettingsKeys.danmakuSupersample, normalized);
      debugPrint('[SettingsProvider] 弹幕超采样已写入: '
          'v2=${_encodeDanmakuSupersample(normalized)} legacy=$normalized');
      logPlayerEvent(
        'Danmaku',
        '弹幕超采样已设置并持久化: '
            '${normalized == 0.0 ? '关闭(0.0)' : '${normalized}x'}',
      );
    } catch (e) {
      debugPrint('[SettingsProvider] 弹幕超采样写入失败: $e');
      logPlayerEvent('Danmaku', '弹幕超采样写入失败: $e', level: 'ERROR');
    }
    notifyListeners();
  }
}
