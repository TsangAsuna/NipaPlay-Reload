import 'package:shared_preferences/shared_preferences.dart';

/// 网络设置管理类
class NetworkSettings {
  static const String _dandanplayServerKey = 'dandanplay_server_url';
  static const String _bangumiServerKey = 'bangumi_server_url';
  static const String _imageProxyServerKey = 'image_proxy_server_url';

  /// 图片反代地址（如 https://imgproxy.example.com/）。
  /// 直连不了图片 CDN（bgm.tv 图床等）时可强制走该前缀。
  static const String _imageProxyDefault = '';

  // 官方发行版统一通过 NipaPlay 网关访问弹弹play。旧地址仅用于迁移
  // 已安装版本保存的偏好，客户端不再持有弹弹play AppSecret。
  static const String primaryServer =
      'https://nipaplay.aimes-soft.com/dandanplay';
  static const String _legacyOfficialServer = 'https://api.dandanplay.net';
  static const String _legacyBackupServer = 'http://139.224.252.88:16001';

  // 默认服务器（主服务器）
  static const String defaultServer = primaryServer;

  // Bangumi 服务器常量
  static const String bangumiDefaultServer = 'https://api.bgm.tv';

  /// Recognize the provider by origin, never just by its compatible API path.
  static bool isDandanplayServiceUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'api.dandanplay.net' || host.endsWith('.dandanplay.net')) {
      return true;
    }
    final gateway = Uri.parse(primaryServer);
    if (host == gateway.host &&
        (uri.path == gateway.path || uri.path.startsWith('${gateway.path}/'))) {
      return uri.path != '${gateway.path}/healthz';
    }
    return host == '139.224.252.88' && uri.port == 16001;
  }

  /// 获取当前弹弹play服务器地址
  static Future<String> getDandanplayServer() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_dandanplayServerKey) ?? defaultServer;
    final normalized = _normalizeServerUrl(stored);
    if (normalized == _legacyOfficialServer ||
        normalized == _legacyBackupServer) {
      return primaryServer;
    }
    return normalized;
  }

  /// 设置弹弹play服务器地址
  static Future<void> setDandanplayServer(String serverUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeServerUrl(serverUrl);
    await prefs.setString(_dandanplayServerKey, normalized);
    print('[网络设置] 弹弹play服务器已切换到: $normalized');
  }

  /// 获取当前 Bangumi 服务器地址
  static Future<String> getBangumiServer() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_bangumiServerKey) ?? bangumiDefaultServer;
    return _normalizeServerUrl(stored);
  }

  /// 设置 Bangumi 服务器地址
  static Future<void> setBangumiServer(String serverUrl) async {
    final previous = await getBangumiServer();
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeServerUrl(serverUrl);
    await prefs.setString(_bangumiServerKey, normalized);
    _cachedBangumiServer = normalized;
    print('[网络设置] Bangumi服务器已切换到: $normalized');
    if (normalized != previous) {
      await clearBangumiImageCaches();
    }
  }

  /// 清除持久化的番剧图片/详情缓存。
  /// 换 Bangumi API（或反代）后，旧缓存里保存的图片地址仍指向旧域名，
  /// 不清掉就会一直加载失败——这是"改了服务器图片仍不加载"的根因。
  static Future<void> clearBangumiImageCaches() async {
    final prefs = await SharedPreferences.getInstance();
    final stale = prefs.getKeys()
        .where((k) =>
            k.startsWith('media_library_image_url_') ||
            k.startsWith('bangumi_detail_'))
        .toList();
    for (final key in stale) {
      await prefs.remove(key);
    }
    print('[网络设置] 已清除 ${stale.length} 条番剧图片缓存');
  }

  // ---- 图片反代 ----

  static String _cachedImageProxyPrefix = _imageProxyDefault;
  static String _cachedBangumiServer = bangumiDefaultServer;

  /// 启动时调用一次，让同步的 build 代码也能应用反代前缀
  static Future<void> preloadImageProxyServer() async {
    final prefs = await SharedPreferences.getInstance();
    _cachedImageProxyPrefix = _normalizeProxyPrefix(
        prefs.getString(_imageProxyServerKey) ?? _imageProxyDefault);
    _cachedBangumiServer = _normalizeServerUrl(
        prefs.getString(_bangumiServerKey) ?? bangumiDefaultServer);
  }

  static Future<String> getImageProxyServer() async {
    final prefs = await SharedPreferences.getInstance();
    _cachedImageProxyPrefix = _normalizeProxyPrefix(
        prefs.getString(_imageProxyServerKey) ?? _imageProxyDefault);
    return _cachedImageProxyPrefix;
  }

  static Future<void> setImageProxyServer(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = url.trim().isEmpty ? '' : _normalizeProxyPrefix(url);
    if (normalized.isEmpty) {
      await prefs.remove(_imageProxyServerKey);
    } else {
      await prefs.setString(_imageProxyServerKey, normalized);
    }
    _cachedImageProxyPrefix = normalized;
    print('[网络设置] 图片反代已切换到: '
        '${normalized.isEmpty ? '(已关闭)' : normalized}');
  }

  /// 给图片 URL 加反代前缀。
  /// 两种反代风格都支持：
  /// - 根路径前缀（如 https://imgproxy.example.com/）：前缀 + 完整 URL（imgproxy/GH-proxy 类）。
  /// - 带子路径前缀（如 https://proxy.example.com/img/）：替换主机，保留源 path+query（bgm-proxy / bangumi-proxy-workers 类）。
  /// 同步返回，供 build 里的 Image.network 直接使用。
  static String applyImageProxy(String url) {
    final prefix = _cachedImageProxyPrefix;
    if (prefix.isEmpty || url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return url;
    if (url.startsWith(prefix)) return url;
    final prefixUri = Uri.tryParse(prefix);
    final srcUri = Uri.tryParse(url);
    if (srcUri != null) {
      // 官方域名的残留 URL（旧版本直连缓存） 用当前 bangumi server 替换 host，走反代
      if (srcUri.host == 'api.bgm.tv' || srcUri.host == 'next.bgm.tv') {
        final server = _cachedBangumiServer;
        if (server.isNotEmpty && server != bangumiDefaultServer) {
          final srvBase = server.endsWith('/')
              ? server.substring(0, server.length - 1)
              : server;
          return '$srvBase${srcUri.path}${srcUri.hasQuery ? '?${srcUri.query}' : ''}';
        }
      }
      // 已是反代域名自身的 URL（如 API 反代返回的图片地址）不再套前缀，避免嵌套
      if (prefixUri != null && prefixUri.host == srcUri.host) {
        return url;
      }
    }
    if (prefixUri != null && srcUri != null &&
        prefixUri.path.isNotEmpty && prefixUri.path != '/') {
      // 带子路径前缀（如 .../img）：仅 lain 图床做主机替换保留 path；
      // 其它任意图床（tmdb 等）用「前缀 + 完整 URL」，反代 worker 透传
      if (srcUri.host.endsWith('lain.bgm.tv')) {
        final base =
            prefix.endsWith('/') ? prefix.substring(0, prefix.length - 1) : prefix;
        return '$base${srcUri.path}${srcUri.hasQuery ? '?${srcUri.query}' : ''}';
      }
    }
    return '$prefix$url';
  }

  static String _normalizeProxyPrefix(String url) {
    var value = url.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    if (!value.endsWith('/')) value = '$value/';
    return value;
  }

  /// 检查当前 Bangumi 服务器是否为自定义服务器
  static bool isCustomBangumiServer(String serverUrl) {
    if (serverUrl.trim().isEmpty) {
      return false;
    }
    final normalized = _normalizeServerUrl(serverUrl);
    return normalized != bangumiDefaultServer;
  }

  /// 重置弹弹play为默认服务器
  static Future<void> resetToDefaultServer() async {
    await setDandanplayServer(defaultServer);
  }

  /// 重置Bangumi为默认服务器
  static Future<void> resetBangumiServer() async {
    final prefs = await SharedPreferences.getInstance();
    final had = prefs.containsKey(_bangumiServerKey);
    await prefs.remove(_bangumiServerKey);
    _cachedBangumiServer = bangumiDefaultServer;
    if (had) {
      await clearBangumiImageCaches();
    }
    print('[网络设置] Bangumi服务器已重置为默认: $bangumiDefaultServer');
  }

  /// 获取所有可用服务器列表
  static List<Map<String, String>> getAvailableServers() {
    return [
      {
        'name': 'NipaPlay 服务',
        'url': primaryServer,
        'description': '由 NipaPlay 网关连接弹弹play',
      },
    ];
  }

  /// 检查当前服务器是否为自定义服务器
  static bool isCustomServer(String serverUrl) {
    if (serverUrl.trim().isEmpty) {
      return false;
    }
    final normalized = _normalizeServerUrl(serverUrl);
    return normalized != primaryServer &&
        normalized != _legacyOfficialServer &&
        normalized != _legacyBackupServer;
  }

  /// 粗略校验用户输入的服务器地址
  static bool isValidServerUrl(String serverUrl) {
    final normalized = _normalizeServerUrl(serverUrl);
    final uri = Uri.tryParse(normalized);
    return uri != null &&
        (uri.isScheme('http') || uri.isScheme('https')) &&
        uri.host.isNotEmpty;
  }

  static String _normalizeServerUrl(String serverUrl) {
    var url = serverUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}
