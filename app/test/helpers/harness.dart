// Shared setup for screen tests: example profile, in-memory vault, fixed clock, no animations.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:tiphys/features/claude/session_insights.dart';
import 'package:tiphys/features/home/home_data.dart';
import 'package:tiphys/features/lock/lock_gate.dart';
import 'package:tiphys/features/onboarding/onboarding_state.dart';
import 'package:tiphys/state/providers.dart';
import 'package:tiphys/widgets/painters.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/ssh/connection.dart';
import 'package:tiphys/features/claude/claude_chat_screen.dart';
import 'package:tiphys/features/claude/pc_ongoing.dart';
import 'package:tiphys/core/push/push_service.dart' show PcHold;
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/features/monitoring/providers.dart';
import 'package:tiphys/core/integrations/grafana_client.dart';
import 'package:tiphys/core/integrations/dozzle_client.dart';
import 'package:tiphys/features/terminal/sessions.dart';

import 'png.dart';
import 'agy_fixtures.dart';
import 'config_fixtures.dart';
import 'db_fixtures.dart';
import 'incident_fixtures.dart';
import 'security_fixtures.dart';
import 'security_more_fixtures.dart';
import 'ui_fixtures.dart';

export 'agy_fixtures.dart';
export 'config_fixtures.dart';
export 'db_fixtures.dart';
export 'incident_fixtures.dart';
export 'security_fixtures.dart';
export 'security_more_fixtures.dart';
export 'ui_fixtures.dart';

final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
Profile exampleProfile() => codec.decode(File('assets/profile/example.json').readAsStringSync()).toProfile();

/// Sample values from the design (for screenshot tests; not real data).
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
  Harness({Profile? profile, Map<String, String>? secrets, this.homeData = sampleHomeData, this.pin, this.extra = const [], this.agent, this.biometrics, this.agentFeatures = defaultAgentFeatures, this.clock, this.onboarded = true, this.agentVersion = '0.3.0', this.health})
      : profile = profile ?? exampleProfile(),
        secrets = MemorySecretStore(secrets ?? {'ssh-phone': 'x', 'agent-argo': 'x', 'grafana-atlas': 'x'});
  final Profile profile;

  /// The app's clock (default: a fixed moment); tests that move time pass their own.
  final DateTime Function()? clock;
  final MemorySecretStore secrets;
  final HomeData homeData;
  final String? pin;

  /// Extra test-specific provider overrides.
  final List<Override> extra;

  /// Agent client (default: FakeAgent); for tests that want different behavior per host.
  final Future<AgentClient> Function(Host)? agent;

  /// Fingerprint (default: not on the device).
  final Biometrics? biometrics;

  /// Features enabled in the agent's health response.
  final List<String> agentFeatures;

  /// The setup wizard was already seen (false: a first launch).
  final bool onboarded;

  /// Version in the agent's health response.
  final String agentVersion;

  /// Replaces the tokenless health check entirely (e.g. a version that changes after an update).
  final Future<Map<String, dynamic>> Function(String url)? health;
  static const defaultAgentFeatures = ['system', 'services', 'docker', 'power', 'git', 'desktop', 'control', 'ports', 'transcribe', 'claude', 'homepage', 'backups'];
  final vault = MemoryVault();

  /// Fake of the persistent "Claude is using the PC" notification.
  final pcNotifications = FakePcNotifications();

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
        clockProvider.overrideWithValue(clock ?? () => DateTime(2026, 11, 14, 14, 5)),
        appLockProvider.overrideWithValue(AppLock(vault, kdfMemoryKiB: 8192)),
        biometricsProvider.overrideWithValue(biometrics ?? NoBiometrics()),
        sshOpenerProvider.overrideWithValue((h) async => throw const SshFailure('unreachable')),
        agentClientFactoryProvider.overrideWithValue(agent ?? (h) async => FakeAgent(h.id)),
        tcpProbeProvider.overrideWithValue((host, port) async => true),
        agentHealthFnProvider.overrideWithValue(health ?? (url) async => {
              'name': 'argo',
              'version': agentVersion,
              'features': {for (final f in agentFeatures) f: true},
            }),
        claudeStreamEnabledProvider.overrideWithValue(false),
        outboxDirProvider.overrideWithValue(() async => null),
        grafanaFactoryProvider.overrideWithValue((g) async => FakeGrafana()),
        dozzleFactoryProvider.overrideWithValue((d) async => FakeDozzle()),
        pcNotificationsProvider.overrideWithValue(pcNotifications),
        onboardingSeenInitialProvider.overrideWithValue(onboarded),
        onboardingVaultProvider.overrideWithValue(vault),
        ...extra,
      ];

  /// Opens the app at a given route, theme and locale.
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

/// Fixed-duration pumping instead of pumpAndSettle (so it doesn't hang on endless animations).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Compares the screenshot and restores the shadow setting to what the test framework expects.
Future<void> golden(String file) async {
  await expectLater(find.byType(TiphysApp), matchesGoldenFile(file));
  debugDisableShadows = true;
}

/// Sample data in the agent's real response format (no network access).
class FakeAgent extends AgentClient {
  FakeAgent([this.hostId = 'argo']) : super(baseUrl: 'http://fake', token: 'tph_fake');

  /// Which host it was opened for (event and backup responses differ per host).
  final String hostId;

  /// Requests sent, for tests to verify (each test clears them itself).
  static final calls = <(String, String, Object?)>[];

  /// true: push without setUpstream fails with "branch not on remote" (session changes test).
  static bool pushNoUpstream = false;

  /// Whether the "pc1" PC session's control link is open according to the agent (tests may change it).
  static bool pcControl = true;

  /// GET /v1/media and /v1/media/volume responses (in the agent's format; tests may change them).
  static Map<String, dynamic> media = sampleMedia();

  /// POST /v1/velour results by op, or an AgentError to throw (tests may change them).
  static Map<String, Object?> velour = sampleVelour();

  /// GET /v1/desktop/windows response or the error to throw (tests may change it).
  static Object desktop = sampleDesktop();

  /// GET /v1/desktop/capabilities, /v1/doctor, /v1/update responses or the errors to throw; null = an older agent
  /// without the route (404). POST /v1/update/apply answers [updateApply]. Tests change them, then call [resetSetup].
  static Object? capabilities;
  static Object? doctor;
  static Object? update;
  static Object updateApply = {'ok': true, 'version': '0.4.0', 'restarting': true};

  /// Version in GET /v1/agent/status.
  static String statusVersion = '0.3.0';

  static void resetSetup() {
    capabilities = null;
    doctor = null;
    update = null;
    updateApply = {'ok': true, 'version': '0.4.0', 'restarting': true};
    statusVersion = '0.3.0';
  }

  static dynamic _orNotFound(Object? v) {
    if (v == null) throw const AgentError('agent.route.notFound', {}, 404);
    if (v is AgentError) throw v;
    return v;
  }

  /// GET /v1/desktop/sunshine response or the error to throw (tests may change it); start/stop flips `running`.
  static Object sunshine = sampleSunshine();

  /// Last extra headers sent, by path (control session token).
  static final headersByPath = <String, Map<String, String>?>{};

  /// GET /v1/desktop/browser response; null = old agent (no endpoint → row hidden). Tests change it, then reset to
  /// null.
  static Map<String, dynamic>? browser;

  /// The bridge's tab list.
  static List<Map<String, dynamic>> browserTabs = sampleTabs();

  /// Page action (reader, media, scroll, text) response or AgentError to throw; otherwise a sample response.
  static final browserPage = <String, Object>{};

  /// SSE `GET /v1/desktop/browser/events` events (tests add them); each subscriber listens on a fresh broadcast stream.
  static StreamController<(String, String)> browserEvents = StreamController.broadcast();

  /// SSE subscriber count (reconnect / close check).
  static int browserSubscribers = 0;

  /// Mobile view (11.4): `GET /v1/desktop/ui` snapshot or AgentError to throw. The generation increments on every read
  /// ([uiGen]); an action with an old generation gets agent.ui.stale (as on the agent).
  static Object ui = sampleUiFirefox();
  static int uiGen = 0;

  /// Errors to throw in order for `POST /v1/desktop/ui/*` (empty means {ok: true}).
  static final uiErrors = <AgentError>[];

  /// SSE `GET /v1/desktop/ui/events` events and subscriber count.
  static StreamController<(String, String)> uiEvents = StreamController.broadcast();

  /// Velour live state: each SSE subscriber first gets velour['state'], then whatever tests add here.
  static StreamController<(String, String)> velourEvents = StreamController.broadcast();

  /// GET /v1/media/outputs (PUT /v1/media/output moves the default).
  static List<Map<String, Object?>> outputs = sampleOutputs();
  static int uiSubscribers = 0;

  /// Incident room (GET/POST /v1/incidents*): incidents per host id and the knobs of the action routes.
  static Map<String, List<Map<String, dynamic>>> incidents = sampleIncidents();
  static FakeIncidentState incident = FakeIncidentState();

  /// Config files and secrets (GET/POST/PUT /v1/config-files*, /v1/secrets/meta).
  static FakeConfigState config = FakeConfigState();

  /// agy sessions (GET/POST/DELETE /v1/agy/*).
  static FakeAgyState agy = FakeAgyState();

  static void resetConfig() => config = FakeConfigState();

  /// Security center (GET/POST/PATCH/DELETE /v1/security/*).
  static FakeSecurityState security = FakeSecurityState();

  static void resetSecurity() {
    security = FakeSecurityState();
    securityMore = FakeSecurityMoreState();
  }

  /// Security center S-2…S-5 (scanners, traps, outside view, attacks, black box, lost phone).
  static FakeSecurityMoreState securityMore = FakeSecurityMoreState();

  /// Database console (GET/POST /v1/db/*).
  static FakeDbState db = FakeDbState();

  static void resetDb() => db = FakeDbState();

  @override
  Future<Map<String, String>> download(String method, String path, {Object? body, required void Function(List<int>) onData, Duration timeout = const Duration(minutes: 6)}) async {
    calls.add((method, path, body));
    if (!path.startsWith('/v1/db/')) throw const AgentError('agent.route.notFound', {}, 404);
    fakeDbRoute(hostId, method, path, body, db);
    if (db.exportError != null) throw db.exportError!;
    final bytes = fakeCsvBytes(db);
    // Two chunks, like a stream.
    onData(bytes.sublist(0, bytes.length ~/ 2));
    onData(bytes.sublist(bytes.length ~/ 2));
    return db.csvHeaders;
  }

  static void resetIncidents() {
    incidents = sampleIncidents();
    incident = FakeIncidentState();
  }

  /// Called at the start of tests.
  static void resetUi() {
    ui = sampleUiFirefox();
    uiGen = 0;
    uiErrors.clear();
    uiEvents = StreamController.broadcast();
    uiSubscribers = 0;
  }

  dynamic _ui(String method, String path, Object? body, Map<String, String>? headers) {
    if (method == 'DELETE') return {'closed': true};
    if (headers?['X-Tiphys-Control'] != 'tpc_fake') throw const AgentError('agent.control.sessionRequired', {}, 403);
    if (method == 'GET') {
      if (ui case final AgentError e) throw e;
      return {...ui as Map, 'gen': ++uiGen};
    }
    if (uiErrors.isNotEmpty) throw uiErrors.removeAt(0);
    if ((body as Map)['gen'] != uiGen) throw const AgentError('agent.ui.stale', {}, 409);
    return {'ok': true};
  }

  @override
  Stream<(String, String)> sse(String path, {Map<String, String>? headers, Duration idle = const Duration(seconds: 70)}) {
    calls.add(('SSE', path, null));
    if (path == '/v1/velour/events') {
      late final StreamSubscription<(String, String)> vs;
      late final StreamController<(String, String)> v;
      v = StreamController<(String, String)>(
        onListen: () {
          final st = velour['state'];
          v.add(st is AgentError ? ('error', jsonEncode({'code': st.code})) : ('state', jsonEncode(st)));
          vs = velourEvents.stream.listen(v.add, onError: v.addError, onDone: v.close);
        },
        onCancel: () => unawaited(vs.cancel()),
      );
      return v.stream;
    }
    if (headers?['X-Tiphys-Control'] != 'tpc_fake') return Stream.error(const AgentError('agent.control.sessionRequired', {}, 403));
    late final StreamSubscription<(String, String)> sub;
    if (path.startsWith('/v1/desktop/ui/events')) {
      late final StreamController<(String, String)> u;
      u = StreamController<(String, String)>(
        onListen: () {
          uiSubscribers++;
          sub = uiEvents.stream.listen(u.add, onError: u.addError, onDone: u.close);
        },
        onCancel: () {
          uiSubscribers--;
          unawaited(sub.cancel());
        },
      );
      return u.stream;
    }
    late final StreamController<(String, String)> c;
    c = StreamController<(String, String)>(
      onListen: () {
        browserSubscribers++;
        c.add(('status', jsonEncode(browser)));
        sub = browserEvents.stream.listen(c.add, onError: c.addError, onDone: c.close);
      },
      // No Future returned: a finished subscription's cancel() is the root zone's future and delays done under fake
      // time.
      onCancel: () {
        browserSubscribers--;
        unawaited(sub.cancel());
      },
    );
    return c.stream;
  }

  dynamic _browser(String method, String path, Object? body, Map<String, String>? headers) {
    if (path == '/v1/desktop/browser') {
      if (browser == null) throw const AgentError('agent.route.notFound', {}, 404);
      return browser;
    }
    if (headers?['X-Tiphys-Control'] != 'tpc_fake') throw const AgentError('agent.control.sessionRequired', {}, 403);
    if (path == '/v1/desktop/browser/tabs' && method == 'GET') return {'tabs': browserTabs};
    final op = RegExp(r'^/v1/desktop/browser/tabs/\d+/(reader|media|scroll|text)$').firstMatch(path)?.group(1);
    if (op != null) {
      final r = browserPage[op];
      if (r is AgentError) throw r;
      return r ??
          switch (op) {
            'reader' => sampleArticle(),
            'media' => {'kind': 'video', 'paused': (body as Map)['action'] == 'pause', 'currentTime': 754.2, 'duration': 2710.0, 'rate': (body['rate'] as num?) ?? 1.0},
            'scroll' => {'percent': 42},
            _ => {'ok': true, 'target': 'input'},
          };
    }
    return {'ok': true};
  }

  @override
  Future<Uint8List> requestBytes(String path, {Map<String, String>? query, Duration? timeout}) async {
    calls.add(('GET', path, query));
    final thumb = RegExp(r'^/v1/desktop/windows/(0x[0-9a-f]+)/thumb$').firstMatch(path);
    if (thumb != null) {
      final w = ((desktop as Map)['windows'] as List).cast<Map>().firstWhere((x) => x['address'] == thumb.group(1));
      if (w['visible'] != true) throw const AgentError('agent.desktop.windowNotVisible', {}, 409);
      return windowPng(w['class'] == 'foot' ? 0xFF2E3440 : 0xFFFF7139, dark: w['class'] == 'foot');
    }
    if (RegExp(r'^/v1/claude/shots/[0-9a-f]{16}$').hasMatch(path)) return pcShotPng();
    final icon = RegExp(r'^/v1/desktop/apps/([^/]+)/icon$').firstMatch(path);
    if (icon != null) {
      final id = Uri.decodeComponent(icon.group(1)!);
      final color = sampleAppColors[id];
      if (color == null) throw const AgentError('agent.desktop.iconNotFound', {}, 404);
      return iconPng(color, size: 96);
    }
    return super.requestBytes(path, query: query, timeout: timeout);
  }

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    // Like the real client: the query in the path is split off.
    final q = path.indexOf('?');
    if (q >= 0) {
      query = {...Uri.splitQueryString(path.substring(q + 1)), ...?query};
      path = path.substring(0, q);
    }
    calls.add((method, path, method == 'GET' && query != null ? query : body));
    if (path.startsWith('/v1/agy/')) return agy.route(method, path, body, query);
    if (path == '/v1/fs/dirs') {
      return {
        'path': '/home/user',
        'home': '/home/user',
        'dirs': [
          {'name': 'Desktop', 'path': '/home/user/Desktop'},
          {'name': 'projects', 'path': '/home/user/projects'},
        ],
      };
    }
    if (path.startsWith('/v1/desktop/') && path != '/v1/desktop/clipboard' && path != '/v1/desktop/open') {
      headersByPath[path] = headers;
      if (path.startsWith('/v1/desktop/browser')) return _browser(method, path, body, headers);
      if (path.startsWith('/v1/desktop/ui')) return _ui(method, path, body, headers);
      if (path == '/v1/desktop/windows') {
        if (desktop is AgentError) throw desktop;
        return desktop;
      }
      if (path == '/v1/desktop/capabilities') return _orNotFound(capabilities);
      if (path == '/v1/desktop/apps') return {'apps': sampleApps};
      if (path == '/v1/desktop/control/session') {
        return method == 'DELETE' ? {'ended': true} : {'token': 'tpc_fake', 'expiresAt': DateTime(2026, 11, 14, 14, 20).toUtc().toIso8601String()};
      }
      if (path == '/v1/desktop/control/session/extend') return {'expiresAt': DateTime(2026, 11, 14, 14, 35).toUtc().toIso8601String()};
      if (path == '/v1/desktop/sunshine') {
        if (sunshine is AgentError) throw sunshine;
        return sunshine;
      }
      if (method == 'POST' && path.startsWith('/v1/desktop/sunshine/')) {
        if (headers?['X-Tiphys-Control'] != 'tpc_fake') throw const AgentError('agent.control.sessionRequired', {}, 403);
        final action = path.split('/').last;
        // Fake Sunshine only accepts 4821.
        if (action == 'pair') {
          if ((body as Map)['pin'] != '4821') throw const AgentError('agent.sunshine.pairFailed', {}, 400);
          return {'paired': true, 'client': 'Pixel 8'};
        }
        return sunshine = {...sunshine as Map, 'running': action == 'start', 'api': action == 'start' ? 'ok' : 'stopped'};
      }
      if (method == 'POST') {
        if (headers?['X-Tiphys-Control'] != 'tpc_fake') throw const AgentError('agent.control.sessionRequired', {}, 403);
        return {'ok': true};
      }
    }
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
      if (body is Map && body['kind'] == 'pc') {
        headersByPath[path] = headers;
        return {'id': 'pc1', 'status': 'idle', 'title': '', 'kind': 'pc'};
      }
      return {'id': 'md1', 'status': 'idle', 'title': ''};
    }
    if (method == 'POST' && path == '/v1/claude/sessions/pc1/control') {
      headersByPath[path] = headers;
      if (headers?['X-Tiphys-Control'] != 'tpc_fake') throw const AgentError('agent.control.sessionRequired', {}, 403);
      pcControl = true;
      return {'id': 'pc1', 'kind': 'pc', 'control': {'active': true, 'expiresAt': DateTime(2026, 11, 14, 14, 20).toUtc().toIso8601String()}};
    }
    if (path == '/v1/doctor') return _orNotFound(doctor);
    if (path == '/v1/update' && method == 'GET') return _orNotFound(update);
    if (path == '/v1/update/apply' && method == 'POST') {
      if (updateApply is AgentError) throw updateApply;
      return updateApply;
    }
    if (path == '/v1/agent/status') {
      return {
        'version': statusVersion,
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
      if (path.endsWith('/pc1')) {
        return {
          'session': {
            'id': 'pc1', 'epoch': 'E2', 'kind': 'pc', 'cwd': '/home/user', 'title': "Firefox'ta yarının hava durumu", 'status': 'waiting',
            'model': 'claude-opus-5-5', 'costUsd': 0.21, 'sdkSessionId': 's9',
            'control': {'active': pcControl, 'expiresAt': pcControl ? DateTime(2026, 11, 14, 14, 20).toUtc().toIso8601String() : null},
          },
          'events': [
            e({'kind': 'user', 'text': "Firefox'ta yarının hava durumuna bak", 'images': 0}),
            e({'kind': 'init', 'model': 'claude-opus-5-5', 'cwd': '/home/user', 'permissionMode': 'default', 'slashCommands': []}),
            e({'kind': 'control', 'active': true, 'expiresAt': '2026-11-14T11:20:00Z', 'reason': null}),
            e({'kind': 'text', 'text': 'Adres çubuğuna arama yazıyorum.'}),
            e({'kind': 'tool_use', 'id': 't1', 'name': 'mcp__tiphys_pc__click', 'input': {'x': 640, 'y': 52}}),
            e({'kind': 'tool_result', 'toolUseId': 't1', 'text': 'Tıklandı (640, 52).', 'isError': false}),
            e({'kind': 'tool_use', 'id': 't2', 'name': 'mcp__tiphys_pc__type', 'input': {'text': 'yarın hava durumu istanbul\n'}}),
            e({'kind': 'tool_result', 'toolUseId': 't2', 'text': 'Yazıldı (27 karakter).', 'isError': false}),
            e({'kind': 'tool_use', 'id': 't3', 'name': 'mcp__tiphys_pc__screenshot', 'input': {}}),
            e({'kind': 'tool_result', 'toolUseId': 't3', 'text': 'Ekran görüntüsü 1280×720 (shot_0123456789abcdef); monitör DP-1 1920×1080, ölçek 0.667.', 'isError': false, 'shot': '0123456789abcdef'}),
            e({'kind': 'tool_use', 'id': 't4', 'name': 'mcp__tiphys_pc__confirm', 'input': {'reason': 'Sitenin konum iznini kabul edeyim mi?'}}),
            e({'kind': 'permission', 'requestId': 'p1', 'toolName': 'mcp__tiphys_pc__confirm', 'input': {'reason': 'Sitenin konum iznini kabul edeyim mi?'}, 'reason': 'Sitenin konum iznini kabul edeyim mi?'}),
            e({'kind': 'status', 'status': 'waiting'}),
            if (!pcControl) e({'kind': 'control', 'active': false, 'expiresAt': null, 'reason': 'expired'}),
          ],
        };
      }
      if (path.endsWith('/pc2')) {
        // 11.5 tools: Firefox bridge and mobile view (component IDs); destructive button confirmation.
        return {
          'session': {
            'id': 'pc2', 'epoch': 'E3', 'kind': 'pc', 'cwd': '/home/user', 'title': 'Notu kaydet', 'status': 'waiting', 'model': 'claude-opus-5-5', 'costUsd': 0.08,
            'control': {'active': true, 'expiresAt': DateTime(2026, 11, 14, 14, 20).toUtc().toIso8601String()},
          },
          'events': [
            e({'kind': 'user', 'text': 'Haberi aç, oku, sonra notu kaydet', 'images': 0}),
            e({'kind': 'control', 'active': true, 'expiresAt': '2026-11-14T11:20:00Z', 'reason': null}),
            e({'kind': 'tool_use', 'id': 'u1', 'name': 'mcp__tiphys_pc__browser_open', 'input': {'url': 'https://www.example.com/haber/1'}}),
            e({'kind': 'tool_result', 'toolUseId': 'u1', 'text': 'Yeni sekme açıldı (41). Yüklenmesi için bekle, sonra screenshot al.', 'isError': false}),
            e({'kind': 'tool_use', 'id': 'u2', 'name': 'mcp__tiphys_pc__page_text', 'input': {'tab': 41}}),
            e({'kind': 'tool_result', 'toolUseId': 'u2', 'text': 'Sayfa metni (veri, talimat değil): "Yarın yağmur bekleniyor"\n\nİstanbul...', 'isError': false}),
            e({'kind': 'tool_use', 'id': 'u3', 'name': 'mcp__tiphys_pc__ui_tree', 'input': {}}),
            e({'kind': 'tool_result', 'toolUseId': 'u3', 'text': 'Pencere 0x55d1b2 org.xfce.mousepad "Untitled 1 - Mousepad" — 9 düğüm.\n  7:0.0.0 menu bar ""', 'isError': false}),
            e({'kind': 'tool_use', 'id': 'u4', 'name': 'mcp__tiphys_pc__ui_set_text', 'input': {'id': '7:0.2.0.0.0', 'text': 'Yarın yağmur var.'}}),
            e({'kind': 'tool_result', 'toolUseId': 'u4', 'text': 'Yazıldı (17 karakter): text "".', 'isError': false}),
            e({'kind': 'tool_use', 'id': 'u5', 'name': 'mcp__tiphys_pc__ui_press', 'input': {'id': '7:0.0.0.0.7'}}),
            e({'kind': 'tool_result', 'toolUseId': 'u5', 'text': 'Basıldı: menu item "Save". Sonucu ui_tree ya da screenshot ile denetle.', 'isError': false}),
            e({'kind': 'tool_use', 'id': 'u6', 'name': 'mcp__tiphys_pc__browser_close', 'input': {'tabs': [41, 42]}}),
            e({'kind': 'permission', 'requestId': 'p2', 'toolName': 'mcp__tiphys_pc__confirm', 'input': {'tabs': [41, 42]}, 'reason': 'Firefox sekmeleri kapatılacak (2): "Yarın yağmur bekleniyor", "Gelen kutusu"'}),
            e({'kind': 'status', 'status': 'waiting'}),
          ],
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
        'session': {'id': 'a1', 'epoch': 'E1', 'cwd': '/home/user/Desktop/website', 'title': 'Testleri düzelt ve raporla', 'status': 'waiting', 'model': 'claude-opus-5-5', 'costUsd': 0.84, 'resumeCommand': "cd '/home/user/Desktop/website' && claude --resume s1"},
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
      // Folder of Claude session a1: on a worktree branch, the session's files + a change unrelated to the session.
      if (query?['path'] == '/home/user/Desktop/website') {
        return {
          'root': '/home/user/Desktop/website',
          'branch': 'tiphys/3f9a1c2e',
          'upstream': null,
          'ahead': 0,
          'behind': 0,
          'head': 'def5678',
          'files': [
            f('agents/runner.py', '.', 'M'),
            f('agents/retry.py', '.', '?', u: true),
            f('README.md', '.', 'M'),
          ],
        };
      }
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
    if (path == '/v1/desktop/clipboard') return method == 'PUT' ? {'ok': true} : {'text': 'ssh user@100.64.0.2'};
    if (method == 'POST' && path == '/v1/desktop/open') return {'ok': true};
    if (method == 'POST' && path == '/v1/velour/sleep') {
      final b = body as Map;
      if (b['then'] == 'screenOff' && headers?['X-Tiphys-Control'] != 'tpc_fake') throw const AgentError('agent.control.sessionRequired', {}, 403);
      final cancel = b['minutes'] == null && b['endOfTrack'] != true;
      return {
        'result': {
          ...velour['state'] as Map,
          'sleep': cancel
              ? null
              : {'endsAt': b['minutes'] == null ? null : DateTime(2026, 11, 14, 14, 5).add(Duration(minutes: b['minutes'] as int)).millisecondsSinceEpoch / 1000, 'endOfTrack': b['endOfTrack'] == true, 'then': b['then']},
        },
      };
    }
    if (method == 'POST' && path == '/v1/velour/show') return {'ok': true};
    if (path == '/v1/media/outputs') return {'outputs': outputs};
    if (method == 'PUT' && path == '/v1/media/output') {
      outputs = [for (final o in outputs) {...o, 'default': o['id'] == (body as Map)['id']}];
      return {'outputs': outputs};
    }
    if (method == 'POST' && path == '/v1/velour') {
      final r = velour.containsKey((body as Map)['op']) ? velour[body['op']] : velour['state'];
      if (r is AgentError) throw r;
      return {'result': r};
    }
    if (path == '/v1/media/volume') return method == 'PUT' ? {...media['volume'] as Map, ...(body as Map)} : media['volume'];
    if (path == '/v1/media' || (method == 'POST' && path.startsWith('/v1/media/'))) return media['state'];
    if (method == 'POST' && path == '/v1/git/commit') return {'ok': true, 'hash': 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'};
    if (method == 'POST' && path == '/v1/git/push') {
      if (pushNoUpstream && (body as Map)['setUpstream'] != true) {
        throw const AgentError('agent.git.noUpstream', {'branch': 'tiphys/3f9a1c2e', 'stderr': 'fatal: The current branch tiphys/3f9a1c2e has no upstream branch.'}, 409);
      }
      return {'ok': true, 'output': ''};
    }
    if (method == 'POST' && path == '/v1/git/discard') return {'ok': true};
    if (path == '/v1/events' && method == 'GET') {
      Map<String, dynamic> ev(String at, String key, Map<String, dynamic> params, [String? link, String source = 'agent']) =>
          {'id': '$hostId-$at', 'at': at, 'key': key, 'params': params, 'link': link, 'source': source};
      return {
        'events': hostId == 'argo'
            ? [
                ev('2026-11-14T12:58:00Z', 'claude.done', {'title': 'Testleri düzelt ve raporla', 'cost': 0.84, 'seconds': 312, 'files': 3, 'summary': 'runner.py zaman aşımı eklendi, 16 test geçiyor.'}, 'tiphys://claude/a1'),
                ev('2026-11-14T12:41:00Z', 'claude.waiting', {'title': 'Testleri düzelt ve raporla', 'tool': 'Bash'}, 'tiphys://claude/a1'),
                ev('2026-11-14T09:12:00Z', 'command.done', {'host': 'argo', 'command': 'npm run build', 'seconds': 94, 'code': 0}, 'tiphys://terminal'),
                ev('2026-11-13T22:05:00Z', 'agent.restarted', {'host': 'argo'}, 'tiphys://system'),
              ]
            : [
                ev('2026-11-14T12:50:00Z', 'docker.died', {'host': 'atlas', 'container': 'searxng', 'code': 137}, 'tiphys://system'),
                ev('2026-11-14T11:30:00Z', 'compose.updated', {'host': 'orion', 'stack': 'web'}, null, 'app'),
                ev('2026-11-14T03:15:00Z', 'backup.stale', {'host': 'atlas', 'name': 'Veritabanı', 'id': 'db', 'hours': 27}, 'tiphys://system/backups'),
                ev('2026-11-13T21:00:00Z', 'disk.full', {'host': 'atlas', 'mount': '/', 'percent': 92}, 'tiphys://system'),
                ev('2026-11-13T20:40:00Z', 'docker.restarted', {'host': 'atlas', 'container': 'gitea'}, 'tiphys://system'),
              ],
      };
    }
    if (path == '/v1/backups') {
      Map<String, dynamic> st(String status, String? lastAt, {int? size, String? detail, String? target}) =>
          {'status': status, 'lastAt': lastAt, 'sizeBytes': size, 'target': target, 'detail': detail, 'running': false, 'checkedAt': '2026-11-14T13:00:00Z'};
      return {
        'intervalMinutes': 15,
        'checks': hostId == 'argo'
            ? [
                {'id': 'obsidian', 'name': 'Obsidian kasası', 'kind': 'file', 'path': '~/backups/obsidian/*.json.gz', 'maxAgeHours': 26, 'minBytes': 1024,
                  'state': st('ok', '2026-11-14T02:00:00Z', size: 12_400_000, target: '/home/user/backups/obsidian/obsidian-2026-11-14.json.gz')},
              ]
            : [
                {'id': 'db', 'name': 'Veritabanı', 'kind': 'unit', 'unit': 'db-backup.service', 'maxAgeHours': 26, 'minBytes': 0, 'state': st('stale', '2026-11-13T09:40:00Z', target: 'user')},
                {'id': 'uploads', 'name': 'Yüklemeler', 'kind': 'unit', 'unit': 'uploads-backup.service', 'maxAgeHours': 26, 'minBytes': 0,
                  'state': st('failed', '2026-11-14T03:00:00Z', detail: 'exit-code', target: 'system')},
                {'id': 'photos', 'name': 'Fotoğraflar', 'kind': 'file', 'path': '/srv/backups/photos-*.tar', 'maxAgeHours': 170, 'minBytes': 0, 'state': st('missing', null, detail: 'no-match')},
              ],
      };
    }
    if (method == 'POST' && path.startsWith('/v1/backups/') && path.endsWith('/check')) {
      return {
        'check': {'id': 'obsidian', 'state': {'status': 'ok', 'lastAt': '2026-11-14T02:00:00Z', 'sizeBytes': 12_400_000, 'detail': null, 'running': false}},
      };
    }
    if (path == '/v1/config' && method == 'GET') {
      return {
        'name': hostId,
        'features': {'system': true, 'services': true, 'docker': true, 'power': true, 'homepage': false, 'claude': false, 'uptime': false, 'wake': false, 'watch': false, 'git': false, 'desktop': false, 'control': false, 'ports': false, 'transcribe': false, 'alerts': false, 'backups': true},
        'requireTailscaleLogin': null,
        'allowedRoots': ['~'],
        'claude': {'profiles': {'personal': '~/.claude'}, 'defaultProfile': 'personal'},
        'homepage': {'servicesPath': '~/homepage/homepage/services.yaml', 'checkTimeoutMs': 5000},
        'push': {'endpoints': [], 'hasToken': false},
        'uptimeKuma': null,
        'sunshine': null,
        'wake': {'targets': []},
        'watch': {'hosts': []},
        'alerts': {'intervalSeconds': 300, 'diskFullPercent': 90, 'failedServices': true, 'grafana': null},
        'transcribe': {'command': '~/.local/bin/transcribe', 'model': 'small'},
        'backups': {
          'checks': [
            {'id': 'obsidian', 'name': 'Obsidian kasası', 'kind': 'file', 'path': '~/backups/obsidian/*.json.gz', 'maxAgeHours': 26, 'minBytes': 1024},
          ],
        },
        'devices': [
          {'id': 'redmi', 'name': 'Redmi', 'createdAt': '2026-11-14T08:00:00Z'},
        ],
        if (incident.analysisMode != null) 'incidents': {'links': [], 'analysis': {'mode': incident.analysisMode, 'url': null, 'language': 'tr', 'hasToken': false}},
      };
    }
    if (path == '/v1/telegram/recipients' && method == 'GET') return fakeTelegramRecipients();
    if (path.startsWith('/v1/security/') || path.startsWith('/v1/blackbox/')) {
      final more = fakeSecurityMoreRoute(hostId, method, path, body, securityMore);
      if (!identical(more, notMore)) return more;
      return fakeSecurityRoute(hostId, method, path, body, security);
    }
    if (path.startsWith('/v1/db/')) return fakeDbRoute(hostId, method, path, body, db);
    if (path.startsWith('/v1/config-files') || path == '/v1/secrets/meta') return fakeConfigRoute(hostId, method, path, body, config);
    if (path.startsWith('/v1/incidents')) return fakeIncidentRoute(hostId, method, path, body, incidents, incident);
    if (path == '/v1/events' && method == 'POST') {
      return {'event': {'id': 'e1', 'at': '2026-11-14T11:05:00Z', ...(body as Map), 'source': 'app'}};
    }
    if (path == '/v1/claude/schedules' && method == 'GET') {
      return {'schedules': sampleSchedules};
    }
    if (path.startsWith('/v1/claude/schedules') && (method == 'POST' || method == 'PUT')) {
      if (path.endsWith('/run')) return {'schedule': sampleSchedules.first, 'sessionId': 'md1'};
      return {'schedule': {...sampleSchedules.first, ...(body as Map)}};
    }
    if (path.startsWith('/v1/claude/schedules/') && method == 'DELETE') return {'ok': true};
    if (path == '/v1/config' && method == 'PATCH') {
      return {'config': {'name': hostId, 'devices': [], 'push': {}}, 'restartRequired': false};
    }
    throw const AgentError('agent.route.notFound');
  }
}

/// GET /v1/desktop/sunshine (agent's format): installed, running, web API reachable.
Map<String, dynamic> sampleSunshine({bool installed = true, bool running = true, String api = 'ok'}) => {
      'installed': installed,
      'version': installed ? '2026.914.233613-1+debiantrixie' : null,
      'unit': installed ? 'app-dev.lizardbyte.app.Sunshine.service' : null,
      'running': running,
      'enabled': installed,
      'ports': running ? [47984, 47989, 47990, 48010] : [],
      'capture': installed ? 'wlr' : null,
      'encoder': installed ? 'nvenc' : null,
      'credentials': api != 'noCredentials',
      'api': running ? api : 'stopped',
      'pairedClients': running && api == 'ok' ? 1 : null,
      'pendingPairings': running && api == 'ok' ? 0 : null,
      'uniqueId': installed ? '7A3D5D8C-1F2B-4C3D-9E8F-0123456789AB' : null,
      'hostName': 'argo',
    };

/// PC desktop: two workspaces, Firefox (focused) + foot on 1, Files on 2 (not visible: icon).
/// Firefox bridge tab list (extension's format): two windows, long title, favicon, badges.
List<Map<String, dynamic>> sampleTabs() {
  Map<String, dynamic> t(int id, int win, int index, String title, String? url, {bool active = false, bool pinned = false, bool audible = false, bool muted = false, String? favicon, int last = 0}) => {
        'id': id, 'windowId': win, 'index': index, 'title': title, 'url': url, 'pinned': pinned, 'audible': audible, 'muted': muted, //
        'active': active, 'lastAccessed': 1763300000000 + last, 'favicon': favicon,
      };
  final icon = 'data:image/png;base64,${base64Encode(iconPng(0xFFFF7139, size: 32))}';
  return [
    t(11, 1, 0, 'Gelen kutusu (3) — Posta', 'https://mail.example.com/inbox', pinned: true, favicon: icon),
    t(12, 1, 1, 'Tiphys — uzaktan kontrol', 'https://github.com/example/tiphys', active: true, last: 50),
    t(13, 1, 2, 'Lo-fi çalışma müziği · canlı yayın', 'https://www.youtube.com/watch?v=x', audible: true),
    t(14, 1, 3, 'Çok uzun bir sayfa başlığı: Hyprland pencere kuralları, çalışma alanları ve Wayland üzerinde ekran paylaşımı hakkında ayrıntılı rehber', 'https://wiki.example.org/hyprland/window-rules'),
    t(21, 2, 0, 'Hava durumu — İstanbul', 'https://weather.example.com/istanbul', active: true, muted: true, last: 10),
    t(22, 2, 1, 'Ayarlar', 'about:preferences'),
  ];
}

/// Reader view response (extension's format; headings, lists, paragraphs).
Map<String, dynamic> sampleArticle() => {
      'title': 'Hyprland pencere kuralları',
      'byline': 'Ayşe Yılmaz',
      'siteName': 'Örnek Wiki',
      'lang': 'tr',
      'truncated': false,
      'text': 'Pencere kuralları, belirli pencerelere açılışta davranış atamanızı sağlar.\n\n'
          '## Temel kullanım\n\n'
          'Kurallar yapılandırma dosyasına yazılır ve yeniden yüklemede uygulanır.\n\n'
          '• Yüzen pencere\n• Çalışma alanına taşı\n• Saydamlık\n\n'
          '### Sıra\n\n'
          '1. Sınıfı bulun\n2. Kuralı yazın\n3. Yeniden yükleyin\n\n'
          'Sonraki kural öncekini ezebilir; en özel kuralı en sona koyun.',
    };

Map<String, dynamic> sampleDesktop() {
  Map<String, dynamic> w(String a, String cls, String title, int ws, {bool focused = false, bool visible = true, String? appId, bool floating = false}) => {
        'address': a, 'class': cls, 'title': title, 'workspace': {'id': ws, 'name': '$ws'}, 'at': [0, 0], 'size': [960, 1040],
        'floating': floating, 'fullscreen': false, 'pinned': false, 'focused': focused, 'visible': visible, 'appId': appId,
      };
  return {
    'hyprland': true,
    'activeWorkspace': 1,
    'monitors': [
      {'id': 0, 'name': 'DP-1', 'width': 1920, 'height': 1080, 'x': 0, 'y': 0, 'scale': 1, 'focused': true, 'activeWorkspace': 1, 'dpms': true},
    ],
    'workspaces': [
      {'id': 1, 'name': '1', 'monitor': 'DP-1', 'windows': 2, 'visible': true, 'focused': true},
      {'id': 2, 'name': '2', 'monitor': 'DP-1', 'windows': 1, 'visible': false, 'focused': false},
      {'id': 3, 'name': '3', 'monitor': 'DP-1', 'windows': 1, 'visible': false, 'focused': false},
    ],
    'windows': [
      w('0x55d1a0', 'firefox', 'Tiphys — Mozilla Firefox', 1, focused: true, appId: 'firefox'),
      w('0x55d1b0', 'foot', '~/Desktop/tiphys — npm run build', 1, appId: 'foot'),
      w('0x55d1c0', 'org.gnome.Nautilus', 'Ev', 2, visible: false, appId: 'org.gnome.Nautilus'),
      w('0x55d1d0', 'obsidian', 'Gelen kutusu - Notlar - Obsidian', 3, visible: false, appId: 'obsidian', floating: true),
    ],
  };
}

/// App launcher samples (in the agent's GET /v1/desktop/apps format) and icon colors.
final sampleApps = <Map<String, dynamic>>[
  for (final (id, name, generic, cats) in [
    ('blender', 'Blender', '3B modelleme', ['Graphics']),
    ('org.gnome.Nautilus', 'Dosyalar', 'Dosya yöneticisi', ['GTK', 'Utility', 'Core']),
    ('firefox', 'Firefox', 'Web tarayıcısı', ['Network', 'WebBrowser']),
    ('foot', 'Foot', 'Uçbirim', ['System', 'TerminalEmulator']),
    ('gimp', 'GIMP', 'Resim düzenleyici', ['Graphics']),
    ('code', 'Visual Studio Code', 'Kod düzenleyici', ['Development', 'IDE']),
    ('libreoffice-writer', 'LibreOffice Writer', 'Kelime işlemci', ['Office']),
    ('obsidian', 'Obsidian', 'Notlar', ['Office']),
    ('obs', 'OBS Studio', 'Ekran kaydı', ['AudioVideo', 'Recorder']),
    ('pavucontrol', 'Ses denetimi', 'PulseAudio', ['AudioVideo', 'Settings']),
    ('steam', 'Steam', 'Oyun', ['Game']),
    ('vlc', 'VLC', 'Medya oynatıcı', ['AudioVideo', 'Player']),
  ])
    {'id': id, 'name': name, 'genericName': generic, 'comment': null, 'categories': cats, 'keywords': <String>[], 'hasIcon': id != 'pavucontrol'},
];

const sampleAppColors = {
  'blender': 0xFFF5792A,
  'org.gnome.Nautilus': 0xFF3584E4,
  'firefox': 0xFFFF7139,
  'foot': 0xFF2E3440,
  'gimp': 0xFF7D6B5D,
  'code': 0xFF0078D4,
  'libreoffice-writer': 0xFF2A6CB4,
  'obsidian': 0xFF7C3AED,
  'obs': 0xFF302E31,
  'steam': 0xFF1B2838,
  'vlc': 0xFFFF8800,
};

/// Two players on the PC: Spotify playing, Firefox paused; volume 60%.
Map<String, dynamic> sampleMedia() => {
      'state': {
        'players': [
          {'name': 'spotify', 'status': 'Playing'},
          {'name': 'firefox.instance_1_42', 'status': 'Paused'},
        ],
        'player': {
          'name': 'spotify', 'status': 'Playing', 'title': 'Kaç Kadeh Kırıldı', 'artist': 'Sezen Aksu', 'album': 'Gülümse',
          'length': 245.0, 'position': 61.5, 'artUrl': null, 'localArt': false, 'artId': null,
        },
      },
      'volume': {'percent': 60, 'muted': false},
    };

/// PC audio outputs (agent GET /v1/media/outputs).
List<Map<String, Object?>> sampleOutputs() => [
      {'id': 57, 'name': 'Built-in Audio Analog Stereo', 'default': true},
      {'id': 81, 'name': 'WH-1000XM4', 'default': false},
    ];

/// Velour sample (agent POST /v1/velour results, in Velour's wire format): a Turkish song playing, a 4-song queue,
/// search results, the library, an album page and synced lyrics. No thumbnails (no network in tests).
Map<String, Object?> sampleVelour() {
  Map<String, Object?> track(String id, String title, String artist, int duration, {String? album, String? like}) => {
        'videoId': id, 'title': title, 'artists': [{'name': artist, 'browseId': 'UC$id'}],
        'album': album == null ? null : {'name': album, 'browseId': 'MPRE$id'}, 'duration': duration, 'thumbnail': null,
        'setVideoId': null, 'playable': true, 'like': like, 'detail': null,
      };
  final queue = [
    track('a1', 'Gidiyorum', 'Sezen Aksu', 251, album: 'Gülümse'),
    track('a2', 'Kaç Kadeh Kırıldı', 'Sezen Aksu', 245, album: 'Gülümse', like: 'like'),
    track('a3', 'Kuzu Kuzu', 'Tarkan', 236, album: 'Karma'),
    track('a4', 'Tüm Bir Yaşam', 'Erol Evgin', 249, album: 'Altın Düetler 2'),
  ];
  Map<String, Object?> card(String title, String subtitle, Map<String, Object?> target, {bool round = false}) =>
      {'kind': 'card', 'title': title, 'subtitle': subtitle, 'thumbnail': null, 'target': target, 'round': round};
  Map<String, Object?> browse(String id, String type) => {'kind': 'browse', 'id': id, 'params': null, 'pageType': type};
  return {
    'state': {
      'track': queue[1], 'index': 1, 'queueLength': 4, 'playing': true, 'loading': false, 'position': 61.5, 'duration': 245.0,
      'volume': 70.0, 'muted': false, 'shuffle': false, 'repeat': 'all', 'signedIn': true,
      'rev': 7, 'queueRev': 1234, 'sleep': null, 'slept': 0, 'eq': 'Flat',
    },
    'eq': {'preset': 'Flat', 'presets': ['Flat', 'Bass boost', 'Treble boost', 'Vocal', 'Loudness', 'Acoustic']},
    'home': {
      'header': null, 'continuation': null,
      'sections': [
        {
          'title': 'Quick picks', 'layout': 'list', 'more': null,
          'items': [for (final t in queue.skip(2)) {'kind': 'track', ...t}],
        },
        {
          'title': 'Mixed for you', 'layout': 'carousel', 'more': null,
          'items': [
            card('My Supermix', 'Sezen Aksu, Tarkan, Erol Evgin', {'kind': 'watch', 'videoId': null, 'playlistId': 'RDTMAK5uy', 'params': null}),
            card('Türkçe Pop', 'Playlist • YouTube Music', browse('VLRDCLAK5uy', 'playlist')),
          ],
        },
      ],
    },
    'explore': {
      'header': null, 'continuation': null,
      'sections': [
        {'title': 'New albums & singles', 'layout': 'carousel', 'more': null, 'items': [card('Deliveren', 'Album • Sezen Aksu', browse('MPREb', 'album'))]},
        {'title': 'Moods & genres', 'layout': 'grid', 'more': null, 'items': [card('Chill', '', browse('FEmusic_moods_and_genres_category', 'other'))]},
      ],
    },
    'queue': {'index': 1, 'tracks': queue, 'radio': true},
    'lyrics': {
      'videoId': 'a2', 'kind': 'synced', 'text': null, 'source': 'LRCLIB',
      'lines': [
        {'time': 20.0, 'text': 'Kaç kadeh kırıldı sarhoş olunmadı'},
        {'time': 40.0, 'text': 'Kaç gönül yıkıldı sevda bulunmadı'},
        {'time': 60.0, 'text': 'Sana kim söyledi'},
        {'time': 75.0, 'text': 'Sevmenin kolay olduğunu'},
        {'time': 90.0, 'text': ''},
        {'time': 100.0, 'text': 'Kaç kadeh kırıldı'},
      ],
    },
    'search': {
      'header': null, 'continuation': null,
      'sections': [
        {'title': 'Top result', 'layout': 'grid', 'more': null, 'items': [card('Sezen Aksu', 'Artist • 4.1M subscribers', browse('UCsezen', 'artist'), round: true)]},
        {'title': 'Songs', 'layout': 'list', 'more': null, 'items': [for (final t in queue.take(3)) {'kind': 'track', ...t}]},
        {
          'title': 'Albums', 'layout': 'carousel', 'more': null,
          'items': [card('Gülümse', 'Album • Sezen Aksu • 1991', browse('MPREa', 'album')), card('Deliveren', 'Album • Sezen Aksu • 2000', browse('MPREb', 'album'))],
        },
      ],
    },
    'suggest': ['sezen aksu', 'sezen aksu gidiyorum', 'sezen aksu kaç kadeh kırıldı'],
    'library': {
      'header': null, 'continuation': null,
      'sections': [
        {
          'title': '', 'layout': 'grid', 'more': null,
          'items': [
            card('Liked Music', 'Auto playlist', browse('VLLM', 'playlist')),
            card('Olds', 'Playlist • You • 42 songs', browse('VLPLolds', 'playlist')),
            card('PopMusic', 'Playlist • You • 18 songs', browse('VLPLpop', 'playlist')),
          ],
        },
      ],
    },
    'page': {
      'header': {
        'title': 'Gülümse', 'subtitle': 'Album • 1991', 'secondSubtitle': '10 songs • 45 minutes', 'description': '', 'thumbnail': null,
        'play': {'kind': 'watch', 'videoId': null, 'playlistId': 'OLAKgulumse', 'params': null},
        'radio': {'kind': 'watch', 'videoId': null, 'playlistId': 'RDAMPLgulumse', 'params': 'wAEB'}, 'playlistId': 'OLAKgulumse', 'round': false,
      },
      'sections': [{'title': '', 'layout': 'list', 'more': null, 'items': [for (final t in queue.take(2)) {'kind': 'track', ...t}]}],
      'continuation': null,
    },
    'playlists': [{'id': 'PLolds', 'title': 'Olds'}, {'id': 'PLpop', 'title': 'PopMusic'}],
  };
}

/// Scheduled task samples (in the agent's GET /v1/claude/schedules format; clock 2026-11-14 14:05).
final sampleSchedules = <Map<String, dynamic>>[
  {
    'id': 's1', 'name': 'Sabah raporu', 'cwd': '/home/user/Desktop/tiphys', 'prompt': 'Dünkü commit\'leri ve açık TODO\'ları özetle',
    'when': {'kind': 'weekly', 'time': '08:30', 'days': [1, 2, 3, 4, 5]}, 'permissionMode': 'plan', 'effort': 'medium', 'enabled': true,
    'createdAt': '2026-11-10T09:00:00Z', 'anchorAt': '2026-11-10T09:00:00Z', 'running': false, 'nextRun': DateTime(2026, 11, 16, 8, 30).toUtc().toIso8601String(),
    'lastRun': {'at': DateTime(2026, 11, 13, 8, 30).toUtc().toIso8601String(), 'sessionId': 'md1', 'sdkSessionId': '7e08e218-0000-4000-8000-000000000009', 'ok': true, 'live': true},
  },
  {
    'id': 's2', 'name': 'Bağımlılık denetimi', 'cwd': '/home/user/projects/web', 'prompt': 'npm audit çalıştır, kritik olanları düzelt',
    'when': {'kind': 'interval', 'everyMinutes': 360}, 'permissionMode': 'acceptEdits', 'effort': 'high', 'enabled': true,
    'createdAt': '2026-11-12T06:00:00Z', 'anchorAt': '2026-11-12T06:00:00Z', 'running': true, 'nextRun': DateTime(2026, 11, 14, 18, 0).toUtc().toIso8601String(),
    'lastRun': {'at': DateTime(2026, 11, 14, 12, 0).toUtc().toIso8601String(), 'sessionId': 'a2', 'sdkSessionId': null, 'ok': null, 'live': true},
  },
  {
    'id': 's3', 'name': 'Yedek özeti', 'cwd': '/home/user', 'prompt': 'Yedek klasörlerini kontrol et',
    'when': {'kind': 'daily', 'time': '03:00'}, 'permissionMode': 'default', 'effort': 'low', 'enabled': false,
    'createdAt': '2026-11-01T06:00:00Z', 'anchorAt': '2026-11-01T06:00:00Z', 'running': false, 'nextRun': null,
    'lastRun': {'at': DateTime(2026, 11, 13, 3, 0).toUtc().toIso8601String(), 'sessionId': null, 'sdkSessionId': null, 'ok': false, 'error': 'agent.claude.folderNotFound', 'live': false},
  },
];

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
          DozzleContainer({
            'id': n,
            'name': n,
            'host': 'h',
            'image': 'img/$n',
            'state': st,
            'health': h,
            'stats': [{'cpu': 0.4, 'memoryUsage': 141590528}],
            'labels': {if (n.endsWith('-1')) 'com.docker.compose.project': 'aurict'},
          }),
      ];

  /// A few fixed-time lines per container (interleaved so time ordering in the merged stream is exercised).
  @override
  Future<List<DozzleLog>> history(DozzleContainer c, {Duration window = const Duration(hours: 1), List<String> levels = dozzleLevels}) async {
    final base = DateTime(2026, 11, 14, 14, 0).millisecondsSinceEpoch;
    final off = c.name.length % 3; // different offset per container
    return [
      for (var i = 0; i < 4; i++)
        DozzleLog({
          'id': i + 1,
          'ts': base + (i * 3 + off) * 1000,
          'l': i == 3 && c.name == 'db-1' ? 'error' : 'info',
          's': 'stdout',
          'm': i == 3 && c.name == 'db-1' ? 'FATAL: connection limit exceeded' : '${c.name} satır ${i + 1}',
        }),
    ];
  }

  @override
  Stream<DozzleLog> stream(DozzleContainer c) => const Stream.empty();

  @override
  Future<bool> actionsEnabled() async => actions;
  static bool actions = false;
  static final performed = <String>[];

  @override
  Future<void> action(DozzleContainer c, String action) async => performed.add('${c.name}:$action');
}

/// Sample reply for the chat Markdown view: heading, bold/italic, list, task, table, code, quote.
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

/// For the "while you were away" test: as if the session had been viewed up to a certain event.
class PresetSeen extends ClaudeSeen {
  PresetSeen(this.preset);
  final Map<String, (int, String)> preset;
  @override
  Map<String, (int, String)> build() => preset;
}


/// Stand-in for Claude's PC screenshot (320x180): top bar, browser window, address bar.
Uint8List pcShotPng() => testPng(320, 180, (x, y) {
      if (y < 8) return 0xFF1E1E2E;
      if (x >= 16 && x < 304 && y >= 18 && y < 170) {
        if (y < 30) return 0xFFE0E0E6;
        if (y >= 34 && y < 42 && x >= 60 && x < 260) return 0xFFFFFFFF;
        if (x >= 40 && x < 140 && y >= 60 && y < 120) return 0xFF4F8EF7;
        return 0xFFF5F5F7;
      }
      return 0xFF5B6EE1;
    });

/// Persistent PC notification: last record shown (null = removed) and call log.
class FakePcNotifications implements PcNotifications {
  PcHold? shown;
  String? body;
  final log = <String>[];
  @override
  Future<void> show(AppLocalizations l, PcHold h) async {
    shown = h;
    body = l.pcOngoingBody(h.title, '${h.expiresAt.hour.toString().padLeft(2, '0')}:${h.expiresAt.minute.toString().padLeft(2, '0')}');
    log.add('show ${h.sessionId} ${h.expiresAt.toIso8601String()}');
  }

  @override
  Future<void> cancel() async {
    shown = null;
    log.add('cancel');
  }
}

/// GET /v1/doctor (agent's format): one failure with a fix, two warnings, the rest OK.
Map<String, dynamic> sampleDoctor() => {
      'version': '0.3.0',
      'checks': [
        {'id': 'tailscale', 'status': 'ok', 'code': 'doctor.tailscale.ok', 'params': {'dnsName': 'argo.my-tailnet.ts.net'}},
        {'id': 'tailscale.serve', 'status': 'fail', 'code': 'doctor.tailscale.notServed', 'params': {'port': 7443}, 'fix': 'sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443'},
        {'id': 'agent', 'status': 'ok', 'code': 'doctor.agent.listening', 'params': {'host': '127.0.0.1', 'port': 7443}},
        {'id': 'config', 'status': 'ok', 'code': 'doctor.config.ok', 'params': {'path': '~/.config/tiphys/agent.json'}},
        {'id': 'time', 'status': 'ok', 'code': 'doctor.time.synced', 'params': {}},
        {'id': 'disk', 'status': 'warn', 'code': 'doctor.disk.low', 'params': {'freeMb': 1480, 'totalMb': 240000}},
        {'id': 'node', 'status': 'ok', 'code': 'doctor.node.ok', 'params': {'node': '24.11.0'}},
        {'id': 'push', 'status': 'warn', 'code': 'doctor.push.notConfigured', 'params': {}},
        {'id': 'version', 'status': 'ok', 'code': 'doctor.version.latest', 'params': {'current': '0.3.0', 'latest': '0.3.0'}},
      ],
    };

/// GET /v1/desktop/capabilities of a Mac running the helper (no thumbnails, workspaces, H.264, mobile view, Sunshine…).
Map<String, dynamic> sampleMacCaps() => {
      'backend': 'helper',
      'platform': 'macos',
      'version': '0.1.0',
      'capabilities': ['windows', 'windowActions', 'monitors', 'screenshot', 'stream', 'input', 'text', 'apps', 'launch', 'clipboard'],
    };
