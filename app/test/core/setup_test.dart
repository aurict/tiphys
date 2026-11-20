// Setup and maintenance (K6–K9, P1): pairing code parsing, doctor report, update polling, desktop capabilities,
// version comparison, the onboarding flag and the live notifications without ntfy.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/platform.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/live_events.dart';
import 'package:tiphys/core/security/app_lock.dart';
import 'package:tiphys/features/desktop/desktop_caps.dart';
import 'package:tiphys/features/onboarding/onboarding_state.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/features/system/agent_update.dart';
import 'package:tiphys/features/system/doctor.dart';
import 'package:tiphys/features/system/pair_scanner.dart';
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/harness.dart';

/// Agent with an event log: GET /v1/events filters by `since` and `limit` like the real one (newest first).
class _EventsAgent extends AgentClient {
  _EventsAgent(this.log, this.queries) : super(baseUrl: 'http://fake', token: 'tph_fake');
  final List<Map<String, dynamic>> log;
  final List<Map<String, String>?> queries;
  static bool down = false;

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    if (down) throw const AgentError('net.unreachable');
    queries.add(query);
    final since = query?['since'] == null ? null : DateTime.parse(query!['since']!);
    final limit = int.parse(query?['limit'] ?? '100');
    final out = [for (final e in log.reversed) if (since == null || DateTime.parse(e['at'] as String).isAfter(since)) e];
    return {'events': out.take(limit).toList()};
  }
}

Map<String, dynamic> _ev(String id, String at, String key, [Map<String, dynamic> params = const {}, String source = 'agent']) =>
    {'id': id, 'at': at, 'key': key, 'params': params, 'link': 'tiphys://system', 'source': source};

const _argo = Host(id: 'argo', name: 'argo', address: 'argo', agent: AgentRef(url: 'https://argo.example.com', tokenRef: 'secret:agent-argo'));
const _atlas = Host(id: 'atlas', name: 'atlas', address: 'atlas', agent: AgentRef(url: 'https://atlas.example.com', tokenRef: 'secret:agent-atlas'));
const _noAgent = Host(id: 'nas', name: 'nas', address: 'nas');

void main() {
  group('eşleme kodu yapıştırma', () {
    test('QR metni (JSON)', () {
      final p = parsePairingText(' {"v":1,"type":"tiphys-pair","agent":"argo","url":"https://argo.my-tailnet.ts.net:7443","token":"tph_abcdefgh123"} ');
      expect((p?.agent, p?.url, p?.token), ('argo', 'https://argo.my-tailnet.ts.net:7443', 'tph_abcdefgh123'));
    });

    test('pair komutunun "adres + token" satırları', () {
      final p = parsePairingText('QR okutulamazsa elle gir:\n  Adres: https://atlas.my-tailnet.ts.net:7443\n  Token: tph_Zx9-_abcDEF0123\n');
      expect((p?.agent, p?.url, p?.token), ('atlas', 'https://atlas.my-tailnet.ts.net:7443', 'tph_Zx9-_abcDEF0123'));
    });

    test('eksik ya da yabancı metin reddedilir', () {
      expect(parsePairingText('https://argo.example.com'), isNull);
      expect(parsePairingText('tph_abcdefgh123'), isNull);
      expect(parsePairingText('{"v":2,"type":"tiphys-pair"}'), isNull);
      expect(parsePairingText(''), isNull);
    });
  });

  group('doktor', () {
    test('rapor gruplanır, metinler iki dilde, bilinmeyen kod olduğu gibi', () {
      final r = DoctorReport.fromJson(sampleDoctor());
      expect(r.version, '0.4.0');
      expect(r.withStatus(DoctorStatus.fail).map((c) => c.id), ['tailscale.serve']);
      expect(r.withStatus(DoctorStatus.warn).map((c) => c.id), ['disk', 'push']);
      expect(r.problems, 3);
      final fail = r.withStatus(DoctorStatus.fail).single;
      expect(fail.fix, 'sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443');
      expect(doctorText(AppLocalizationsEn(), fail), 'tailscale serve does not publish the agent (port 7443) in your tailnet.');
      expect(doctorText(AppLocalizationsTr(), r.checks.firstWhere((c) => c.id == 'disk')), 'Disk alanı az: 1480 MB boş.');
      expect(doctorText(AppLocalizationsEn(), const DoctorCheck(id: 'x', status: DoctorStatus.ok, code: 'doctor.tailscale.served', params: {'httpsPorts': [443, 7443]})),
          'tailscale serve publishes the agent on HTTPS port 443, 7443.');
      // A newer agent's check and status: shown as a warning with its code.
      final unknown = DoctorCheck.fromJson({'id': 'new', 'status': 'info', 'code': 'doctor.new.thing', 'params': {}, 'fix': '  '});
      expect((unknown.status, unknown.fix, doctorText(AppLocalizationsEn(), unknown)), (DoctorStatus.warn, null, 'doctor.new.thing'));
      expect(doctorMissing(const AgentError('agent.route.notFound')), isTrue);
      expect(doctorMissing(const AgentError('net.timeout')), isFalse);
    });
  });

  group('güncelleme', () {
    test('yanıt ve hata metinleri', () {
      final u = UpdateInfo.fromJson({'current': '0.3.0', 'latest': '0.4.0', 'available': true, 'managed': true, 'notesUrl': 'https://example.com/r'});
      expect((u.available, u.managed, u.latest), (true, true, '0.4.0'));
      // "available" without a version can't be applied.
      expect(UpdateInfo.fromJson({'current': '0.3.0', 'latest': null, 'available': true}).available, isFalse);
      final l = AppLocalizationsEn();
      expect(agentErrorText(l, const AgentError('agent.update.disabled')), l.updateErrDisabled);
      expect(agentErrorText(l, const AgentError('agent.update.badSignature')), l.updateErrBadRelease);
      expect(agentErrorText(l, const AgentError('agent.update.notNewer', {'current': '0.4.0'})), 'The agent already runs 0.4.0 or newer.');
    });

    test('yeni sürüm yanıt verene kadar bekler; vermezse false', () async {
      var calls = 0;
      Future<Map<String, dynamic>> health() async {
        calls++;
        if (calls < 3) throw const AgentError('net.unreachable'); // restarting
        return {'version': calls < 4 ? '0.3.0' : '0.4.0'};
      }

      expect(await waitForAgentVersion(health, '0.4.0', every: Duration.zero, tries: 10), isTrue);
      expect(calls, 4);
      expect(await waitForAgentVersion(() async => {'version': '0.3.0'}, '0.4.0', every: Duration.zero, tries: 3), isFalse);
    });

    test('sürüm karşılaştırması: eski, aynı, yeni, okunamaz', () {
      expect([compareAgentVersion('0.2.9'), compareAgentVersion(kExpectedAgentVersion), compareAgentVersion('0.10.0'), compareAgentVersion('dev'), compareAgentVersion(null)], [-1, 0, 1, null, null]);
      expect((agentOutdated('0.2.0'), agentNewer('0.2.0'), agentNewer('9.0.0'), agentOutdated('dev')), (true, false, true, false));
    });
  });

  group('masaüstü yetenekleri', () {
    test('helper (macOS) ve eski ajan', () {
      final mac = DesktopCaps.fromJson(sampleMacCaps());
      final l = AppLocalizationsEn();
      expect((mac.isHyprland, mac.has('windows'), mac.has('thumbnails'), desktopBackendName(l, mac)), (false, true, false, 'macOS'));
      expect(missingDesktopFeatures(l, mac), ['window thumbnails', 'workspaces', 'H.264', 'Mobile view', 'Sunshine', 'Claude using the PC', 'clipboard sync', 'screen off/on']);
      expect(missingDesktopFeatures(l, DesktopCaps.legacy), isEmpty);
      expect(DesktopCaps.legacy.isHyprland, isTrue);
      final broken = DesktopCaps.fromJson({'backend': 'helper', 'capabilities': [], 'error': 'agent.desktop.helperMissing'});
      expect((broken.caps.isEmpty, broken.error, desktopBackendName(l, broken)), (true, 'agent.desktop.helperMissing', 'this desktop'));
    });

    test('izin hatası hangi izin olduğunu söyler', () {
      final l = AppLocalizationsEn();
      expect(agentErrorText(l, const AgentError('agent.desktop.permission', {'permission': 'Accessibility permission is missing (System Settings → …)'})),
          contains('Privacy & Security › Accessibility'));
      expect(agentErrorText(l, const AgentError('agent.desktop.permission', {'permission': 'Screen Recording'})), contains('Screen Recording permission'));
      expect(agentErrorText(l, const AgentError('agent.desktop.permission', {'permission': 'portal denied'})), endsWith('portal denied'));
      expect(agentErrorText(l, const AgentError('agent.desktop.helperMissing')), l.desktopErrHelperMissing);
      expect(agentErrorText(l, const AgentError('agent.desktop.unsupported')), l.desktopErrUnsupported);
    });
  });

  group('platform', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);
    test('Android her şey; iOS QR ama UnifiedPush yok; Linux yapıştırma', () {
      expect((hasUnifiedPush, hasQrScanner, isDesktopPlatform), (true, true, false));
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect((hasUnifiedPush, hasTiphysNative, hasQrScanner, isDesktopPlatform), (false, false, true, false));
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect((hasUnifiedPush, hasQrScanner, isDesktopPlatform), (false, false, true));
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect((hasQrScanner, isDesktopPlatform), (true, true));
    });
  });

  test('kurulum sihirbazı bayrağı: kayıtlı ya da host varsa görüldü', () async {
    final v = MemoryVault();
    expect(await loadOnboardingSeen(v, hasHosts: false), isFalse);
    expect(await loadOnboardingSeen(v, hasHosts: true), isTrue);
    await Future<void>.delayed(Duration.zero);
    // Stored: even with every host deleted later it doesn't come back.
    expect(await loadOnboardingSeen(v, hasHosts: false), isTrue);
  });

  group('ntfy olmadan canlı bildirimler', () {
    late Map<String, List<Map<String, dynamic>>> logs;
    late List<Map<String, String>?> queries;
    late List<String> shown;
    late Set<String> covered;
    late LiveEventsWatcher w;

    setUp(() {
      _EventsAgent.down = false;
      queries = [];
      shown = [];
      covered = {};
      logs = {
        'argo': [_ev('a1', '2026-11-14T10:00:00.000Z', 'claude.done')],
        'atlas': [],
      };
      w = LiveEventsWatcher(
        hosts: () => const [_argo, _atlas, _noAgent],
        clientFor: (h) async => _EventsAgent(logs[h.id]!, queries),
        covered: (h) async => covered.contains(h.id),
        show: (e) async => shown.add('${e['key']}#${e['id']}'),
      );
    });

    test('ilk bakışta eski olaylar gösterilmez; sonra yeniler eskiden yeniye, uygulamanın kendi olayları hariç', () async {
      expect(await w.tick(), 0);
      expect(queries, [{'limit': '1'}, {'limit': '1'}]);
      logs['argo']!.addAll([
        _ev('a2', '2026-11-14T10:01:00.000Z', 'host.offline', {'host': 'atlas'}),
        _ev('a3', '2026-11-14T10:02:00.000Z', 'compose.updated', {'stack': 'web'}, 'app'),
        _ev('a4', '2026-11-14T10:03:00.000Z', 'disk.full', {'host': 'argo', 'mount': '/', 'percent': 95}),
      ]);
      logs['atlas']!.add(_ev('b1', '2026-11-14T10:01:30.000Z', 'docker.died', {'container': 'searxng'}));
      queries.clear();
      expect(await w.tick(), 3);
      // argo continues after its newest seen event; atlas's empty log started at the epoch, so its first event shows.
      expect(queries, [{'since': '2026-11-14T10:00:00.000Z', 'limit': '50'}, {'since': '1970-01-01T00:00:00.000Z', 'limit': '50'}]);
      expect(shown, ['host.offline#a2', 'disk.full#a4', 'docker.died#b1']);
      // Nothing new: nothing shown again.
      expect(await w.tick(), 0);
      expect(shown, hasLength(3));
    });

    test('push bu hostu kapsıyorsa sorulmaz (çift bildirim yok); kapsamı bitince baştan başlar', () async {
      covered.add('argo');
      await w.tick();
      logs['argo']!.add(_ev('a2', '2026-11-14T10:01:00.000Z', 'host.offline'));
      await w.tick();
      expect(shown, isEmpty);
      expect(queries.where((q) => q?['since'] != null).length, 1); // only atlas
      covered.clear();
      expect(await w.tick(), 0); // first look again: what push already showed isn't replayed
      logs['argo']!.add(_ev('a3', '2026-11-14T10:05:00.000Z', 'service.failed'));
      await w.tick();
      expect(shown, ['service.failed#a3']);
    });

    test('ulaşılamayan ajan sessizce atlanır; bir turda en çok 10 bildirim', () async {
      _EventsAgent.down = true;
      expect(await w.tick(), 0);
      _EventsAgent.down = false;
      await w.tick();
      for (var i = 0; i < 15; i++) {
        logs['argo']!.add(_ev('x$i', '2026-11-14T11:${i.toString().padLeft(2, '0')}:00.000Z', 'command.done'));
      }
      expect(await w.tick(), liveEventsMaxPerPoll);
      // The newest ten, oldest first.
      expect(shown.first, 'command.done#x5');
      expect(shown.last, 'command.done#x14');
    });

    test('başlat/durdur', () {
      expect(w.running, isFalse);
      w.start();
      expect(w.running, isTrue);
      w.stop();
      expect(w.running, isFalse);
    });
  });
}
