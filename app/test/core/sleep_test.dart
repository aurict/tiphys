// Sleep mode data layer (PLAN.md §21 U, S4 contract): settings and status parsing, the next alarm, the session object
// (the leader first without a plan, its plan forwarded to the others, the S2 fallback), group start with a partial
// failure and retries, stop on every machine, the alarm on one machine (notRinging), the alarm time across time zones,
// group-wide vs per-machine writes, the phone's backup alarm and run record, the `sleep.alarm` push, the notification
// routes and texts, the morning summary, errors.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/core/push/sleep_notices.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
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
      expect((empty.fadeMin, empty.soundFadeMin, empty.nightSound), (30, 45, 'off'));
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
    test('Uykuya geç: önce lidere plansız oturum; liderin yanıtındaki oturum (plan dahil) aynen diğerine', () async {
      FakeAgent.sleep.configured();
      FakeAgent.sleep.hosts['argo']!.alarmNext = DateTime.now().add(const Duration(hours: 7)).millisecondsSinceEpoch;
      final c = _container();
      await _group(c);
      final r = await c.read(sleepGroupProvider.notifier).start();
      expect(r.ok, isTrue);
      final starts = _calls('/v1/sleep/start');
      expect(starts, hasLength(2));
      final first = (starts.first.$3 as Map)['session'] as Map;
      final second = (starts.last.$3 as Map)['session'] as Map;
      expect(first['leader'], 'theloth');
      expect(first.containsKey('plan'), isFalse, reason: 'telefon planı kurmaz');
      final leaderSession = FakeAgent.sleep.hosts['argo']!.session!;
      expect(second, leaderSession, reason: 'liderin döndürdüğü oturum, plan dahil, değişmeden');
      expect((second['plan'] as Map)['ringAt'], FakeAgent.sleep.hosts['argo']!.alarmNext);
      expect(FakeAgent.sleep.hosts['atlas']!.session!['plan'], leaderSession['plan']);
      expect(FakeAgent.sleep.hosts.values.every((h) => h.running), isTrue);
      expect(c.read(sleepGroupProvider.notifier).lastSession, leaderSession);
      expect(c.read(sleepGroupProvider).value!.running, isTrue);
    });

    test('lider başlamazsa üyeler başlatılmaz; yeniden dene önce lideri, sonra planı üyeye', () async {
      FakeAgent.sleep.configured();
      FakeAgent.sleep.hosts['argo']!.startError = const AgentError('net.unreachable');
      final c = _container();
      await _group(c);
      final n = c.read(sleepGroupProvider.notifier);
      final r = await n.start();
      expect(r.started, isEmpty);
      expect(r.failed['argo'], isA<AgentError>());
      expect(r.failed['atlas'], isA<SleepLeaderNotStarted>());
      expect(_calls('/v1/sleep/start'), hasLength(1), reason: 'üye kendi planıyla başlamasın');
      expect(sleepActionError(_tr, c.read(sleepGroupProvider).value, r.failed['atlas']!), _tr.slErrLeaderNotStarted(exampleHost('argo').name));
      FakeAgent.sleep.hosts['argo']!.startError = null;
      FakeAgent.calls.clear();
      final again = await n.start(only: r.failed.keys.toList(), session: n.lastSession);
      expect(again.ok, isTrue);
      final starts = _calls('/v1/sleep/start');
      expect(((starts.first.$3 as Map)['session'] as Map).containsKey('plan'), isFalse);
      expect((starts.last.$3 as Map)['session'], FakeAgent.sleep.hosts['argo']!.session);
      expect(FakeAgent.sleep.hosts['atlas']!.session!['plan'], isNotNull);
    });

    test('Tek makineyle sür: lider hatalıysa bekleyen üye tek başına (kendi lideri)', () async {
      FakeAgent.sleep.configured();
      FakeAgent.sleep.hosts['argo']!.startError = const AgentError('net.unreachable');
      final c = _container();
      await _group(c);
      final n = c.read(sleepGroupProvider.notifier);
      final r = await n.start();
      FakeAgent.calls.clear();
      final alone = await n.startAlone(r);
      expect(alone.started, ['atlas']);
      final s = (_calls('/v1/sleep/start').single.$3 as Map)['session'] as Map;
      expect(s['leader'], 'laptop');
      expect(s['members'], [
        {'host': 'laptop', 'side': 'right', 'distance': 'mid'},
      ]);
      expect(FakeAgent.sleep.hosts['atlas']!.session!['plan'], isNotNull, reason: 'tek üyede kendi planı');
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
      expect((s.$3 as Map)['session'], FakeAgent.sleep.hosts['argo']!.session, reason: 'yeniden denemede de liderin planı');
    });

    test('S2 ajanı (yalnız kimlik listesi): 400 sonrası aynı oturum kimlik listesiyle gider', () async {
      FakeAgent.sleep.idsOnly = true;
      final c = _container();
      await _group(c);
      final r = await c.read(sleepGroupProvider.notifier).start();
      expect(r.ok, isTrue);
      expect(FakeAgent.sleep.hosts['argo']!.session!['members'], ['theloth', 'laptop']);
      expect(sessionIdsOnly({'id': 'x', 'members': ['a'], 'plan': {}}).containsKey('plan'), isFalse);
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

    test('alarm: Ertele/Kapat yalnız lidere (grup iletir); yedek taşınır/iptal edilir', () async {
      FakeAgent.sleep.sleeping(ringing: true);
      final c = _container();
      final g = await _group(c);
      expect(g.ringing, isTrue);
      await c.read(sleepGroupProvider.notifier).alarm('snooze');
      expect(_calls('/v1/sleep/alarm').map((x) => x.$3), [
        {'action': 'snooze'},
      ]);
      expect(FakeAgent.sleep.hosts.values.map((h) => h.phase), ['snoozed', 'snoozed']);
      expect(_h.sleepAlarms.backups.last, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 20)); // the re-read after the action
      FakeAgent.calls.clear();
      await c.read(sleepGroupProvider.notifier).alarm('dismiss');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_calls('/v1/sleep/alarm'), hasLength(1));
      expect(_h.sleepAlarms.backups.last, isNull);
      expect(_h.sleepAlarms.cleared, greaterThan(0));
    });

    test('alarm: lidere ulaşılamazsa sıradaki çalışan makine', () async {
      FakeAgent.sleep.sleeping(ringing: true);
      final c = _container();
      await _group(c);
      FakeAgent.sleep.hosts['argo']!.error = const AgentError('net.unreachable');
      await c.read(sleepGroupProvider.notifier).alarm('dismiss');
      expect(_calls('/v1/sleep/alarm'), hasLength(2), reason: 'önce lider (ulaşılamadı), sonra laptop');
      expect(FakeAgent.sleep.hosts['atlas']!.phase, 'morning');
    });

    test('alarm çalmıyorken: 409 notRinging tek çağrıda, metin "şu an çalmıyor"; yedek yeniden kurulur', () async {
      FakeAgent.sleep.sleeping(phase: 'night');
      final ring = DateTime.fromMillisecondsSinceEpoch(DateTime.now().add(const Duration(hours: 6)).millisecondsSinceEpoch); // whole ms: the fake agent stores epoch ms
      for (final h in FakeAgent.sleep.hosts.values) {
        h.alarmNext = ring.millisecondsSinceEpoch;
      }
      final c = _container();
      await _group(c);
      Object? err;
      try {
        await c.read(sleepGroupProvider.notifier).alarm('dismiss');
      } catch (e) {
        err = e;
      }
      expect(err, isA<AgentError>().having((e) => e.code, 'code', 'agent.sleep.notRinging'));
      expect(_calls('/v1/sleep/alarm'), hasLength(1));
      expect(sleepActionError(_tr, null, err!), 'Alarm şu an çalmıyor.');
      expect(sleepActionError(_en, null, err), "The alarm isn't ringing right now.");
      await Future<void>.delayed(Duration.zero);
      expect(_h.sleepAlarms.backups.last, DateTime.fromMillisecondsSinceEpoch(ring.millisecondsSinceEpoch).add(sleepBackupDelay), reason: 'iptal edilen yedek makinelerin durumuyla geri gelir');
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

    test('bildirimden Ertele/Kapat: önce lider, yalnız biri; ulaşılamayan atlanır, notRinging durdurur', () async {
      final posts = <(String, Object?)>[];
      final secrets = MemorySecretStore({'agent-argo': 'x', 'agent-atlas': 'x'});
      Future<bool> send(Map<String, Object> answers) => sleepAlarmToAgents(
        actionSleepSnooze,
        profile: exampleProfile(),
        secrets: secrets,
        run: const SleepRun(hosts: ['argo', 'atlas']),
        clientFor: (url, token) => _RecordingClient(url, posts, answers: answers),
      );
      expect(await send({}), isTrue);
      expect(posts.map((p) => p.$1), ['https://argo.example.ts.net:7443/v1/sleep/alarm']);
      posts.clear();
      expect(await send({'argo': const AgentError('net.unreachable')}), isTrue);
      expect(posts.map((p) => Uri.parse(p.$1).host.split('.').first), ['argo', 'atlas']);
      posts.clear();
      expect(await send({'argo': const AgentError('agent.sleep.notRinging', {'phase': 'night'}, 409)}), isTrue);
      expect(posts, hasLength(1), reason: 'grup zaten yanıtladı: ikinci makineye gitmez');
      posts.clear();
      expect(await send({'argo': const AgentError('agent.screen.notRunning', {}, 409), 'atlas': const AgentError('net.timeout')}), isFalse);
      expect(posts, hasLength(2));
    });

    test('push sleep.alarm alanları: ringing (at, ringAt, count), snoozed (snoozedUntil), dismissed/autoStopped', () {
      final now = DateTime(2026, 11, 21, 7, 0);
      final ringAt = DateTime(2026, 11, 21, 7, 30);
      final at = DateTime(2026, 11, 21, 7, 48);
      final ring = SleepAlarmPush.of({'state': 'ringing', 'at': at.millisecondsSinceEpoch, 'snoozeMin': 9, 'count': 2, 'ringAt': ringAt.millisecondsSinceEpoch}, now)!;
      expect((ring.show, ring.title, ring.count, ring.backup, ring.ring, ring.snoozeMin), (at, ringAt, 2, at.add(sleepBackupDelay), at, 9));
      final first = SleepAlarmPush.of({'state': 'ringing', 'at': ringAt.millisecondsSinceEpoch, 'snoozeMin': 9, 'count': 1, 'ringAt': ringAt.millisecondsSinceEpoch}, now)!;
      expect((first.title, first.count), (ringAt, 1));
      expect(sleepAlarmText(_tr, ringAt, count: 2), ('Alarm · 07:30', _tr.slAlarmBodyAgain(2)));
      expect(sleepAlarmText(_tr, ringAt).$2, _tr.slAlarmBody);
      final until = DateTime(2026, 11, 21, 7, 39);
      final snoozed = SleepAlarmPush.of({'state': 'snoozed', 'at': ringAt.millisecondsSinceEpoch, 'snoozeMin': 9, 'snoozedUntil': until.millisecondsSinceEpoch}, now)!;
      expect((snoozed.show, snoozed.backup, snoozed.ring), (null, until.add(sleepBackupDelay), until));
      final noUntil = SleepAlarmPush.of({'state': 'snoozed', 'at': ringAt.millisecondsSinceEpoch, 'snoozeMin': 5}, now)!;
      expect(noUntil.ring, ringAt.add(const Duration(minutes: 5)));
      for (final st in ['dismissed', 'autoStopped']) {
        final p = SleepAlarmPush.of({'state': st, 'at': at.millisecondsSinceEpoch, 'snoozeMin': 9}, now)!;
        expect((p.state, p.show, p.backup, p.ring), (st, null, null, null), reason: '$st: bildirim ve yedek gider');
      }
      expect(SleepAlarmPush.of({'state': 'later'}, now), isNull, reason: 'bilinmeyen durum hiçbir şeyi değiştirmez');
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

  group('saat dilimi', () {
    // The leader rings at 07:30 its own time; [phone] is the same instant on the phone's clock.
    SleepGroup leaderAt(DateTime phone, {String hm = '07:30', String? edited, bool running = false}) {
      final settings = SleepSettings(sleepDefaults()).apply({
        'alarm': {'enabled': true, 'time': edited ?? hm, 'days': 'daily'},
        'group': {
          'members': ['theloth'],
          'leader': 'theloth',
        },
      });
      final ms = phone.millisecondsSinceEpoch;
      return SleepGroup([
        SleepMachine(
          host: exampleHost('argo'),
          agentId: 'theloth',
          status: SleepStatus(
            running: running,
            alarmNext: ms,
            alarmHm: hm,
            settings: settings,
            session: running ? {'t0': ms - 8 * 3600000, 'plan': fakePlan(ms - 8 * 3600000, ms)} : null,
          ),
        ),
      ]);
    }

    test('alarm saati alarm.next ile telefonun saatinde; fark 15 dk adımlarıyla bulunur', () {
      final same = leaderAt(DateTime(2026, 11, 21, 7, 30));
      expect((same.leaderZoneMin, same.alarmHmLocal), (0, '07:30'));
      // A leader 9 h behind the phone (e.g. CST vs +03): 07:30 there is 16:30 here.
      final behind = leaderAt(DateTime(2026, 11, 21, 16, 30));
      expect((behind.leaderZoneMin, behind.alarmHmLocal), (-540, '16:30'));
      expect(sleepAlarmLine(_tr, behind), 'alarm 16:30 · 1 makine');
      // Across midnight: 23:30 there, 01:30 here.
      expect(leaderAt(DateTime(2026, 11, 22, 1, 30), hm: '23:30').leaderZoneMin, -120);
      expect(leaderAt(DateTime(2026, 11, 21, 3, 15), hm: '22:30').leaderZoneMin, -285, reason: 'çeyrek saatlik dilim (4:45 geride)');
      // Running: the plan's ring (the same instant).
      expect(leaderAt(DateTime(2026, 11, 21, 16, 30), running: true).alarmHmLocal, '16:30');
    });

    test('bekleyen düzenleme: yeni saat liderin farkıyla telefona çevrilir', () {
      final g = leaderAt(DateTime(2026, 11, 21, 16, 30), edited: '08:00');
      expect(g.alarmLocal, isNull, reason: 'alarm.next eski saate ait');
      expect(g.alarmHmLocal, '17:00');
      expect(shiftHm('23:50', 20), '00:10');
      expect(shiftHm('00:10', -20), '23:50');
      expect(zoneDiffMin('07:30', DateTime(2026, 11, 21, 7, 39)), isNull, reason: 'erteleme halkası dilim değil');
    });

    test('alarm.next yokken (S4 öncesi) ayarın saati olduğu gibi', () {
      final g = SleepGroup([SleepMachine(host: exampleHost('argo'), agentId: 'theloth', status: SleepStatus(settings: SleepSettings(sleepDefaults()).apply({'alarm': {'enabled': true, 'time': '06:45'}})))]);
      expect((g.leaderZoneMin, g.alarmHmLocal), (null, '06:45'));
    });

    test('yedek alarm: plan.ringAt (alarm.next yoksa), dismissedAt varsa yok', () {
      final now = DateTime(2026, 11, 21, 1, 0);
      final ring = DateTime(2026, 11, 21, 7, 30).millisecondsSinceEpoch;
      SleepGroup g({int? dismissed}) => SleepGroup([
        SleepMachine(
          host: exampleHost('argo'),
          agentId: 'theloth',
          status: SleepStatus(running: true, session: {'t0': 0, 'plan': {...fakePlan(0, ring), 'dismissedAt': dismissed}}, settings: SleepSettings(sleepDefaults())),
        ),
      ]);
      expect(sleepRingAt(g(), now), DateTime.fromMillisecondsSinceEpoch(ring));
      expect(sleepRingAt(g(dismissed: ring + 60000), now), isNull);
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
  _RecordingClient(this.url, this.posts, {this.answers = const {}}) : super(baseUrl: url, token: 'x');
  final String url;
  final List<(String, Object?)> posts;

  /// host id → the error it answers with.
  final Map<String, Object> answers;
  @override
  Future<dynamic> post(String path, [Object? body]) async {
    posts.add(('$url$path', body));
    final e = answers[Uri.parse(url).host.split('.').first];
    if (e != null) throw e;
    return {'ok': true};
  }
}

/// A host of the example profile.
Host exampleHost(String id) => exampleProfile().host(id)!;
