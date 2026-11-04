import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/services/smb_proxy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<bool> healthOk(int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .get(InternetAddress.loopbackIPv4.address, port, '/smb/health');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return response.statusCode == 200 && body.trim() == 'ok';
    } finally {
      client.close(force: true);
    }
  }

  group('SMBProxyService 回环代理自愈', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(() async {
      await SMBProxyService.instance.stop();
    });

    test('initialize 后监听真实可连，health 返回 ok', () async {
      await SMBProxyService.instance.initialize();

      final service = SMBProxyService.instance;
      expect(service.isRunning, isTrue);
      expect(service.port, greaterThan(0));
      expect(await healthOk(service.port), isTrue);
    });

    test('监听 socket 被回收后再次 initialize 会就地重启（复现 iOS 后台挂起）', () async {
      final service = SMBProxyService.instance;
      await service.initialize();
      final firstPort = service.port;

      await service.simulateListenerReclaimedForTest();
      expect(service.isRunning, isTrue, reason: 'Dart 侧状态标记未失效');
      expect(await healthOk(firstPort), isFalse, reason: '旧端口已经拒连');

      await service.initialize();

      expect(service.isRunning, isTrue);
      expect(service.port, greaterThan(0));
      expect(await healthOk(service.port), isTrue);
    });

    test('ensureAliveIfRunning 在代理从未启动时是 no-op，不主动拉起', () async {
      await SMBProxyService.instance.ensureAliveIfRunning();
      expect(SMBProxyService.instance.isRunning, isFalse);
    });
  });
}
