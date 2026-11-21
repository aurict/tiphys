// Sleep mode data layer (PLAN.md §21 U): settings and status parsing, the next alarm, the ONE session object (leader
// first, the S2 fallback), group start with a partial failure, stop/alarm on every machine, group-wide vs per-machine
// writes, the phone's backup alarm and run record, the notification routes and texts, the morning summary, errors.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/core/push/sleep_notices.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/screen/sleep/sleep_data.dart';
import 'package:tiphys/features/screen/sleep/sleep_morning.dart';
import 'package:tiphys/features/screen/sleep/sleep_sync.dart';
import 'package:tiphys/features/screen/sleep/sleep_texts.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/harness.dart';
import '../helpers/sleep_fixtures.dart';

final _tr = AppLocalizationsTr();
final _en = AppLocalizationsEn();
final _features = [...Harness.defaultAgentFeatures, 'screen'];

late Harness _h;

ProviderContainer _container() {
  _h = Harness(agentFeatures: _features, health: (url) => sleepHealth(url, _features));
  final c = ProviderContainer(overrides: _h.overrides);
  addTearDown(c.dispose);
  return c;
}

Future<SleepGroup> _group(ProviderContainer c) async {
  c.listen(sleepGroupProvider, (_, _) {});
  return c.read(sleepGroupProvider.future);
}

List<(String, String, Object?)> _calls(String path) => [
  for (final c in FakeAgent.calls)
    if (c.$2 == path) c,
];

void main() {
  setUp(() {
    FakeAgent.resetSleep();
    FakeAgent.calls.clear();
  });

  group('model', () {
    test('ayarlar varsayılanlarla okunur; günler ve saat doğrulanır', () {
      const empty = SleepSettings();
      expect((empty.join, empty.side, empty.distance, empty.volume), (true, 'left', 'mid', 35));
      expect((empty.brightnessStart, empty.brightnessNight, empty.brightnessMorning), (25, 3, 70));
      expect((empty.fadeMin, empty.soundFadeMin, empty.nightSound), (30, 45, 'hum'));
      expect(empty.layer('wind'), isFalse);
      expect(empty.layer('crackle'), isTrue);
      expect(empty.hasAlarm, isFalse, reason: 'alarm bloğu yok: ajan güncellemesi gerekiyor');
      final s = SleepSettings(sleepDefaults()).apply({
        'alarm': {'enabled': true, 'time': '6:5', 'days': [5, 1, 3]},
        'group': {
          'members': ['theloth', 'laptop'],
          'leader': 'laptop',
        },
      });
      expect(s.alarmTime, '07:00', reason: 'geçersiz saat varsayılana döner');
      expect(s.alarmDays, [1, 3, 5]);
      expect(s.group!.$1, ['theloth', 'laptop']);
      expect(s.group!.$2, 'laptop');
      expect(s.apply({'group': null}).group, isNull, reason: 'group bütün olarak değişir');
      expect(sleepIdOf('the loth/1'), 'the-loth-1');
    });

    test('durum ayrıştırılır; saat kayması düzeltilir', () {
      final received = DateTime.fromMillisecondsSinceEpoch(1_000_000);
      final s = SleepStatus.fromJson({
        'running': true,
        'session': {'id': 'abcdefgh', 'seed': 1, 't0': 900_000, 'members': ['theloth'], 'leader': 'theloth'},
        'phase': 'fade',
        'phaseEndsAt': 1_060_000 + 600_000,
        'alarm': {'next': null, 'ringing': false, 'snoozedUntil': null},
        'members': [
          {'host': 'theloth', 'state': 'running'},
        ],
        'brightness': {'dimming': 'ddc', 'hardware': 20, 'content': 0.5, 'preview': null},
        'warning': null,
        'settings': sleepDefaults(),
        'now': 1_060_000,
      }, receivedAt: received);
      expect(s.skewMs, 60_000);
      expect(s.phaseEndsLocal, received.add(const Duration(minutes: 10)));
      expect((s.dimming, s.hardware), ('ddc', 20));
      expect(s.members.single, ('theloth', 'running'));
      expect(s.sessionId, 'abcdefgh');
      final g = SleepStatus.fromJson({
        'running': true,
        'members': [
          {'host': 'theloth', 'side': 'left', 'distance': 'mid', 'leader': true, 'state': 'running'},
          {'host': 'laptop', 'side': 'right', 'distance': 'near', 'leader': false, 'state': 'down'},
        ],
        'group': {'role': 'member', 'link': 'ok', 'offsetMs': 9, 'rttMs': 20, 'error': 'agent.sleep.memberDown'},
      });
      expect(g.members.last, ('laptop', 'down'));
      expect((g.groupLink, g.groupError), ('ok', 'agent.sleep.memberDown'));
    });

    test('sonraki alarm: bir kez, hafta içi, seçili günler, gece yarısı', () {
      SleepSettings alarm(Object days, [String time = '07:30']) => SleepSettings(sleepDefaults()).apply({
        'alarm': {'enabled': true, 'time': time, 'days': days},
      });
      final fri23 = DateTime(2026, 11, 20, 23, 0); // Friday
      expect(nextAlarm(alarm('once'), fri23), DateTime(2026, 11, 21, 7, 30));
      expect(nextAlarm(alarm('weekdays'), fri23), DateTime(2026, 11, 23, 7, 30), reason: 'Cumartesi/Pazar atlanır');
      expect(nextAlarm(alarm('daily'), DateTime(2026, 11, 21, 7, 0)), DateTime(2026, 11, 21, 7, 30));
      expect(nextAlarm(alarm([0]), fri23), DateTime(2026, 11, 22, 7, 30), reason: '0 = Pazar');
      expect(nextAlarm(SleepSettings(sleepDefaults()), fri23), isNull, reason: 'kapalı');
    });

    test('oturum nesnesi: kimlik biçimi, lider önce, yerleşim, liderin saati', () {
      final g = SleepGroup([
        SleepMachine(host: exampleHost('atlas'), agentId: 'laptop', status: SleepStatus(settings: SleepSettings(sleepDefaults(side: 'right')))),
        SleepMachine(host: exampleHost('argo'), agentId: 'theloth', velour: true, status: SleepStatus(settings: SleepSettings(sleepDefaults()), skewMs: 5000)),
      ]);
      final now = DateTime.fromMillisecondsSinceEpoch(2_000_000_000_000);
      final s = buildSession(g, g.members, now: now, random: math.Random(1));
      expect(s['id'], matches(RegExp(r'^[A-Za-z0-9_-]{16}$')));
      expect(s['seed'], isA<int>());
      expect(s['leader'], 'theloth', reason: 'Velour olan varsayılan lider');
      expect(s['t0'], now.millisecondsSinceEpoch + 5000);
      expect(s['members'], [
        {'host': 'theloth', 'side': 'left', 'distance': 'mid'},
        {'host': 'laptop', 'side': 'right', 'distance': 'mid'},
      ]);
      expect(sessionIdsOnly(s)['members'], ['theloth', 'laptop']);
    });
  });

  group('grup', () {
    test('Uykuya geç: tek oturum, önce lider, sonra diğerleri; hepsi aynı nesneyi alır', () async {
      FakeAgent.sleep.configured();
      final c = _container();
      await _group(c);
      final r = await c.read(sleepGroupProvider.notifier).start();
      expect(r.ok, isTrue);
      final starts = _calls('/v1/sleep/start');
      expect(starts, hasLength(2));
      final first = FakeAgent.calls.indexWhere((x) => x.$2 == '/v1/sleep/start');
      expect(FakeAgent.sleep.hosts['argo']!.session, isNotNull);
      expect((starts.first.$3 as Map)['session'], (starts.last.$3 as Map)['session']);
      expect(((starts.first.$3 as Map)['session'] as Map)['leader'], 'theloth');
      // The leader's request went out first.
      expect(FakeAgent.calls[first].$3, starts.first.$3);
      expect(FakeAgent.sleep.hosts.values.every((h) => h.running), isTrue);
      expect(c.read(sleepGroupProvider).value!.running, isTrue);
    });

    test('kısmi hata: hangi host başlamadı; yeniden dene aynı oturumla yalnız onu dener', () async {
      FakeAgent.sleep.configured();
      FakeAgent.sleep.hosts['atlas']!.startError = const AgentError('net.unreachable');
      final c = _container();
      await _group(c);
      final n = c.read(sleepGroupProvider.notifier);
      final r = await n.start();
      expect(r.failed.keys, ['atlas']);
      expect(r.started, ['argo']);
      FakeAgent.sleep.hosts['atlas']!.startError = null;
      FakeAgent.calls.clear();
      final again = await n.start(only: r.failed.keys.toList(), session: n.lastSession);
      expect(again.ok, isTrue);
      final s = _calls('/v1/sleep/start').single;
      expect(FakeAgent.sleep.hosts['atlas']!.session!['id'], (FakeAgent.sleep.hosts['argo']!.session!)['id']);
      expect(((s.$3 as Map)['session'] as Map)['id'], FakeAgent.sleep.hosts['argo']!.session!['id']);
    });

    test('S2 ajanı (yalnız kimlik listesi): 400 sonrası aynı oturum kimlik listesiyle gider', () async {
      FakeAgent.sleep.idsOnly = true;
      final c = _container();
      await _group(c);
      final r = await c.read(sleepGroupProvider.notifier).start();
      expect(r.ok, isTrue);
      expect(FakeAgent.sleep.hosts['argo']!.session!['members'], ['theloth', 'laptop']);
    });

    test('Uyan hepsini durdurur; yedek alarm ve kayıt silinir', () async {
      FakeAgent.sleep.sleeping();
      final c = _container();
      await _group(c);
      await c.read(sleepSyncProvider).sync(c.read(sleepGroupProvider).value!);
      expect(await _h.sleepVault.read(sleepRunKey), isNotNull);
      await c.read(sleepGroupProvider.notifier).stop();
      expect(_calls('/v1/sleep/stop'), hasLength(2));
      expect(FakeAgent.sleep.hosts.values.any((h) => h.running), isFalse);
      expect(await _h.sleepVault.read(sleepRunKey), isNull);
      expect(_h.sleepAlarms.backups.last, isNull);
    });

    test('alarm: Kapat her makineye gider ve yedeği iptal eder; Ertele yedeği taşır', () async {
      FakeAgent.sleep.sleeping(ringing: true);
      final c = _container();
      final g = await _group(c);
      expect(g.ringing, isTrue);
      await c.read(sleepGroupProvider.notifier).alarm('snooze');
      expect(_calls('/v1/sleep/alarm').map((x) => x.$3), [
        {'action': 'snooze'},
        {'action': 'snooze'},
      ]);
      expect(_h.sleepAlarms.backups.last, isNotNull);
      FakeAgent.calls.clear();
      await c.read(sleepGroupProvider.notifier).alarm('dismiss');
      expect(_calls('/v1/sleep/alarm'), hasLength(2));
      expect(_h.sleepAlarms.backups.last, isNull);
      expect(_h.sleepAlarms.cleared, greaterThan(0));
    });

    test('grup ayarı her makineye, makine ayarı yalnız ona yazılır; katılım grubu yeniden yazar', () async {
      final c = _container();
      await _group(c);
      final n = c.read(sleepGroupProvider.notifier);
      await n.saveGroup({
        'times': {'fadeMin': 40},
      });
      expect(_calls('/v1/sleep').where((x) => x.$1 == 'PUT'), hasLength(2));
      expect(FakeAgent.sleep.hosts.values.map((h) => h.settings['times']['fadeMin']), [40, 40]);
      FakeAgent.calls.clear();
      await n.saveMachine('atlas', {'volume': 50});
      expect(_calls('/v1/sleep').where((x) => x.$1 == 'PUT').single.$3, {
        'settings': {'volume': 50},
      });
      expect(FakeAgent.sleep.hosts['argo']!.settings['volume'], 35);
      await n.setJoin('atlas', false);
      expect(FakeAgent.sleep.hosts['atlas']!.settings['join'], isFalse);
      expect(FakeAgent.sleep.hosts['argo']!.settings['group'], {
        'members': ['theloth'],
        'leader': 'theloth',
      });
      expect(FakeAgent.sleep.hosts['atlas']!.settings['group'], FakeAgent.sleep.hosts['argo']!.settings['group']);
    });

    test('eski ajan (404) güncelleme ister; ötekisi çalışır', () async {
      FakeAgent.sleep.unsupported.add('atlas');
      final c = _container();
      final g = await _group(c);
      expect(g.byHost('atlas')!.unsupported, isTrue);
      expect(g.byHost('argo')!.ok, isTrue);
      expect(g.allUnsupported, isFalse);
      expect(g.members.map((m) => m.host.id), ['argo']);
    });
  });

  group('telefon', () {
    test('uyurken alarm + 3 dk yedek kurulur ve kayıt yazılır; aynı durum ikinci kez yazılmaz', () async {
      FakeAgent.sleep.sleeping();
      final c = _container();
      final g = await _group(c);
      final now = DateTime.now();
      await c.read(sleepSyncProvider).sync(g, now: now);
      final ring = nextAlarm(g.settings, DateTime.fromMillisecondsSinceEpoch((g.phaseSource!.session!['t0'] as num).toInt() - g.phaseSource!.skewMs))!;
      expect(_h.sleepAlarms.backups.last, ring.add(sleepBackupDelay));
      final run = SleepRun.fromJson(await _h.sleepVault.read(sleepRunKey))!;
      expect(run.hosts, ['argo', 'atlas']);
      expect(run.ringAt, ring);
      final n = _h.sleepAlarms.backups.length;
      await c.read(sleepSyncProvider).sync(g, now: now);
      expect(_h.sleepAlarms.backups, hasLength(n));
    });

    test('ajanın alarm.next ve ertelemesi hesaplananın önüne geçer', () {
      final t = DateTime(2026, 11, 21, 6, 0);
      SleepGroup g(int? next, int? snoozed) => SleepGroup([
        SleepMachine(
          host: exampleHost('argo'),
          agentId: 'theloth',
          status: SleepStatus(running: true, session: const {'t0': 0}, alarmNext: next, snoozedUntil: snoozed, settings: SleepSettings(sleepDefaults())),
        ),
      ]);
      expect(sleepRingAt(g(t.millisecondsSinceEpoch, null), t), t);
      expect(sleepRingAt(g(1, t.millisecondsSinceEpoch), t), t);
      expect(sleepRingAt(g(null, null), t), isNull, reason: 'alarm kapalı');
    });

    test('hatırlatma grubun ayarını izler', () async {
      FakeAgent.sleep.configured();
      for (final h in FakeAgent.sleep.hosts.values) {
        h.settings['reminder'] = {'enabled': true, 'time': '22:45'};
      }
      final c = _container();
      await _group(c);
      await Future<void>.delayed(Duration.zero);
      expect(_h.sleepAlarms.reminders, ['22:45']);
    });

    test('bildirimden Ertele/Kapat: kayıttaki makinelere gider', () async {
      final posts = <(String, Object?)>[];
      final ok = await sleepAlarmToAgents(
        actionSleepDismiss,
        profile: exampleProfile(),
        secrets: Harness().secrets,
        run: const SleepRun(hosts: ['argo']),
        clientFor: (url, token) => _RecordingClient(url, posts),
      );
      expect(ok, isTrue);
      expect(posts.single.$1, 'https://argo.example.ts.net:7443/v1/sleep/alarm');
      expect(posts.single.$2, {'action': 'dismiss'});
    });

    test('alarm bildirimi: tam ekran, alarm kategorisi, ısrarlı ses, Ertele/Kapat', () {
      final d = sleepAlarmDetails(_tr, snoozeMin: 9);
      expect(d.fullScreenIntent, isTrue);
      expect(d.category, AndroidNotificationCategory.alarm);
      expect(d.audioAttributesUsage, AudioAttributesUsage.alarm);
      expect(d.additionalFlags, [4]);
      expect(d.ongoing, isTrue);
      expect(d.visibility, NotificationVisibility.public);
      expect(d.actions!.map((a) => (a.id, a.title)), [(actionSleepSnooze, 'Ertele · 9 dk'), (actionSleepDismiss, 'Kapat')]);
      final (title, body) = sleepAlarmText(_en, DateTime(2026, 11, 21, 7, 30));
      expect(title, 'Alarm · 07:30');
      expect(body, _en.slAlarmBody);
    });

    test('bildirim adresleri: alarm ekranı, sabah özeti', () {
      final at = DateTime(2026, 11, 21, 7, 30);
      expect(routeForPayload(sleepAlarmPayload(at)), '/screen/sleep/alarm?at=${at.millisecondsSinceEpoch}');
      expect(isSleepAlarmRoute(routeForPayload(sleepAlarmPayload(null))!), isTrue);
      expect(routeForPayload('tiphys://sleep'), '/screen/sleep');
      final m = SleepMorning.fromParams({'minutes': 460, 'jobs': 2}, at: at);
      final r = routeForPayload(jsonEncode({'link': 'tiphys://sleep', 'morning': m.toJson()}))!;
      expect(r, startsWith('/screen/sleep?morning='));
      expect(SleepMorning.fromJson(Uri.parse(r).queryParameters['morning']), m);
    });
  });

  group('metinler', () {
    test('sabah özeti: sayılar, başlıklar, 12 saat', () {
      final at = DateTime(2026, 11, 21, 7, 40);
      final m = SleepMorning.fromParams({
        'minutes': 460,
        'jobs': '3',
        'jobsFailed': 1,
        'backups': 2,
        'incidents': 0,
        'held': 7,
        'titles': 'a\nb\n\nc\nd',
      }, at: at);
      expect(m.titles, ['a', 'b', 'c']);
      final (title, body) = sleepMorningNotice(_tr, m);
      expect(title, 'Günaydın · 7 sa 40 dk uyku');
      expect(body, '3 iş bitti (1 başarısız) · 2 yedek · 7 bildirim bekledi');
      expect(sleepMorningNotice(_en, SleepMorning(at: at, minutes: 30)).$2, _en.slMorningQuiet);
      expect(m.fresh(at.add(const Duration(hours: 11))), isTrue);
      expect(m.fresh(at.add(const Duration(hours: 13))), isFalse);
    });

    test('hata ve olay metinleri iki dilde', () {
      for (final l in [_tr, _en]) {
        expect(agentErrorText(l, const AgentError('agent.sleep.noGroup')), l.slErrNoGroup);
        expect(agentErrorText(l, const AgentError('agent.sleep.noGroup', {'reason': 'notMember'})), l.slErrNotMember);
        expect(agentErrorText(l, const AgentError('agent.sleep.noGroup', {'reason': 'noLeaderSource', 'leader': 'theloth'})), l.slErrNoLeaderSource('theloth'));
        expect(agentErrorText(l, const AgentError('agent.sleep.memberDown', {'host': 'laptop'})), l.slErrMemberDownHost('laptop'));
        expect(agentErrorText(l, const AgentError('agent.sleep.ddcUnavailable', {'reason': 'missing'})), l.slErrDdcMissing);
        expect(agentErrorText(l, const AgentError('agent.sleep.ddcUnavailable')), l.slErrDdcUnavailable);
        expect(agentErrorText(l, const AgentError('agent.sleep.badAlarm')), l.slErrBadAlarm);
        expect(agentErrorText(l, const AgentError('agent.sleep.running')), l.slErrRunning);
        expect(noticeText(l, 'sleep.started', {'device': 'Pixel'}), (l.slEventStarted, 'Pixel'));
        expect(noticeText(l, 'sleep.alarm', {'state': 'dismissed'})!.$1, l.slEventAlarmDismissed);
        expect(noticeText(l, 'sleep.morning', {'minutes': 60})!.$1, l.slMorningTitle(l.durationHours(1)));
      }
      expect(sleepDaysText(_tr, [1, 2, 0]), 'Pzt Sal Paz');
      expect(sleepPartialText(_en, null, SleepPartialError({'atlas': const AgentError('net.unreachable')})), 'atlas: ${_en.agentUnreachable}');
    });
  });
}

/// A client that records POSTs (the notification path builds its own clients from URL + token).
class _RecordingClient extends AgentClient {
  _RecordingClient(this.url, this.posts) : super(baseUrl: url, token: 'x');
  final String url;
  final List<(String, Object?)> posts;
  @override
  Future<dynamic> post(String path, [Object? body]) async {
    posts.add(('$url$path', body));
    return {'ok': true};
  }
}

/// A host of the example profile.
Host exampleHost(String id) => exampleProfile().host(id)!;
