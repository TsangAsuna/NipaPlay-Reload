import 'dart:async';
import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:kmbal_ionicons/kmbal_ionicons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/models/playable_item.dart';
import 'package:nipaplay/models/dandanplay_remote_model.dart';
import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/models/shared_remote_library.dart';
import 'package:nipaplay/providers/dandanplay_remote_provider.dart';
import 'package:nipaplay/providers/appearance_settings_provider.dart';
import 'package:nipaplay/utils/network_settings.dart';
import 'package:nipaplay/services/bangumi_service.dart';
import 'package:nipaplay/services/bangumi_api_service.dart';
import 'package:nipaplay/themes/nipaplay/widgets/cached_network_image_widget.dart';
import 'package:nipaplay/themes/nipaplay/widgets/horizontal_anime_card.dart';
import 'package:nipaplay/themes/nipaplay/widgets/blur_snackbar.dart';
import 'package:nipaplay/themes/nipaplay/widgets/themed_anime_detail.dart';
import 'package:nipaplay/themes/nipaplay/widgets/large_screen_focusable_action.dart';
import 'package:nipaplay/themes/nipaplay/widgets/large_screen_mode_scope.dart';
import 'package:nipaplay/themes/nipaplay/widgets/large_screen_page_scaffold.dart';
import 'package:nipaplay/app/app_display_surface.dart';
import 'package:nipaplay/app/app_display_surface_scope.dart';
import 'package:nipaplay/media_library/adaptive_media_library_primitives.dart';
import 'package:nipaplay/themes/cupertino/widgets/cupertino_dandanplay_connection_dialog.dart';
import 'package:nipaplay/themes/cupertino/widgets/cupertino_media_search_toolbar.dart';
import 'package:nipaplay/themes/nipaplay/widgets/blur_login_dialog.dart';

class DandanplayRemoteLibraryView extends StatefulWidget {
  const DandanplayRemoteLibraryView({
    super.key,
    this.onPlayEpisode,
  });

  final ValueChanged<WatchHistoryItem>? onPlayEpisode;

  @override
  State<DandanplayRemoteLibraryView> createState() =>
      _DandanplayRemoteLibraryViewState();
}

class _DandanplayRemoteLibraryViewState
    extends State<DandanplayRemoteLibraryView> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  final ScrollController _gridScrollController = ScrollController();
  Timer? _searchDebounce;
  final Map<int, String?> _coverCache = {}; // 复用本地缓存的番剧封面
  final Map<int, Future<String?>> _coverLoadingTasks = {};
  // 简介结果缓存：FutureBuilder 每次 build 新建 future 会让所有可见卡片
  // 闪回 waiting（父级任何 rebuild——退出播放器/历史更新/搜索框聚焦——
  // 都触发），这是"简介消失再出现"的直接机制。resolved 后直接读表，
  // future 只发一次，结果终身复用（详情网络层有内存 LRU，重复任务近乎零成本）。
  final Map<int, BangumiAnime?> _summaryCache = {};
  final Map<int, Future<BangumiAnime?>> _summaryTasks = {};
  // 未匹配条目（animeId 空/0）的 Bangumi 镜像识别缓存：按标题键控。
  // 弹弹play 识别不了的条目没有 animeId，无法按 ID 查询；改走镜像的
  // searchSubjects + getSubject，识别成功用镜像封面替换弹弹play 默认图。
  final Map<String, String?> _unmatchedCoverCache = {};
  final Map<String, String?> _unmatchedSummaryCache = {};
  final Set<String> _unmatchedTasks = {};
  // 数据失效纪元：服务端重新匹配后 provider 会失效变化的番剧并递增；
  // 视图层检测到 epoch 变化即清内存缓存，封面/简介按新数据重新解析。
  int _lastLibraryCacheEpoch = -1;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _gridScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DandanplayRemoteProvider>(
      builder: (context, provider, child) {
        // 数据失效纪元变化（服务端重新匹配等）→ 清内存封面/简介缓存，
        // 卡片按新数据重新解析；持久化层由 provider 侧负责失效。
        if (provider.libraryCacheEpoch != _lastLibraryCacheEpoch) {
          _lastLibraryCacheEpoch = provider.libraryCacheEpoch;
          _coverCache.clear();
          _coverLoadingTasks.clear();
          _summaryCache.clear();
          _summaryTasks.clear();
          _unmatchedCoverCache.clear();
          _unmatchedSummaryCache.clear();
          _unmatchedTasks.clear();
        }
        final isLargeScreen = NipaplayLargeScreenModeScope.isActiveOf(context);
        if (!provider.isInitialized && provider.isLoading) {
          return const Center(child: AdaptiveMediaActivityIndicator());
        }
        if (!provider.isConnected) {
          if (isLargeScreen) {
            return _buildLargeScreenDisconnectedState(provider);
          }
          return _buildDisconnectedState(provider);
        }

        final List<DandanplayRemoteAnimeGroup> groups =
            _filterGroups(provider.animeGroups);

        if (provider.animeGroups.isEmpty && !provider.isLoading) {
          if (isLargeScreen) {
            return _buildLargeScreenEmptyState(provider);
          }
          return _buildEmptyState(provider);
        }

        if (isLargeScreen) {
          return _buildLargeScreenRemoteLibrary(groups, provider);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToolbar(provider),
            if ((provider.errorMessage?.isNotEmpty ?? false) &&
                !provider.isLoading) ...[
              SizedBox(height: 12),
              _buildDandanErrorBanner(provider.errorMessage!),
            ],
            SizedBox(height: 12),
            Expanded(
              child: _buildMediaGrid(groups, provider),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLargeScreenRemoteLibrary(
    List<DandanplayRemoteAnimeGroup> groups,
    DandanplayRemoteProvider provider,
  ) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: NipaplayLargeScreenTextInput(
                controller: _searchController,
                hintText: '搜索弹弹play远程媒体',
                onChanged: _updateSearchQueryDebounced,
                onSubmitted: _commitSearchQuery,
                suffix: _searchQuery.isEmpty
                    ? null
                    : AdaptiveMediaIconButton(
                        tooltip: '清空搜索',
                        onPressed: _clearSearchQuery,
                        desktopIcon: Icons.close_rounded,
                        phoneIcon: cupertino.CupertinoIcons.clear,
                      ),
              ),
            ),
            const SizedBox(width: 14),
            NipaplayLargeScreenActionButton(
              icon: Icons.refresh_rounded,
              label: provider.isLoading ? '刷新中' : '刷新',
              onPressed: provider.isLoading
                  ? null
                  : () async {
                      try {
                        await provider.refresh();
                      } catch (e) {
                        if (mounted) {
                          BlurSnackBar.show(context, '刷新失败: $e');
                        }
                      }
                    },
            ),
            const SizedBox(width: 10),
            NipaplayLargeScreenActionButton(
              icon: Ionicons.link_outline,
              label: '连接',
              onPressed: () => _showConnectDialog(context, provider),
            ),
          ],
        ),
        if ((provider.errorMessage?.isNotEmpty ?? false) &&
            !provider.isLoading) ...[
          const SizedBox(height: 14),
          _buildLargeScreenDandanErrorBanner(provider.errorMessage!),
        ],
        const SizedBox(height: 18),
        Expanded(
          child: provider.isLoading && groups.isEmpty
              ? const Center(child: AdaptiveMediaActivityIndicator())
              : groups.isEmpty
                  ? const NipaplayLargeScreenEmptyState(
                      icon: Icons.search_off_rounded,
                      title: '没有匹配结果',
                      subtitle: '换个关键词再试试',
                    )
                  : GridView.builder(
                      controller: _gridScrollController,
                      padding: const EdgeInsets.only(bottom: 96),
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 244,
                        mainAxisExtent: 468,
                        crossAxisSpacing: 18,
                        mainAxisSpacing: 18,
                      ),
                      itemCount: groups.length,
                      itemBuilder: (context, index) {
                        return _buildLargeScreenAnimeCard(
                          groups[index],
                          provider,
                          autofocus: index == 0,
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildLargeScreenAnimeCard(
    DandanplayRemoteAnimeGroup group,
    DandanplayRemoteProvider provider, {
    required bool autofocus,
  }) {
    final coverUrl = _resolveCoverUrlForGroup(group, provider);
    final textColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : const Color(0xFF151820);

    return NipaplayLargeScreenFocusableAction(
      autofocus: autofocus,
      onActivate: () => _openAnimeDetail(group, provider),
      borderRadius: BorderRadius.circular(8),
      padding: EdgeInsets.zero,
      focusScale: 1,
      style: NipaplayLargeScreenFocusableStyle(
        idleBackgroundDark: Colors.white.withValues(alpha: 0.07),
        idleBackgroundLight: Colors.white.withValues(alpha: 0.82),
        focusStrokeWidth: 2.4,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImageWidget(
                    imageUrl: coverUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __) =>
                        _buildLargeScreenDandanFallbackPoster(textColor),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.74),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: _buildLargeScreenDandanBadge('弹弹play'),
                  ),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: _buildLargeScreenDandanBadge(
                      '${group.episodeCount} 集',
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _formatLargeScreenDandanSubtitle(group),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.52),
                      fontSize: 12,
                      height: 1.26,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLargeScreenDisconnectedState(
    DandanplayRemoteProvider provider,
  ) {
    return NipaplayLargeScreenEmptyState(
      icon: Ionicons.cloud_offline_outline,
      title: '尚未连接弹弹play远程服务',
      subtitle: '连接后可以在大屏模式中浏览家中弹弹play媒体库',
      action: NipaplayLargeScreenActionButton(
        icon: Ionicons.link_outline,
        label: '连接弹弹play',
        onPressed: () => _showConnectDialog(context, provider),
      ),
    );
  }

  Widget _buildLargeScreenEmptyState(DandanplayRemoteProvider provider) {
    return NipaplayLargeScreenEmptyState(
      icon: Ionicons.tv_outline,
      title: '远程媒体库为空',
      subtitle: '请确认弹弹play远程访问已同步媒体，稍候片刻后刷新列表',
      action: NipaplayLargeScreenActionButton(
        icon: Icons.refresh_rounded,
        label: '刷新',
        onPressed: provider.isLoading
            ? null
            : () async {
                try {
                  await provider.refresh();
                } catch (e) {
                  if (mounted) {
                    BlurSnackBar.show(context, '刷新失败: $e');
                  }
                }
              },
      ),
    );
  }

  Widget _buildLargeScreenDandanErrorBanner(String message) {
    return NipaplayLargeScreenPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const Icon(Ionicons.warning_outline,
              color: Colors.redAccent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLargeScreenDandanFallbackPoster(Color textColor) {
    return Container(
      color: Colors.white.withValues(alpha: 0.08),
      child: Center(
        child: Icon(
          Icons.movie_creation_outlined,
          color: textColor.withValues(alpha: 0.46),
          size: 52,
        ),
      ),
    );
  }

  Widget _buildLargeScreenDandanBadge(String label) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  String _formatLargeScreenDandanSubtitle(DandanplayRemoteAnimeGroup group) {
    final latest = group.latestPlayTime;
    if (latest == null) {
      return '共 ${group.episodeCount} 集';
    }
    return '共 ${group.episodeCount} 集 · 最近播放 ${latest.year}-${latest.month.toString().padLeft(2, '0')}-${latest.day.toString().padLeft(2, '0')}';
  }

  void _updateSearchQueryDebounced(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _searchQuery = value.trim();
      });
    });
  }

  void _commitSearchQuery(String value) {
    _searchDebounce?.cancel();
    setState(() {
      _searchQuery = value.trim();
    });
  }

  void _clearSearchQuery() {
    _searchDebounce?.cancel();
    setState(() {
      _searchQuery = '';
      _searchController.clear();
    });
  }

  Widget _buildToolbar(DandanplayRemoteProvider provider) {
    if (AppDisplaySurfaceScope.of(context) == AppDisplaySurface.phone) {
      return CupertinoMediaSearchToolbar(
        controller: _searchController,
        focusNode: _searchFocusNode,
        placeholder: '搜索番剧或剧集…',
        onChanged: _updateSearchQueryDebounced,
        onSubmitted: _commitSearchQuery,
        actions: [
          CupertinoMediaSearchToolbarAction(
            label: provider.isLoading ? '刷新中' : '刷新',
            icon: cupertino.CupertinoIcons.refresh,
            loading: provider.isLoading,
            onPressed: provider.isLoading
                ? null
                : () async {
                    try {
                      await provider.refresh();
                    } catch (error) {
                      if (mounted) BlurSnackBar.show(context, '刷新失败: $error');
                    }
                  },
          ),
          CupertinoMediaSearchToolbarAction(
            label: '连接',
            icon: cupertino.CupertinoIcons.link,
            onPressed: () => _showConnectDialog(context, provider),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        children: [
          _buildSearchField(),
        ],
      ),
    );
  }

  Widget _buildDandanErrorBanner(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.red.withValues(alpha: 0.1),
          border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Ionicons.warning_outline, color: Colors.redAccent, size: 18),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<DandanplayRemoteAnimeGroup> _filterGroups(
    List<DandanplayRemoteAnimeGroup> source,
  ) {
    if (_searchQuery.isEmpty) {
      return List.unmodifiable(source);
    }
    return source.where((group) {
      final titleMatch = _matchesQuery(group.title, _searchQuery);
      final episodeMatch = group.episodes.any(
        (episode) => _matchesQuery(episode.episodeTitle, _searchQuery),
      );
      return titleMatch || episodeMatch;
    }).toList();
  }

  bool _matchesQuery(String source, String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return true;

    final lowerSource = source.toLowerCase();
    final lowerQuery = trimmed.toLowerCase();
    if (lowerSource.contains(lowerQuery)) return true;

    final normalizedSource = _normalizeSearchText(lowerSource);
    final normalizedQuery = _normalizeSearchText(lowerQuery);
    if (normalizedSource.contains(normalizedQuery)) return true;

    final tokens = trimmed
        .split(RegExp(r'\s+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (tokens.length <= 1) return false;

    final tokenMatch = tokens.every(
      (token) => _normalizeSearchText(lowerSource)
          .contains(_normalizeSearchText(token.toLowerCase())),
    );
    return tokenMatch;
  }

  String _normalizeSearchText(String input) {
    return input.replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  }

  Widget _buildMediaGrid(
    List<DandanplayRemoteAnimeGroup> groups,
    DandanplayRemoteProvider provider,
  ) {
    final showSummary =
        context.watch<AppearanceSettingsProvider>().showAnimeCardSummary;
    return RepaintBoundary(
      child: AdaptiveMediaScrollbar(
        controller: _gridScrollController,
        child: GridView.builder(
          controller: _gridScrollController,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: showSummary
                ? HorizontalAnimeCard.detailedGridMaxCrossAxisExtent
                : HorizontalAnimeCard.compactGridMaxCrossAxisExtent,
            mainAxisExtent: showSummary
                ? HorizontalAnimeCard.detailedCardHeight
                : HorizontalAnimeCard.compactCardHeight,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final group = groups[index];
            return _buildAnimeCard(group, provider);
          },
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return AdaptiveMediaSearchField(
      controller: _searchController,
      focusNode: _searchFocusNode,
      placeholder: '搜索番剧或剧集…',
      onChanged: _updateSearchQueryDebounced,
      onSubmitted: _commitSearchQuery,
      onClear: () {
        _searchDebounce?.cancel();
        if (mounted) setState(() => _searchQuery = '');
      },
    );
  }

  Widget _buildAnimeCard(
    DandanplayRemoteAnimeGroup group,
    DandanplayRemoteProvider provider,
  ) {
    final coverUrl = _resolveCoverUrlForGroup(group, provider);

    if (group.animeId != null && group.animeId! > 0) {
      final animeId = group.animeId!;
      // 缓存命中（含"拉过但为空"）直接渲染；在途任务也不新建。
      // 失败不写缓存（保持与原 FutureBuilder 一致的重试语义）。
      if (_summaryCache.containsKey(animeId)) {
        return _buildAnimeCardBody(
          group,
          provider,
          coverUrl,
          _summaryCache[animeId],
        );
      }
      if (_summaryTasks.containsKey(animeId)) {
        return _buildAnimeCardBody(group, provider, coverUrl, null);
      }
      final task = BangumiService.instance
          .getAnimeDetails(animeId)
          .then((anime) {
            _summaryCache[animeId] = anime;
            if (mounted) {
              setState(() {});
            }
            return anime;
          })
          .catchError((Object error) {
            debugPrint('获取番剧简介失败($animeId): $error');
            return null;
          });
      _summaryTasks[animeId] = task;
      unawaited(
        task.whenComplete(() {
          _summaryTasks.remove(animeId);
        }),
      );
      return _buildAnimeCardBody(group, provider, coverUrl, null);
    }

    // animeId 空或 0：弹弹play 服务器未匹配的条目。用 Bangumi 镜像按
    // 标题搜索识别（searchSubjects/getSubject 走 NetworkSettings 的
    // 自定义 Bangumi 服务器），识别成功则用镜像封面替换弹弹play 默认图，
    // 并补一条简介。
    final unmatchedKey = group.title.trim().toLowerCase();
    if (unmatchedKey.isEmpty) {
      return _buildAnimeCardBody(group, provider, coverUrl, null);
    }
    final cachedCover = _unmatchedCoverCache[unmatchedKey];
    final cachedSummary = _unmatchedSummaryCache[unmatchedKey];
    if (!_unmatchedTasks.contains(unmatchedKey)) {
      _unmatchedTasks.add(unmatchedKey);
      unawaited(
        _identifyUnmatchedGroup(group.title.trim(), unmatchedKey),
      );
    }
    return HorizontalAnimeCard(
      key: ValueKey('dandan_${group.animeId ?? group.title}'),
      title: group.title,
      imageUrl: (cachedCover?.isNotEmpty ?? false) ? cachedCover! : coverUrl,
      source: '弹弹play',
      rating: null,
      onTap: () => _openAnimeDetail(group, provider),
      summary: cachedSummary,
    );
  }

  /// 标题归一化：小写、去空白/标点/符号及 OVA/SP 等集数装饰词，
  /// 让"xxx OVA"能与正传条目"xxx 第二季"比较基础标题。
  static final RegExp _titleNoiseRegExp = RegExp(r'[\s\p{P}\p{S}]', unicode: true);

  static String _normalizeTitleForMatch(String input) {
    return input
        .toLowerCase()
        .replaceAll(_titleNoiseRegExp, '')
        .replaceAll(RegExp(r'ova|oad|sp|特别篇|总集篇|完结篇'), '');
  }

  /// 关键词与候选标题的匹配分：1=归一化后完全一致，0.9=包含关系，
  /// 其余用字符二元组 Dice 系数，0=完全无关。
  static double _titleMatchScore(String keyword, String candidate) {
    final a = _normalizeTitleForMatch(keyword);
    final b = _normalizeTitleForMatch(candidate);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (a.contains(b) || b.contains(a)) return 0.9;
    if (a.length < 2 || b.length < 2) return 0;
    final Set<String> bigramsA = {
      for (var i = 0; i < a.length - 1; i++) a.substring(i, i + 2),
    };
    final Set<String> bigramsB = {
      for (var i = 0; i < b.length - 1; i++) b.substring(i, i + 2),
    };
    var overlap = 0;
    for (final g in bigramsA) {
      if (bigramsB.contains(g)) overlap++;
    }
    return (2 * overlap) / (bigramsA.length + bigramsB.length);
  }

  /// Bangumi 镜像识别未匹配条目：按标题搜索 → 相似度评分取最优命中 →
  /// 拉详情拿简介与封面。低于阈值的命中宁可不换封面——"搜索第一条
  /// 直接用"会把无关番剧的封面张冠李戴（如美好世界 OVA 配上其它条目）。
  /// 封面按当前 Bangumi 配置改写到镜像主机，未配置时保留源站 URL。
  Future<void> _identifyUnmatchedGroup(
    String keyword,
    String cacheKey,
  ) async {
    try {
      final search = await BangumiApiService.searchSubjects(keyword, limit: 5);
      final List<dynamic> subjects =
          (search['data'] as List<dynamic>?) ?? const <dynamic>[];
      int bestSubjectId = 0;
      double bestScore = 0;
      String bestName = '';
      for (final s in subjects) {
        if (s is! Map<String, dynamic>) continue;
        final id = (s['id'] as num?)?.toInt() ?? 0;
        if (id <= 0) continue;
        final nameCn = s['name_cn']?.toString() ?? '';
        final name = s['name']?.toString() ?? '';
        var score = _titleMatchScore(keyword, nameCn);
        final scoreName = _titleMatchScore(keyword, name);
        if (scoreName > score) score = scoreName;
        if (score > bestScore) {
          bestScore = score;
          bestSubjectId = id;
          bestName = nameCn.isNotEmpty ? nameCn : name;
        }
      }
      if (bestSubjectId <= 0 || bestScore < 0.5) {
        _unmatchedCoverCache[cacheKey] = null;
        _unmatchedSummaryCache[cacheKey] = null;
        debugPrint(
          '[弹弹play库] 未匹配条目 "$keyword" 无相似命中'
          '(最高分 ${bestScore.toStringAsFixed(2)})，保留弹弹play默认封面',
        );
        if (mounted) setState(() {});
        return;
      }
      final detail = await BangumiApiService.getSubject(bestSubjectId);
      final images = detail['images'];
      final String rawCover = (images is Map<String, dynamic>
              ? (images['large'] ??
                  images['common'] ??
                  images['medium'] ??
                  '')
              : '')
          .toString();
      final cover = await NetworkSettings.rewriteBangumiImageUrl(rawCover);
      final summaryText = (detail['summary'] ?? '').toString();
      _unmatchedCoverCache[cacheKey] = cover;
      _unmatchedSummaryCache[cacheKey] =
          summaryText.isEmpty ? null : summaryText;
      debugPrint(
        '[弹弹play库] 未匹配条目 "$keyword" 识别为 subject $bestSubjectId'
        '《$bestName》(相似度 ${bestScore.toStringAsFixed(2)})，'
        '封面: $cover',
      );
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('[弹弹play库] 未匹配条目 "$keyword" Bangumi 识别失败: $e');
    } finally {
      _unmatchedTasks.remove(cacheKey);
    }
  }

  Widget _buildAnimeCardBody(
    DandanplayRemoteAnimeGroup group,
    DandanplayRemoteProvider provider,
    String coverUrl,
    BangumiAnime? summary,
  ) {
    return HorizontalAnimeCard(
      key: ValueKey('dandan_${group.animeId ?? group.title}'),
      title: group.title,
      imageUrl: coverUrl,
      source: '弹弹play',
      rating: null,
      onTap: () => _openAnimeDetail(group, provider),
      summary: summary?.summary,
    );
  }

  String _resolveCoverUrlForGroup(
    DandanplayRemoteAnimeGroup group,
    DandanplayRemoteProvider provider,
  ) {
    final fallback = provider.buildImageUrl(group.primaryHash ?? '') ?? '';
    final animeId = group.animeId;
    if (animeId == null) {
      return fallback;
    }

    final cached = _coverCache[animeId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    _coverCache.putIfAbsent(animeId, () => fallback);
    _ensureCoverLoad(animeId, title: group.title);
    return _coverCache[animeId] ?? fallback;
  }

  void _ensureCoverLoad(int animeId, {String? title}) {
    if (_coverLoadingTasks.containsKey(animeId)) {
      return;
    }

    final future = _loadCoverFromSources(animeId, title: title).then((url) {
      if ((url?.isNotEmpty ?? false) && mounted) {
        setState(() {
          _coverCache[animeId] = url;
        });
      } else if (url != null && url.isNotEmpty) {
        _coverCache[animeId] = url;
      }
      return url;
    }).catchError((error) {
      debugPrint('获取番剧封面失败($animeId): $error');
      return null;
    });

    _coverLoadingTasks[animeId] = future;
    future.whenComplete(() {
      _coverLoadingTasks.remove(animeId);
    });
  }

  Future<String?> _getOrFetchCoverUrl(
    int animeId,
    DandanplayRemoteProvider provider,
    DandanplayRemoteAnimeGroup group,
  ) async {
    final cached = _coverCache[animeId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final pending = _coverLoadingTasks[animeId];
    if (pending != null) {
      final result = await pending;
      if (result != null && result.isNotEmpty) {
        return result;
      }
    } else {
      _ensureCoverLoad(animeId, title: group.title);
      final newly = await _coverLoadingTasks[animeId];
      if (newly != null && newly.isNotEmpty) {
        return newly;
      }
    }

    final fallback = provider.buildImageUrl(group.primaryHash ?? '');
    if (fallback != null && fallback.isNotEmpty) {
      if (mounted) {
        setState(() {
          _coverCache[animeId] = fallback;
        });
      } else {
        _coverCache[animeId] = fallback;
      }
    }
    return fallback;
  }

  Future<String?> _loadCoverFromSources(int animeId, {String? title}) async {
    // animeId<=0（未匹配/自有条目）没有 Bangumi 元数据，跳过详情查询，
    // 直接走弹弹play 图片 hash 回退（自定义镜像对 ID 0 报参数错误）。
    if (animeId <= 0) {
      return null;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'media_library_image_url_$animeId';
      final persisted = prefs.getString(key);
      if (persisted != null && persisted.isNotEmpty) {
        // 旧版本持久化的可能是 lain.bgm.tv 源站 URL；配置镜像后按当前
        // 配置改写（已指向镜像的 URL 原样通过）。
        final rewritten = await NetworkSettings.rewriteBangumiImageUrl(persisted);
        debugPrint(
          '[弹弹play封面] "$title" ($animeId) 命中持久化 URL: $persisted'
          '${rewritten != persisted ? " → 镜像改写: $rewritten" : ""}',
        );
        return rewritten;
      }

      final detail = await BangumiService.instance.getAnimeDetails(animeId);
      final url = detail.imageUrl;
      if (url.isNotEmpty) {
        await prefs.setString(key, url);
        debugPrint(
          '[弹弹play封面] "$title" ($animeId) 取得 Bangumi 封面: $url',
        );
        return url;
      }
      debugPrint(
        '[弹弹play封面] "$title" ($animeId) Bangumi 详情无封面图，用弹弹play 图片回退',
      );
    } catch (e) {
      debugPrint('加载番剧封面异常($animeId): $e');
    }
    return null;
  }

  SharedRemoteAnimeSummary _buildSharedSummary(
    DandanplayRemoteAnimeGroup group,
    DandanplayRemoteProvider provider, {
    String? coverUrl,
  }) {
    // 未匹配条目（animeId 空/0）同样可打开详情与播放：Bangumi ID 只影响
    // 弹幕/收藏绑定，播放走 hash 流。镜像识别的封面在这里兜底注入。
    final unmatchedCover = (group.animeId == null || group.animeId! <= 0)
        ? _unmatchedCoverCache[group.title.trim().toLowerCase()]
        : null;
    final resolvedCover = coverUrl ??
        (group.animeId != null && group.animeId! > 0
            ? _coverCache[group.animeId!]
            : null) ??
        (unmatchedCover?.isNotEmpty == true ? unmatchedCover : null) ??
        provider.buildImageUrl(group.primaryHash ?? '');

    return SharedRemoteAnimeSummary(
      animeId: group.animeId ?? 0,
      name: group.title,
      nameCn: group.title,
      summary: null,
      imageUrl: resolvedCover,
      lastWatchTime: group.latestPlayTime ?? DateTime.now(),
      episodeCount: group.episodeCount,
      hasMissingFiles: false,
    );
  }

  SharedRemoteEpisode? _mapToSharedEpisode(
    DandanplayRemoteEpisode episode,
    DandanplayRemoteProvider provider,
  ) {
    final streamUrl = provider.buildStreamUrlForEpisode(episode);
    if (streamUrl == null || streamUrl.isEmpty) {
      return null;
    }

    final resolvedEpisodeId = episode.episodeId ??
        (episode.entryId.isNotEmpty
            ? episode.entryId.hashCode
            : (episode.hash.isNotEmpty
                ? episode.hash.hashCode
                : episode.name.hashCode));

    final shareKey = episode.entryId.isNotEmpty
        ? episode.entryId
        : (episode.hash.isNotEmpty ? episode.hash : episode.path);

    return SharedRemoteEpisode(
      shareId: 'dandan_$shareKey',
      title:
          episode.episodeTitle.isNotEmpty ? episode.episodeTitle : episode.name,
      fileName: episode.name,
      streamPath: streamUrl,
      fileExists: true,
      animeId: episode.animeId,
      episodeId: resolvedEpisodeId,
      duration: episode.duration,
      lastPosition: 0,
      progress: 0,
      fileSize: episode.size,
      lastWatchTime: episode.lastPlay ?? episode.created,
      videoHash: episode.hash.isNotEmpty ? episode.hash : null,
    );
  }

  PlayableItem _buildPlayableFromShared({
    required SharedRemoteAnimeSummary summary,
    required SharedRemoteEpisode episode,
  }) {
    final watchItem = _buildWatchHistoryItem(
      summary: summary,
      episode: episode,
    );
    return PlayableItem(
      videoPath: watchItem.filePath,
      title: watchItem.animeName,
      subtitle: watchItem.episodeTitle,
      animeId: watchItem.animeId,
      episodeId: watchItem.episodeId,
      historyItem: watchItem,
      actualPlayUrl: watchItem.filePath,
    );
  }

  WatchHistoryItem _buildWatchHistoryItem({
    required SharedRemoteAnimeSummary summary,
    required SharedRemoteEpisode episode,
  }) {
    final duration = episode.duration ?? 0;
    final lastPosition = episode.lastPosition ?? 0;
    double progress = episode.progress ?? 0;
    if (progress <= 0 && duration > 0 && lastPosition > 0) {
      progress = (lastPosition / duration).clamp(0.0, 1.0);
    }

    return WatchHistoryItem(
      filePath: episode.streamPath,
      animeName:
          summary.nameCn?.isNotEmpty == true ? summary.nameCn! : summary.name,
      episodeTitle: episode.title,
      episodeId: episode.episodeId,
      animeId: summary.animeId,
      watchProgress: progress,
      lastPosition: lastPosition,
      duration: duration,
      lastWatchTime: episode.lastWatchTime ?? summary.lastWatchTime,
      thumbnailPath: summary.imageUrl,
      isFromScan: false,
      videoHash: episode.videoHash,
    );
  }

  Future<void> _openAnimeDetail(
    DandanplayRemoteAnimeGroup group,
    DandanplayRemoteProvider provider,
  ) async {
    // 未匹配条目（animeId 空/0，弹弹play 识别不了的视频）不再硬性拦截：
    // 详情页元数据走 Bangumi 镜像识别（见 _identifyUnmatchedGroup），
    // 剧集列表来自远程库本体的 shared loader，播放走 hash 流，与
    // animeId 解耦。缺 Bangumi ID 只影响弹幕/收藏绑定，不影响播放。
    final animeId = group.animeId;
    if (animeId == null || animeId <= 0) {
      if (_unmatchedCoverCache.isEmpty &&
          _unmatchedSummaryCache.isEmpty &&
          mounted) {
        // 首次进入先触发一次识别，让详情/卡片都能拿到镜像元数据。
        final unmatchedKey = group.title.trim().toLowerCase();
        if (unmatchedKey.isNotEmpty && !_unmatchedTasks.contains(unmatchedKey)) {
          _unmatchedTasks.add(unmatchedKey);
          unawaited(_identifyUnmatchedGroup(group.title.trim(), unmatchedKey));
        }
      }
    }

    final resolvedAnimeId =
        (animeId != null && animeId > 0) ? animeId : 0;
    final coverUrl =
        await _getOrFetchCoverUrl(resolvedAnimeId, provider, group);
    if (!mounted) return;

    final summary = _buildSharedSummary(
      group,
      provider,
      coverUrl: coverUrl,
    );
    Future<List<SharedRemoteEpisode>> episodeLoader() async {
      final episodes = group.episodes.reversed
          .map((episode) => _mapToSharedEpisode(episode, provider))
          .whereType<SharedRemoteEpisode>()
          .toList();
      if (episodes.isEmpty) {
        throw Exception('该番剧暂无可播放的剧集');
      }
      return episodes;
    }

    final sourceLabel = provider.serverUrl ?? '弹弹play';

    try {
      final result = await ThemedAnimeDetail.show(
        context,
        summary.animeId,
        sharedSummary: summary,
        sharedEpisodeLoader: episodeLoader,
        sharedEpisodeBuilder: (episode) => _buildPlayableFromShared(
          summary: summary,
          episode: episode,
        ),
        sharedSourceLabel: sourceLabel,
      );

      if (result != null) {
        widget.onPlayEpisode?.call(result);
      }
    } catch (e) {
      if (mounted) {
        BlurSnackBar.show(context, '打开详情失败：$e');
      }
    }
  }

  Widget _buildDisconnectedState(DandanplayRemoteProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final textColor = colorScheme.onSurface;
    final subTextColor = textColor.withOpacity(0.7);
    final mutedTextColor = textColor.withOpacity(0.5);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Ionicons.cloud_offline_outline,
                color: mutedTextColor, size: 48),
            SizedBox(height: 16),
            Text(
              '尚未连接弹弹play远程服务',
              style: TextStyle(color: textColor, fontSize: 18),
            ),
            SizedBox(height: 8),
            Text(
              '请先在下方完成远程访问配置，即可浏览家中弹弹play媒体库。',
              textAlign: TextAlign.center,
              style: TextStyle(color: subTextColor, fontSize: 14),
            ),
            SizedBox(height: 20),
            AdaptiveMediaActionButton(
              onPressed: () => _showConnectDialog(context, provider),
              desktopIcon: Ionicons.link_outline,
              phoneIcon: cupertino.CupertinoIcons.link,
              label: '连接弹弹play',
              emphasis: AdaptiveMediaActionEmphasis.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(DandanplayRemoteProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final textColor = colorScheme.onSurface;
    final subTextColor = textColor.withOpacity(0.7);
    final mutedTextColor = textColor.withOpacity(0.5);
    final title = '远程媒体库为空';
    final subtitle = '请确认弹弹play 远程访问已同步媒体，稍候片刻即可自动更新列表。';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Ionicons.tv_outline,
              color: mutedTextColor,
              size: 48,
            ),
            SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(color: textColor, fontSize: 18),
            ),
            SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: subTextColor, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showConnectDialog(
    BuildContext context,
    DandanplayRemoteProvider provider,
  ) async {
    if (AppDisplaySurfaceScope.of(context) == AppDisplaySurface.phone) {
      final config = await showCupertinoDandanplayConnectionDialog(
        context: context,
        provider: provider,
      );
      if (config == null) return;
      await _connectProvider(provider, config.baseUrl, config.apiToken);
      return;
    }

    final connected = await BlurLoginDialog.show(
      context,
      title: '连接弹弹play远程服务',
      loginButtonText: '连接',
      fields: [
        LoginField(
          key: 'base',
          label: '服务地址',
          hint: '例如 http://192.168.1.10:23333',
          initialValue: provider.serverUrl ?? '',
        ),
        LoginField(
          key: 'token',
          label: provider.tokenRequired ? 'API密钥 (必填)' : 'API密钥 (可选)',
          isPassword: true,
          required: provider.tokenRequired,
        ),
      ],
      onLogin: (values) async {
        final baseUrl = values['base']?.trim() ?? '';
        if (baseUrl.isEmpty) {
          return const LoginResult(success: false, message: '请输入远程服务地址');
        }
        try {
          final token = values['token'];
          await provider.connect(
            baseUrl,
            token: token?.isNotEmpty == true ? token : null,
          );
          return const LoginResult(success: true, message: '连接成功');
        } catch (error) {
          return LoginResult(success: false, message: '连接失败: $error');
        }
      },
    );
    if (connected == true && mounted) {
      BlurSnackBar.show(context, '弹弹play远程服务已连接');
    }
  }

  Future<void> _connectProvider(
    DandanplayRemoteProvider provider,
    String baseUrl,
    String? token,
  ) async {
    final url = baseUrl.trim();
    if (url.isEmpty) {
      BlurSnackBar.show(context, '请输入远程服务地址');
      return;
    }

    try {
      await provider.connect(url,
          token: token?.isNotEmpty == true ? token : null);
      if (!mounted) return;
      BlurSnackBar.show(context, '弹弹play远程服务已连接');
    } catch (e) {
      if (!mounted) return;
      BlurSnackBar.show(context, '连接失败: $e');
    }
  }
}
