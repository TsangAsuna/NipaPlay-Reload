import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nipaplay/models/dandanplay_remote_model.dart';
import 'package:nipaplay/services/dandanplay_remote_service.dart';
import 'package:nipaplay/services/web_remote_access_service.dart';

class DandanplayRemoteProvider extends ChangeNotifier {
  DandanplayRemoteProvider() {
    _service.addConnectionStateListener(_handleConnectionChange);
  }

  final DandanplayRemoteService _service = DandanplayRemoteService.instance;

  bool _isInitialized = false;
  bool _isLoading = false;
  String? _errorMessage;
  List<DandanplayRemoteEpisode> _episodes = [];
  List<DandanplayRemoteAnimeGroup> _animeGroups = [];

  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  bool get isConnected => _service.isConnected;
  String? get serverUrl => _service.serverUrl;
  bool get tokenRequired => _service.tokenRequired;
  String? get errorMessage => _errorMessage ?? _service.lastError;
  DateTime? get lastSyncedAt => _service.lastSyncedAt;
  List<DandanplayRemoteEpisode> get episodes => List.unmodifiable(_episodes);
  List<DandanplayRemoteAnimeGroup> get animeGroups =>
      List.unmodifiable(_animeGroups);

  String? buildStreamUrlForEpisode(DandanplayRemoteEpisode episode) {
    final hash = episode.hash.isNotEmpty ? episode.hash : null;
    final entryId = episode.entryId.isNotEmpty ? episode.entryId : null;
    return _service.buildEpisodeStreamUrl(hash: hash, entryId: entryId);
  }

  String? buildImageUrl(String hash) {
    if (hash.isEmpty) return null;
    return _service.buildImageUrl(hash);
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    _setLoading(true);
    try {
      if (kIsWeb) {
        await _syncFromRemote();
      } else {
        await _service.loadSavedSettings(backgroundRefresh: true);
      }
      _episodes = _service.cachedEpisodes;
      _rebuildGroups();
    } finally {
      _isInitialized = true;
      _setLoading(false);
    }
  }

  Future<void> _syncFromRemote() async {
    final base = await WebRemoteAccessService.resolveCandidateBaseUrl();
    if (base == null) return;

    try {
      final response = await http.get(Uri.parse('$base/api/settings/network/dandanplay'));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        // 这里需要DandanplayService暴露setter或者我们通过其他方式更新
        // DandanplayRemoteService没有暴露setter，但它是单例，且属性是getters
        // 我们可以通过connect方法来设置状态，或者如果已连接，就不做任何事
        // 注意：DandanplayService没有简单的“设置状态”方法
        // 我们假设如果远程已连接，我们在这里不需要做太多，因为数据获取是通过Service进行的
        // 而Service在Web端需要通过Remote API代理请求...
        // 等等，DandanplayRemoteService本身就是设计为连接远程弹弹play的
        // 在Web Remote模式下，它是连接"NipaPlay Host"连接的"弹弹play"
        // 所以我们不需要代理请求，只需要同步连接状态即可
        
        // 由于DandanplayRemoteService设计上是直连弹弹play API (或者通过NipaPlay服务端代理)
        // 现有的DandanplayRemoteService在Web端可能无法直接连接（跨域/HTTPS问题）
        // 最好是让它完全代理到NipaPlay Host的API
        
        // 暂时我们只同步连接状态，假设Service已经做了适当的抽象
        // 实际上 DandanplayRemoteService 需要修改以支持 Web Remote 代理模式
        // 但这里我们先只做配置同步
      }
    } catch (e) {
      print('DandanplayRemoteProvider: Failed to sync from remote: $e');
    }
  }

  Future<bool> connect(String baseUrl, {String? token}) async {
    _setLoading(true);
    try {
      bool success;
      if (kIsWeb) {
        final base = await WebRemoteAccessService.resolveCandidateBaseUrl();
        if (base == null) throw Exception('Remote server not found');
        
        final response = await http.post(
          Uri.parse('$base/api/settings/network/dandanplay'),
          body: json.encode({
            'serverUrl': baseUrl,
            'token': token,
          }),
        );
        
        if (response.statusCode == 200) {
          // 远程连接成功后，本地Service需要刷新数据
          // 但由于本地Service在Web端可能无法直接访问弹弹play，
          // 我们可能需要让本地Service也支持Web Remote代理
          // 目前暂且假设 connect 会成功
          success = true; 
          // 触发本地刷新（如果支持代理）
          // await _service.refreshLibrary(force: true); 
        } else {
          throw Exception('Remote connection failed: ${response.body}');
        }
      } else {
        success = await _service.connect(baseUrl, token: token);
      }
      
      _episodes = _service.cachedEpisodes;
      _rebuildGroups();
      _errorMessage = null;
      return success;
    } catch (e) {
      _errorMessage = e.toString();
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> disconnect() async {
    _setLoading(true);
    try {
      if (kIsWeb) {
        final base = await WebRemoteAccessService.resolveCandidateBaseUrl();
        if (base != null) {
          await http.post(
            Uri.parse('$base/api/settings/network/dandanplay'),
            body: json.encode({'disconnect': true}),
          );
        }
      } else {
        await _service.disconnect();
      }
      _episodes = [];
      _animeGroups = [];
      _errorMessage = null;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> refresh() async {
    if (!_service.isConnected) {
      throw Exception('尚未连接到弹弹play远程服务');
    }
    _setLoading(true);
    try {
      _episodes = await _service.refreshLibrary(force: true);
      _rebuildGroups();
      _errorMessage = null;
    } catch (e) {
      _errorMessage = e.toString();
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void _handleConnectionChange(bool connected) {
    if (connected) {
      _episodes = _service.cachedEpisodes;
      _rebuildGroups();
      _errorMessage = null;
    } else {
      _episodes = [];
      _animeGroups = [];
      notifyListeners();
    }
  }

  void _rebuildGroups() {
    final Map<int?, List<DandanplayRemoteEpisode>> grouped = {};
    for (final episode in _episodes) {
      grouped.putIfAbsent(episode.animeId, () => []).add(episode);
    }

    // 按 animeId 增量重建：内容没变的分组直接复用旧 group 对象——
    // 每次全量 refresh 都 new 一批新对象会让"排在后面的番剧"跟着
    // 重新加载（数据没变但对象换了，卡片层全部失效重建）。
    // 服务端重新匹配（PC 端更新番剧内容）会改变 animeId→番剧的对应
    // 关系：标题随新数据走，但按 animeId 持久化的封面 URL 还是旧匹配
    // 时代的 → 封面张冠李戴。检测到"已有分组内容变化"时，失效该
    // animeId 的持久化封面并递增 epoch，让视图层同步清内存缓存。
    final List<DandanplayRemoteAnimeGroup> groups = [];
    final Set<int?> changedAnimeIds = {};
    grouped.forEach((animeId, items) {
      items.sort((a, b) {
        final aTime =
            a.lastPlay ?? a.created ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime =
            b.lastPlay ?? b.created ?? DateTime.fromMillisecondsSinceEpoch(0);
        return aTime.compareTo(bTime);
      });
      final latest = items.last;
      final reused = _reuseGroupIfUnchanged(animeId, latest, items);
      if (reused == null && _groupById(animeId) != null) {
        changedAnimeIds.add(animeId);
      }
      groups.add(
        reused ??
            DandanplayRemoteAnimeGroup(
              animeId: animeId,
              title: latest.animeTitle,
              episodes: List.unmodifiable(items),
              latestPlayTime: latest.lastPlay ?? latest.created,
            ),
      );
    });

    groups.sort((a, b) {
      final aTime = a.latestPlayTime ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.latestPlayTime ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });

    // 集合结构变化（消失的 animeId）也失效：其持久化封面不再可靠。
    final previousIds = _animeGroups.map((g) => g.animeId).toSet();
    final currentIds = groups.map((g) => g.animeId).toSet();
    changedAnimeIds.addAll(previousIds.difference(currentIds));

    _animeGroups = groups;
    if (changedAnimeIds.isNotEmpty) {
      _dataInvalidationEpoch++;
      unawaited(_clearPersistedCovers(changedAnimeIds));
      debugPrint(
        '[弹弹play库] 检测到 ${changedAnimeIds.length} 个番剧条目内容变化，'
        '失效其持久化封面缓存 (epoch=$_dataInvalidationEpoch)',
      );
    }
    // 跨会话基线比对（首次调用时加载持久化指纹），关闭期间服务端
    // 重匹配的条目在这里被检出并失效。
    unawaited(_checkCrossSessionRematches());
    notifyListeners();
  }

  Future<void> _clearPersistedCovers(Set<int?> animeIds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final animeId in animeIds) {
        if (animeId == null) continue;
        await prefs.remove('media_library_image_url_$animeId');
      }
    } catch (e) {
      debugPrint('[弹弹play库] 清理持久化封面失败: $e');
    }
  }

  // ---- 跨会话重匹配基线 ----
  // bd29649 的失效机制只对照本会话内存里的旧分组：App 重启后
  // _animeGroups 为空，服务端在关机期间重新匹配完全检测不到 → 旧匹配
  // 时代的持久化封面继续命中。把每个 animeId 的标题+剧集指纹持久化，
  // 首轮 rebuild 与基准比对，变化即失效。
  static const String _fingerprintBaselineKey =
      'dandanplay_library_group_fingerprints_v1';

  Map<int, String>? _fingerprintBaseline;
  bool _fingerprintBaselineLoaded = false;

  static String _groupFingerprint(DandanplayRemoteAnimeGroup group) {
    final episodeIds = group.episodes.map((e) => e.episodeId).toList()..sort();
    return '${group.title}|${episodeIds.join(',')}';
  }

  Future<void> _loadFingerprintBaseline() async {
    if (_fingerprintBaselineLoaded) return;
    _fingerprintBaselineLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_fingerprintBaselineKey);
      if (raw == null || raw.isEmpty) {
        _fingerprintBaseline = {};
        return;
      }
      final decoded = json.decode(raw) as Map<String, dynamic>;
      _fingerprintBaseline = decoded.map(
        (k, v) => MapEntry(int.tryParse(k) ?? -1, v.toString()),
      );
    } catch (e) {
      debugPrint('[弹弹play库] 加载分组指纹基线失败: $e');
      _fingerprintBaseline = {};
    }
  }

  Future<void> _checkCrossSessionRematches() async {
    await _loadFingerprintBaseline();
    final baseline = _fingerprintBaseline;
    if (baseline == null || _animeGroups.isEmpty) return;

    final changed = <int?>{};
    final current = <int, String>{};
    for (final group in _animeGroups) {
      final id = group.animeId;
      if (id == null || id <= 0) continue; // 未匹配条目不持久化封面
      final fp = _groupFingerprint(group);
      current[id] = fp;
      final previous = baseline[id];
      if (previous != null && previous != fp) {
        changed.add(id);
      }
    }
    // 消失的 animeId：其持久化封面不再可靠。
    changed.addAll(baseline.keys.where((id) => !current.containsKey(id)));

    if (changed.isNotEmpty) {
      _dataInvalidationEpoch++;
      unawaited(_clearPersistedCovers(changed));
      debugPrint(
        '[弹弹play库] 跨会话检测到 ${changed.length} 个番剧重匹配/消失，'
        '失效持久化封面 (epoch=$_dataInvalidationEpoch)',
      );
    }
    // 写回本轮基线（含首次运行：空基线只记录，不判变化）。
    _fingerprintBaseline = current;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final encoded = json.encode(
          current.map((k, v) => MapEntry(k.toString(), v)),
        );
        await prefs.setString(_fingerprintBaselineKey, encoded);
      } catch (e) {
        debugPrint('[弹弹play库] 保存分组指纹基线失败: $e');
      }
    }());
  }

  /// 视图层据此清自己的内存缓存（见 dandanplay_remote_library_view）。
  int _dataInvalidationEpoch = 0;
  int get libraryCacheEpoch => _dataInvalidationEpoch;

  DandanplayRemoteAnimeGroup? _groupById(int? animeId) {
    for (final group in _animeGroups) {
      if (group.animeId == animeId) {
        return group;
      }
    }
    return null;
  }

  DandanplayRemoteAnimeGroup? _reuseGroupIfUnchanged(
    int? animeId,
    DandanplayRemoteEpisode latest,
    List<DandanplayRemoteEpisode> items,
  ) {
    for (final previous in _animeGroups) {
      if (previous.animeId != animeId) continue;
      if (previous.title != latest.animeTitle) return null;
      if (previous.episodes.length != items.length) return null;
      for (int i = 0; i < items.length; i++) {
        final a = previous.episodes[i];
        final b = items[i];
        if (a.episodeId != b.episodeId ||
            a.hash != b.hash ||
            a.lastPlay != b.lastPlay ||
            a.lastThumbnail != b.lastThumbnail ||
            a.animeTitle != b.animeTitle) {
          return null;
        }
      }
      return previous;
    }
    return null;
  }

  @override
  void dispose() {
    _service.removeConnectionStateListener(_handleConnectionChange);
    super.dispose();
  }
}
