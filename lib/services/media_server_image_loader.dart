import 'dart:async';
import 'dart:typed_data';

import 'package:nipaplay/services/dandanplay_http_client.dart' as http;
import 'package:nipaplay/services/media_server_transport.dart';
import 'package:nipaplay/services/web_remote_access_service.dart';

final Map<String, Uri> _mediaServerBaseUris = {};

void setMediaServerBaseUrl(String serverKey, String? baseUrl) {
  final uri = baseUrl == null ? null : Uri.tryParse(baseUrl);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    _mediaServerBaseUris.remove(serverKey);
    return;
  }
  _mediaServerBaseUris[serverKey] = uri;
}

bool isMediaServerImageUri(Uri uri) {
  if (!_mediaServerBaseUris.values.any((base) => _isWithinBase(base, uri))) {
    return false;
  }
  final segments = uri.pathSegments
      .map((segment) => segment.toLowerCase())
      .toList(growable: false);
  for (var index = 0; index + 2 < segments.length; index += 1) {
    if (segments[index] == 'items' && segments[index + 2] == 'images') {
      return true;
    }
  }
  return false;
}

bool _isWithinBase(Uri base, Uri candidate) {
  if (!_sameOrigin(base, candidate)) {
    return false;
  }
  final baseSegments = base.pathSegments.where((segment) => segment.isNotEmpty);
  final candidateSegments = candidate.pathSegments.iterator;
  for (final baseSegment in baseSegments) {
    if (!candidateSegments.moveNext() ||
        candidateSegments.current.toLowerCase() != baseSegment.toLowerCase()) {
      return false;
    }
  }
  return true;
}

bool _sameOrigin(Uri left, Uri right) {
  return left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;
}

/// 全局图片下载并发上限。
///
/// 媒体库一屏十几张封面、每张还有基础图+高清图两条通道，滚动时瞬间
/// 会发几十个请求；服务器/CDN 对突发并发会直接丢请求，表现为
/// 「滑过去一片灰，滑回来同样的图又灰」。这里全局限流排队。
int _imageDownloadsInFlight = 0;
final List<Completer<void>> _imageDownloadWaiters = [];
const int _maxImageDownloadConcurrency = 6;

Future<T> _runImageDownloadLimited<T>(Future<T> Function() task) async {
  if (_imageDownloadsInFlight >= _maxImageDownloadConcurrency) {
    // FIFO 等待队列：拿到名额才继续。
    final waiter = Completer<void>();
    _imageDownloadWaiters.add(waiter);
    await waiter.future;
  }
  _imageDownloadsInFlight++;
  try {
    return await task();
  } finally {
    _imageDownloadsInFlight--;
    if (_imageDownloadWaiters.isNotEmpty) {
      _imageDownloadWaiters.removeAt(0).complete();
    }
  }
}

Future<Uint8List> loadNetworkImageBytes(Uri originalUri) async {
  return _runImageDownloadLimited(() async {
    final requestUri = WebRemoteAccessService.proxyUri(originalUri);
    if (isMediaServerImageUri(originalUri)) {
      return loadMediaServerImage(requestUri);
    }

    // iOS 上同时发出的请求偶发被直接掐断（无明确错误码），重试一次能救回
    // 大部分；组件层还有最多两次的延迟重试兜底。
    var lastError = Object();
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await http.get(requestUri);
        if (response.statusCode != 200) {
          throw http.ClientException(
            'Image request failed: HTTP ${response.statusCode}',
            requestUri,
          );
        }
        return response.bodyBytes;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError;
  });
}

Future<Uint8List> loadMediaServerImage(Uri uri) async {
  final transport = await MediaServerTransport.fromStoredSettings();
  try {
    final response = await transport.send(
      http.Request('GET', uri),
      timeout: const Duration(seconds: 20),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'Media-server image request failed: HTTP ${response.statusCode}',
        uri,
      );
    }
    return response.bodyBytes;
  } finally {
    transport.close();
  }
}
