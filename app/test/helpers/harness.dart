// Ekran testleri için ortak düzen: örnek profil, bellek kasası, sabit saat, animasyonsuz.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tiphys/app.dart';
import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/profile/repository.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
import 'package:tiphys/core/security/app_lock.dart';
import 'package:tiphys/features/claude/claude_screen.dart';
import 'package:tiphys/features/home/home_data.dart';
import 'package:tiphys/features/lock/lock_gate.dart';
import 'package:tiphys/state/providers.dart';
import 'package:tiphys/widgets/painters.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/ssh/connection.dart';
import 'package:tiphys/features/claude/claude_chat_screen.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/features/monitoring/providers.dart';
import 'package:tiphys/core/integrations/grafana_client.dart';
import 'package:tiphys/core/integrations/dozzle_client.dart';
import 'package:tiphys/features/terminal/sessions.dart';

final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
Profile exampleProfile() => codec.decode(File('assets/profile/example.json').readAsStringSync()).toProfile();

/// Tasarımdaki örnek değerler (ekran görüntüsü testleri için; gerçek veri değil).
const sampleHomeData = HomeData(
  hostStates: {'argo': HostState.online, 'atlas': HostState.online, 'orion': HostState.online},
  cpu: 0.18,
  ram: 0.58,
  claudeSessions: 2,
  claudeWaiting: 1,
  grafanaSpark: [26, 22, 24, 14, 18, 9, 15, 12, 20, 8, 11],
  dozzleLines: [LogLine('homepage', '200'), LogLine('searxng', 'warn', level: 'warn')],
  terminalTabs: 2,
);

class NoBiometrics implements Biometrics {
  @override
  Future<bool> available() async => false;
  @override
  Future<bool> authenticate(String reason) async => false;
}

class Harness {
  Harness({Profile? profile, Map<String, String>? secrets, this.homeData = sampleHomeData, this.pin})
      : profile = profile ?? exampleProfile(),
        secrets = MemorySecretStore(secrets ?? {'ssh-phone': 'x', 'agent-argo': 'x', 'grafana-atlas': 'x'});
  final Profile profile;
  final MemorySecretStore secrets;
  final HomeData homeData;
  final String? pin;
  final vault = MemoryVault();

  late final repo = ProfileRepository(
    file: File('${Directory.systemTemp.createTempSync('tiphys-ui').path}/profile.json'),
    codec: codec,
    secrets: secrets,
  );

  List<Override> get overrides => [
        secretStoreProvider.overrideWithValue(secrets),
        repositoryProvider.overrideWithValue(repo),
        initialProfileProvider.overrideWithValue(profile),
        homeDataProvider.overrideWithValue(homeData),
        clockProvider.overrideWithValue(() => DateTime(2026, 11, 14, 14, 5)),
        appLockProvider.overrideWithValue(AppLock(vault, kdfMemoryKiB: 8192)),
        biometricsProvider.overrideWithValue(NoBiometrics()),
        sshOpenerProvider.overrideWithValue((h) async => throw const SshFailure('unreachable')),
        agentClientFactoryProvider.overrideWithValue((h) async => FakeAgent()),
        tcpProbeProvider.overrideWithValue((host, port) async => true),
        agentHealthFnProvider.overrideWithValue((url) async => {
              'name': 'argo',
              'version': '0.3.0',
              'features': {for (final f in ['system', 'services', 'docker', 'power', 'git', 'desktop', 'ports', 'transcribe', 'claude', 'homepage']) f: true},
            }),
        claudeStreamEnabledProvider.overrideWithValue(false),
        outboxDirProvider.overrideWithValue(() async => null),
        grafanaFactoryProvider.overrideWithValue((g) async => FakeGrafana()),
        dozzleFactoryProvider.overrideWithValue((d) async => FakeDozzle()),
      ];

  /// Uygulamayı belirli bir rotada, tema ve dilde açar.
  Future<ProviderContainer> pump(WidgetTester tester, {String route = '/', bool dark = false, String lang = 'tr'}) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true, reduceMotion: true);
    tester.platformDispatcher.localeTestValue = Locale(lang);
    tester.platformDispatcher.localesTestValue = [Locale(lang)];
    debugDisableShadows = false;
    tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
    if (pin != null) await tester.runAsync(() => AppLock(vault, kdfMemoryKiB: 8192).setPin(pin!));
    final container = ProviderContainer(overrides: overrides);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const TiphysApp()));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    if (route != '/') {
      container.read(routerProvider).go(route.startsWith('/settings') && route != '/settings' ? '/settings' : route);
      await settle(tester);
      if (route.startsWith('/settings') && route != '/settings') {
        container.read(routerProvider).push(route);
      }
    }
    await settle(tester);
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearAllTestValues();
      container.dispose();
    });
    return container;
  }
}

extension RouterOf on ProviderContainer {
  GoRouter get router => read(routerProvider);
}

/// pumpAndSettle yerine sabit süreli pompalama (sonsuz animasyonda takılmasın).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Ekran görüntüsünü karşılaştırır ve gölge ayarını test çerçevesinin beklediği hale geri alır.
Future<void> golden(String file) async {
  await expectLater(find.byType(TiphysApp), matchesGoldenFile(file));
  debugDisableShadows = true;
}

/// Ajanın gerçek yanıt biçiminde örnek veriler (ağa çıkmaz).
class FakeAgent extends AgentClient {
  FakeAgent() : super(baseUrl: 'http://fake', token: 'tph_fake');

  /// Testlerin doğrulaması için gönderilen istekler (her test kendisi temizler).
  static final calls = <(String, String, Object?)>[];

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout}) async {
    calls.add((method, path, body));
    if (method == 'POST' && path.startsWith('/v1/claude/terminal/') && path.endsWith('/takeover')) {
      return {'id': 'md1', 'status': 'idle', 'title': '(devam)'};
    }
    if (path.startsWith('/v1/claude/history/')) {
      return {
        'events': [
          {'kind': 'user', 'text': 'Tiphys yayın hazırlığını yap', 'images': 0, 'seq': 1, 'at': '2026-11-14T10:00:00Z'},
          {'kind': 'text', 'text': 'APK **hazır**, testler geçiyor.', 'seq': 2, 'at': '2026-11-14T10:01:00Z'},
        ],
      };
    }
    if (method == 'POST' && path == '/v1/claude/sessions') {
      return {'id': 'md1', 'status': 'idle', 'title': ''};
    }
    if (path == '/v1/agent/status') {
      return {
        'version': '0.3.0',
        'startedAt': '2026-11-14T08:00:00Z',
        'uptimeSeconds': 3 * 3600 + 25 * 60,
        'memory': {'agentBytes': 96 * 1024 * 1024, 'childrenBytes': 1300 * 1024 * 1024},
        'unexpectedRestarts24h': 1,
        'lastUnexpectedAt': '2026-11-14T07:59:00Z',
      };
    }
    if (path == '/v1/system') {
      return {
        'hostname': 'argo',
        'os': 'Debian GNU/Linux 13',
        'kernel': '6.12.0-amd64',
        'uptimeSeconds': 3 * 86400 + 5 * 3600,
        'cpu': {'loadPercent': 18.4, 'cores': 8, 'temperatureC': 56.9},
        'memory': {'totalBytes': 16 * 1024 * 1024 * 1024, 'usedBytes': 9.2 * 1024 * 1024 * 1024, 'swapTotalBytes': 0, 'swapUsedBytes': 0},
        'disks': [
          {'mount': '/', 'fs': 'ext4', 'totalBytes': 908 * 1024 * 1024 * 1024, 'usedBytes': 424 * 1024 * 1024 * 1024},
        ],
        'gpus': [
          {'name': 'NVIDIA GeForce GPU', 'temperatureC': 37, 'utilizationPercent': 20, 'memoryUsedMiB': 358, 'memoryTotalMiB': 4096},
        ],
      };
    }
    if (path.startsWith('/v1/services/')) {
      return {
        'scope': 'user',
        'units': [
          {'unit': 'tiphys-agent.service', 'load': 'loaded', 'active': 'active', 'sub': 'running', 'description': 'Tiphys Ajanı'},
          {'unit': 'syncthing.service', 'load': 'loaded', 'active': 'active', 'sub': 'running', 'description': 'Syncthing'},
          {'unit': 'app-backup.service', 'load': 'loaded', 'active': 'failed', 'sub': 'failed', 'description': 'Yedek'},
        ],
      };
    }
    if (path == '/v1/docker/containers') {
      return {
        'containers': [
          {'id': 'a', 'name': 'homepage', 'image': 'homepage', 'state': 'running', 'status': 'Up 3 days', 'project': 'home-services', 'cpuPercent': 0.4, 'memory': '120MiB / 15GiB'},
          {'id': 'b', 'name': 'gitea', 'image': 'gitea', 'state': 'running', 'status': 'Up 3 days', 'project': null, 'cpuPercent': 1.2, 'memory': '210MiB / 15GiB'},
        ],
      };
    }
    if (path == '/v1/uptime/monitors') {
      Map<String, dynamic> m(int id, String name, String status, int? ping, double up, int? ssl, List<int> recent) => {
            'id': id, 'name': name, 'url': 'https://$name', 'type': 'http', 'active': status != 'paused', 'interval': 60, 'status': status,
            'ping': ping, 'avgPing': ping, 'uptime24h': up, 'uptime30d': up, 'cert': ssl == null ? null : {'valid': true, 'daysRemaining': ssl, 'issuer': 'Google Trust Services'}, 'recent': recent,
          };
      return {
        'state': {'connected': true, 'loggedIn': true, 'error': null},
        'monitors': [
          m(2, 'api.example.com', 'up', 99, 1, 88, List.filled(16, 1)),
          m(1, 'example.com', 'up', 156, 1, 88, List.filled(16, 1)),
          m(4, 'status.example.com', 'down', null, 0.9861, 88, [...List.filled(12, 1), 0, 0, 0, 0]),
          m(6, 'shop.example.org', 'up', 319, 0.9993, 61, List.filled(16, 1)),
        ],
      };
    }
    if (path.startsWith('/v1/uptime/monitors/') && path.endsWith('/beats')) {
      final now = DateTime.utc(2026, 11, 14, 11);
      return {
        'beats': [
          for (var i = 0; i < 60; i++)
            {'status': 1, 'time': now.subtract(Duration(minutes: 60 - i)).toIso8601String().replaceFirst('T', ' ').replaceFirst('Z', ''), 'ping': 120 + (i % 7) * 15 + (i == 40 ? 260 : 0)},
        ],
      };
    }
    if (path.startsWith('/v1/uptime/monitors/')) {
      return {
        'id': 4, 'name': 'status.example.com', 'url': 'https://status.example.com', 'type': 'http', 'active': true, 'interval': 60, 'status': 'down',
        'ping': null, 'avgPing': 140, 'uptime24h': 0.9861, 'uptime30d': 0.9991, 'cert': {'valid': true, 'daysRemaining': 88}, 'recent': [],
        'maxretries': 1, 'retryInterval': 60, 'timeout': 30, 'expiryNotification': true, 'beats': [],
        'incidents': [
          {'status': 0, 'time': '2026-11-14 10:57:00.000', 'msg': 'Request failed with status code 502', 'duration': 60},
          {'status': 1, 'time': '2026-11-13 22:10:00.000', 'msg': '200 - OK', 'duration': 60},
          {'status': 0, 'time': '2026-11-13 22:04:00.000', 'msg': 'timeout of 30000ms exceeded', 'duration': 60},
        ],
      };
    }
    if (path == '/v1/homepage') {
      Map<String, dynamic> s(String n, String d, String st, int? ms) => {'name': n, 'href': 'https://$n', 'description': d, 'icon': null, 'monitorUrl': 'x', 'status': st, 'responseMs': ms};
      return {
        'checkedAt': '2026-11-14T11:00:00Z',
        'groups': [
          {'name': 'Bulut (orion)', 'services': [], 'groups': [
            {'name': 'Yapay zekâ', 'services': [s('Notes', 'Not defteri · :8765', 'up', 84), s('Search', 'Arama motoru · :6767', 'up', 61)], 'groups': []},
            {'name': 'Araçlar', 'services': [s('Console', '4× Android · :8000', 'down', null), s('PairDrop', 'Dosya gönderme · :3010', 'up', 40)], 'groups': []},
          ]},
          {'name': 'Bulut (atlas)', 'services': [], 'groups': [
            {'name': 'İzleme', 'services': [s('Grafana', 'Sunucu, container, log paneli · :3030', 'up', 52), s('Uptime Kuma', 'Site kesinti izleme · :3001', 'up', 33)], 'groups': []},
          ]},
        ],
      };
    }
    if (path == '/v1/claude/sessions') {
      return {
        'live': [
          {'id': 'a1', 'sdkSessionId': 's1', 'cwd': '/home/user/Desktop/website', 'title': 'Testleri düzelt ve raporla', 'status': 'waiting', 'model': 'claude-opus-5-5', 'permissionMode': 'default', 'profileId': 'personal', 'costUsd': 0.84, 'createdAt': '2026-11-14T10:00:00Z', 'lastActivity': '2026-11-14T10:58:00Z', 'pendingPermissions': 1, 'live': true},
          {'id': 'a2', 'sdkSessionId': 's2', 'cwd': '/home/user/Desktop/video', 'title': 'Video 3 altyazıları', 'status': 'running', 'model': 'claude-opus-5-5', 'permissionMode': 'bypassPermissions', 'profileId': 'personal', 'costUsd': 1.27, 'createdAt': '2026-11-14T09:00:00Z', 'lastActivity': '2026-11-14T11:00:00Z', 'pendingPermissions': 0, 'live': true},
        ],
        'terminal': [
          {'pid': 3452, 'sdkSessionId': '5e55a0c1-0000-4000-8000-000000000003', 'cwd': '/home/user', 'title': 'Tiphys yayın hazırlığı', 'status': 'busy', 'name': 'user-23', 'startedAt': '2026-11-14T08:00:00Z', 'updatedAt': '2026-11-14T10:59:00Z'},
        ],
        'history': [
          {'sdkSessionId': '7e08e218-0000-4000-8000-000000000001', 'title': 'Web sitesi Docker mimarisi', 'cwd': '/home/user/projects/web', 'lastActivity': '2026-11-13T18:00:00Z', 'live': false},
          {'sdkSessionId': '7e08e218-0000-4000-8000-000000000002', 'title': 'Homepage düzeni', 'cwd': '/home/user/homepage', 'lastActivity': '2026-11-12T09:00:00Z', 'live': false},
        ],
      };
    }
    if (path.startsWith('/v1/claude/sessions/')) {
      var seq = 0;
      Map<String, dynamic> e(Map<String, dynamic> m) => {...m, 'seq': ++seq, 'at': '2026-11-14T10:00:00Z'};
      if (path.endsWith('/long1')) {
        return {
          'session': {'id': 'long1', 'cwd': '/home/user', 'title': 'Uzun sohbet', 'status': 'idle', 'model': 'claude-opus-5-5', 'costUsd': 1.0},
          'events': [for (var i = 0; i < 60; i++) e({'kind': 'user', 'text': 'Mesaj $i', 'images': 0})],
        };
      }
      if (path.endsWith('/md1')) {
        return {
          'session': {'id': 'md1', 'cwd': '/home/user/Desktop/tiphys', 'title': 'Durum raporu', 'status': 'idle', 'model': 'claude-opus-5-5', 'costUsd': 0.12},
          'events': [
            e({'kind': 'user', 'text': 'Durumu özetle', 'images': 0}),
            e({'kind': 'text', 'text': markdownSample}),
            e({'kind': 'result', 'ok': true, 'text': '', 'costUsd': 0.12, 'turns': 1, 'durationMs': 4200}),
          ],
        };
      }
      return {
        'session': {'id': 'a1', 'cwd': '/home/user/Desktop/website', 'title': 'Testleri düzelt ve raporla', 'status': 'waiting', 'model': 'claude-opus-5-5', 'costUsd': 0.84},
        'events': [
          e({'kind': 'user', 'text': 'runner.py testlerini düzelt, sonra kısaca raporla', 'images': 0}),
          e({'kind': 'init', 'model': 'claude-opus-5-5', 'cwd': '/home/user/Desktop/website', 'permissionMode': 'default', 'slashCommands': []}),
          e({'kind': 'text', 'text': 'Önce test çıktısına bakıyorum.'}),
          e({'kind': 'tool_use', 'id': 't1', 'name': 'Bash', 'input': {'command': 'pytest -q agents/'}}),
          e({'kind': 'tool_result', 'toolUseId': 't1', 'text': '2 failed, 14 passed', 'isError': false}),
          e({'kind': 'tool_use', 'id': 't2', 'name': 'Edit', 'input': {'file_path': 'agents/runner.py', 'old_string': '    return run(cfg)', 'new_string': '    return run(cfg, timeout=30)'}}),
          e({'kind': 'tool_result', 'toolUseId': 't2', 'text': 'ok', 'isError': false}),
          e({'kind': 'permission', 'requestId': 'p1', 'toolName': 'Bash', 'input': {'command': 'rm -rf .pytest_cache build'}, 'reason': null}),
          e({'kind': 'status', 'status': 'waiting'}),
        ],
      };
    }
    if (path == '/v1/processes') {
      Map<String, dynamic> pr(int pid, String name, double cpu, int rssMb, String cmd, [String user = 'user']) =>
          {'pid': pid, 'ppid': 1, 'user': user, 'cpuPercent': cpu, 'memPercent': rssMb / 160, 'rssBytes': rssMb * 1024 * 1024, 'elapsedSeconds': 3600, 'name': name, 'command': cmd};
      return {
        'total': 412,
        'processes': [
          pr(4242, 'node', 23.4, 512, 'node dist/cli.js serve'),
          pr(1880, 'firefox', 11.2, 1840, '/usr/lib/firefox/firefox'),
          pr(2210, 'Hyprland', 4.1, 260, 'Hyprland'),
          pr(990, 'dockerd', 1.3, 140, '/usr/bin/dockerd -H fd://', 'root'),
          pr(3011, 'pipewire', 0.8, 40, '/usr/bin/pipewire'),
        ],
      };
    }
    if (path == '/v1/ports') {
      return {
        'host': 'argo.example.ts.net',
        'ports': [
          {'port': 22, 'address': '0.0.0.0', 'process': null, 'pid': null, 'localOnly': false, 'shared': false, 'url': 'http://argo.example.ts.net:22', 'reserved': false},
          {'port': 3000, 'address': '127.0.0.1', 'process': 'node', 'pid': 4300, 'localOnly': true, 'shared': true, 'url': 'https://argo.example.ts.net:3000', 'reserved': false},
          {'port': 5173, 'address': '::1', 'process': 'vite', 'pid': 4400, 'localOnly': true, 'shared': false, 'url': null, 'reserved': false},
          {'port': 7443, 'address': '127.0.0.1', 'process': 'node', 'pid': 4242, 'localOnly': true, 'shared': true, 'url': null, 'reserved': true},
          {'port': 8443, 'address': '0.0.0.0', 'process': 'homepage', 'pid': 777, 'localOnly': false, 'shared': false, 'url': 'http://argo.example.ts.net:8443', 'reserved': false},
        ],
      };
    }
    if (path == '/v1/audit') {
      return {
        'entries': [
          {'at': '2026-11-14T11:02:00Z', 'device': 'redmi', 'method': 'POST', 'path': '/v1/git/commit', 'status': 200},
          {'at': '2026-11-14T10:41:00Z', 'device': 'redmi', 'method': 'POST', 'path': '/v1/services/user/homepage.service/restart', 'status': 200},
          {'at': '2026-11-14T10:40:00Z', 'device': 'redmi', 'method': 'POST', 'path': '/v1/processes/9921/signal', 'status': 403},
        ],
      };
    }
    if (path == '/v1/git/status') {
      Map<String, dynamic> f(String p, String i, String w, {bool u = false}) => {'path': p, 'origPath': null, 'index': i, 'worktree': w, 'untracked': u, 'conflicted': false};
      return {
        'root': '/home/user/Desktop/tiphys',
        'branch': 'main',
        'upstream': 'origin/main',
        'ahead': 2,
        'behind': 0,
        'head': 'abc1234',
        'files': [
          f('app/lib/features/git/git_screen.dart', 'A', '.'),
          f('agent/src/routes/git.ts', 'M', '.'),
          f('PLAN.md', '.', 'M'),
          f('app/lib/features/system/tools.dart', '.', 'M'),
          f('notes/todo.md', '.', '?', u: true),
        ],
      };
    }
    if (path == '/v1/git/log') {
      Map<String, dynamic> c(String h, String s, String d, [String refs = '']) => {'hash': h.padRight(40, '0'), 'author': 'user', 'date': d, 'subject': s, 'refs': refs};
      return {
        'commits': [
          c('9f2c1ab', 'Faz 7: git, süreçler ve port önizleme', '2026-11-14T12:10:00+03:00', 'HEAD -> main'),
          c('41de09c', 'Grafana metin, alarm ve dashboard panelleri', '2026-11-14T09:30:00+03:00'),
          c('7ab3310', 'Bildirimler: WebPush şifreleme', '2026-11-13T22:05:00+03:00', 'origin/main'),
        ],
      };
    }
    if (path == '/v1/git/diff') {
      return {
        'diff': 'diff --git a/PLAN.md b/PLAN.md\nindex 1a2b3c4..5d6e7f8 100644\n--- a/PLAN.md\n+++ b/PLAN.md\n@@ -288,3 +288,4 @@\n ## 8. Durum (2026-11-14)\n-0–6. fazlar tamamlandı.\n+0–7. fazlar tamamlandı.\n+Telefon yalnızca son gerçek test için.\n',
        'truncated': false,
      };
    }
    if (path == '/v1/uptime/maintenance') {
      return {
        'maintenances': [
          {'id': 1, 'title': 'Sunucu taşıma', 'status': 'under-maintenance', 'active': true, 'strategy': 'single', 'start': '2026-11-14 10:00:00', 'end': '2026-11-14 12:00:00', 'monitorIds': [1, 2]},
          {'id': 2, 'title': 'DNS değişikliği', 'status': 'ended', 'active': true, 'strategy': 'single', 'start': '2026-11-12 22:00:00', 'end': '2026-11-12 23:00:00', 'monitorIds': [3]},
        ],
      };
    }
    if (path == '/v1/desktop/clipboard') return {'text': 'ssh user@100.64.0.2'};
    throw const AgentError('agent.route.notFound');
  }
}

class FakeGrafana extends GrafanaClient {
  FakeGrafana() : super('http://fake');
  @override
  Future<List<GrafanaDashboardRef>> search([String q = '']) async => const [
        GrafanaDashboardRef(uid: 'systems-overview', title: 'System overview'),
        GrafanaDashboardRef(uid: 'web', title: 'Web'),
      ];
  @override
  Future<Map<String, dynamic>> dashboard(String uid) async => {
        'title': 'System overview',
        'templating': {'list': [
          {'name': 'system', 'type': 'custom', 'query': 'argo,atlas,orion', 'current': {'value': 'atlas'}, 'options': []},
        ]},
        'panels': [
          {'type': 'row', 'title': 'Host', 'panels': []},
          {'id': 1, 'type': 'stat', 'title': 'CPU used', 'fieldConfig': {'defaults': {'unit': 'percent', 'thresholds': {'steps': [{'color': 'green', 'value': null}, {'color': 'red', 'value': 80}]}}}, 'targets': [{'refId': 'A', 'expr': 'x'}]},
          {'id': 2, 'type': 'stat', 'title': 'Memory used', 'fieldConfig': {'defaults': {'unit': 'percent'}}, 'targets': [{'refId': 'A', 'expr': 'x'}]},
          {'id': 3, 'type': 'timeseries', 'title': 'CPU by mode', 'fieldConfig': {'defaults': {'unit': 'percent'}}, 'targets': [{'refId': 'A', 'expr': 'x'}]},
          {'id': 4, 'type': 'table', 'title': 'Restarts (last hour)', 'targets': [{'refId': 'A', 'expr': 'x'}]},
          {'type': 'row', 'title': 'Home', 'panels': []},
          {'id': 5, 'type': 'text', 'title': '', 'options': {'mode': 'markdown', 'content': '## Systems\nEvery monitored system pushes metrics with a `system` label. Open **System overview** for one system.'}},
          {'id': 6, 'type': 'alertlist', 'title': 'Firing and pending alerts', 'options': {'maxItems': 20, 'stateFilter': {'firing': true, 'pending': true}}},
          {'id': 7, 'type': 'dashlist', 'title': 'Dashboards', 'options': {'maxItems': 10, 'query': ''}},
        ],
      };
  @override
  Future<List<({String uid, String type, String name})>> datasources() async => const [(uid: 'prom', type: 'prometheus', name: 'Prometheus')];
  @override
  Future<List<GrafanaRule>> rules(List<String> prometheusUids) async => [
        GrafanaRule(name: 'BackupStale', group: 'backups', source: 'prom', state: 'pending', severity: 'critical', summary: 'No verified database backup for more than 26 hours', query: 'time() - app_backup_last_success_timestamp > 26 * 3600', activeAt: DateTime.utc(2026, 11, 14, 9), activeCount: 1),
        GrafanaRule(name: 'HostDiskAlmostFull', group: 'hosts', source: 'prom', state: 'firing', severity: 'warning', summary: 'Disk / on orion is above 90%', activeAt: DateTime.utc(2026, 11, 14, 8, 15), activeCount: 1),
        const GrafanaRule(name: 'HostDown', group: 'hosts', source: 'prom', state: 'normal', severity: 'critical'),
        const GrafanaRule(name: 'ContainerRestarting', group: 'docker', source: 'prom', state: 'normal', severity: 'warning'),
      ];
  @override
  Future<void> loadOptions(GrafanaVariable v) async => v.options = ['argo', 'atlas', 'orion'];
  @override
  Future<PanelData> query(GrafanaPanel p, List<GrafanaVariable> vars, {required String from, String to = 'now', int maxDataPoints = 120, String? prometheusUid}) async {
    final t0 = DateTime.utc(2026, 11, 14, 10).millisecondsSinceEpoch;
    List<int> times() => [for (var i = 0; i < 60; i++) t0 + i * 60000];
    if (p.type == 'text') return const PanelData();
    if (p.type == 'alertlist') {
      return PanelData(alerts: [
        GrafanaAlert(name: 'BackupStale', state: 'pending', severity: 'critical', summary: 'No verified database backup for more than 26 hours', activeAt: DateTime.utc(2026, 11, 14, 9)),
      ]);
    }
    if (p.type == 'dashlist') return PanelData(dashboards: await search());
    return switch (p.type) {
      'stat' => PanelData(series: [Series('v', const [], [p.title.startsWith('CPU') ? 18.4 : 61.2])]),
      'timeseries' => PanelData(series: [
          Series('user', times(), [for (var i = 0; i < 60; i++) 8 + (i % 9) * 1.5]),
          Series('system', times(), [for (var i = 0; i < 60; i++) 3 + (i % 5) * 0.8]),
          Series('iowait', times(), [for (var i = 0; i < 60; i++) (i % 13 == 0) ? 6 : 1]),
        ]),
      _ => PanelData(series: [Series('searxng', const [], [2]), Series('firecrawl-api', const [], [1]), Series('homepage', const [], [0])]),
    };
  }
}

class FakeDozzle extends DozzleClient {
  FakeDozzle() : super('http://fake');
  @override
  Future<List<DozzleContainer>> containers() async => [
        for (final (n, st, h) in [('web-1', 'running', 'healthy'), ('db-1', 'running', null), ('searxng', 'running', 'unhealthy'), ('migrate-1', 'exited', null)])
          DozzleContainer({'id': n, 'name': n, 'host': 'h', 'image': 'img/$n', 'state': st, 'health': h, 'stats': [{'cpu': 0.4, 'memoryUsage': 141590528}]}),
      ];
}

/// Sohbet Markdown görünümü için örnek cevap: başlık, kalın/italik, liste, görev, tablo, kod, alıntı.
const markdownSample = '''## Özet

Testler **geçiyor**, `flutter analyze` temiz. Kalan iş *telefonda* deneme.

- Ajan: 45 test
- Uygulama: 77 test
  - goldenlar güncel

1. APK'yı kur
2. Profili içe aktar

- [x] Logo
- [ ] Gerçek cihaz testi

| Bileşen | Durum | Not |
|---|---|---|
| Ajan | ✓ | 0.2.0 |
| Uygulama | ✓ | arm64 |

```dart
if (a != b) return x >= 0 ? a : b;
```

> Not: argo'ta parolalı giriş açık kalıyor.

---
Ayrıntı: ~~eski yol~~ yeni yol.''';

