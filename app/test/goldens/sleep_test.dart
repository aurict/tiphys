// Sleep mode (PLAN.md §21 U, S6): the home card (sleeping / alarm / the morning summary under a closed card), the
// chooser's fourth option, the sleep screen (off, sleeping, a partial start failure, every section), the setup wizard,
// the alarm screen and the morning summary card; and the flows behind them (group start leader first and the same
// session everywhere, retry / one machine, Uyan stops all, Ertele / Kapat on every machine, group-wide vs per-machine
// writes, the live brightness preview, the wizard's writes, the alarm screen over the app lock). Light/dark × TR/EN
// at 375 px. To update: flutter test test/goldens/sleep_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/lock/lock_gate.dart' show LockScreen;
import 'package:tiphys/features/screen/screen_sheet.dart';
import 'package:tiphys/features/screen/sleep/sleep_alarm_screen.dart';
import 'package:tiphys/features/screen/sleep/sleep_morning.dart';
import 'package:tiphys/features/screen/sleep/sleep_screen.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/harness.dart';
import '../helpers/sleep_fixtures.dart';

final _tr = AppLocalizationsTr();
final _en = AppLocalizationsEn();
AppLocalizations _l(String lang) => lang == 'tr' ? _tr : _en;

final _features = [...Harness.defaultAgentFeatures, 'screen', 'gamemode'];

void _size(WidgetTester tester, double w, double h) => tester.view.physicalSize = Size(w * 2, h * 2);

Future<void> _load(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await settle(tester);
}

void _widgets(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
  FakeAgent.resetScreen();
  FakeAgent.resetSleep();
  FakeAgent.calls.clear();
  await body(tester);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 70));
  debugDisableShadows = true;
});

Harness _harness({String? pin}) => Harness(agentFeatures: _features, health: (url) => sleepHealth(url, _features), pin: pin);

Future<Harness> _open(WidgetTester tester, {bool dark = false, String lang = 'tr', double h = 2600, String route = '/screen/sleep', String? pin}) async {
  final harness = _harness(pin: pin);
  await harness.pump(tester, route: route, dark: dark, lang: lang);
  _size(tester, 375, h);
  await _load(tester);
  return harness;
}

Profile _homeProfile() {
  final j = jsonDecode(File('assets/profile/example.json').readAsStringSync()) as Map<String, dynamic>;
  (j['app']['home'] as Map<String, dynamic>)['cards'] = ['claude', 'system', 'screenMode', 'infra'];
  return codec.decode(jsonEncode(j)).toProfile();
}

Future<Harness> _home(WidgetTester tester, {bool dark = false, String lang = 'tr', double h = 760}) async {
  final harness = Harness(profile: _homeProfile(), agentFeatures: _features, health: (url) => sleepHealth(url, _features));
  await harness.pump(tester, dark: dark, lang: lang);
  _size(tester, 375, h);
  await _load(tester);
  return harness;
}

List<(String, String, Object?)> _calls(String method, String path) => [
  for (final c in FakeAgent.calls)
    if (c.$1 == method && c.$2 == path) c,
];

Map<String, dynamic> _morning() => {
  'at': DateTime.now().subtract(const Duration(minutes: 20)).millisecondsSinceEpoch,
  'minutes': 462,
  'jobs': 3,
  'jobsFailed': 1,
  'backups': 2,
  'backupsFailed': 0,
  'incidents': 1,
  'held': 7,
  'titles': ['atlas: disk 91 % dolu', 'Yedek tamamlandı: notes', 'Claude bitti: dokümanları güncelle'],
};

void main() {
  group('ana sayfa kartı', () {
    for (final (name, ringing) in [('sleeping', false), ('alarm', true)]) {
      for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'tr'), ('dark', true, 'en')]) {
        _widgets('kart $name $theme $lang', (tester) async {
          FakeAgent.sleep.sleeping(ringing: ringing);
          await _home(tester, dark: dark, lang: lang);
          final l = _l(lang);
          expect(find.text(l.smModeSleep), findsOneWidget);
          expect(find.text(ringing ? l.slAlarmMachines(2) : '${l.slAlarmAt('07:30')} · ${l.slMachines(2)}'), findsOneWidget);
          if (ringing) {
            expect(find.text(l.slAlarmTitle('07:30')), findsOneWidget);
            expect(find.bySemanticsLabel(l.slDismiss), findsOneWidget);
          } else {
            expect(find.textContaining(l.slPhaseFade), findsOneWidget);
            expect(find.bySemanticsLabel(l.slWake), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await golden('png/sleep_card_${name}_${theme}_$lang.png');
        });
      }
    }

    for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'en')]) {
      _widgets('kapalı kart + sabah özeti $theme $lang', (tester) async {
        FakeAgent.sleep.configured();
        FakeAgent.sleep.summary = _morning();
        await _home(tester, dark: dark, lang: lang, h: 860);
        final l = _l(lang);
        expect(find.text(l.gmOff), findsOneWidget, reason: 'ekran modu kartı kapalı');
        expect(find.textContaining(l.slGoodMorning), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/sleep_card_morning_${theme}_$lang.png');
      });
    }

    _widgets('Uyan tek dokunuşla iki makineyi durdurur; çalarken Kapat alarmı kapatır', (tester) async {
      FakeAgent.sleep.sleeping(ringing: true);
      final h = await _home(tester);
      await tester.tap(find.bySemanticsLabel(_tr.slDismiss));
      await _load(tester);
      expect(_calls('POST', '/v1/sleep/alarm').map((c) => c.$3), [
        {'action': 'dismiss'},
        {'action': 'dismiss'},
      ]);
      expect(h.sleepAlarms.backups.last, isNull, reason: 'telefonun yedeği iptal');
      await tester.tap(find.bySemanticsLabel(_tr.slWake));
      await _load(tester);
      expect(_calls('POST', '/v1/sleep/stop'), hasLength(2));
      expect(find.text(_tr.gmOff), findsOneWidget);
    });
  });

  group('seçme sayfası', () {
    for (final (theme, dark, lang) in [('dark', true, 'tr'), ('light', false, 'en')]) {
      _widgets('Uyku seçeneği $theme $lang', (tester) async {
        FakeAgent.sleep.configured();
        await _home(tester, dark: dark, lang: lang, h: 812);
        final l = _l(lang);
        await tester.tap(find.bySemanticsLabel(l.gmStart));
        await _load(tester);
        await tester.tap(find.descendant(of: find.byType(ScreenSheet), matching: find.text(l.smModeSleep)));
        await settle(tester);
        expect(find.text('${l.slAlarmAt('07:30')} · ${l.slMachines(2)}'), findsOneWidget);
        expect(find.text(l.smFromLabel), findsNothing, reason: 'kaynak seçimi uykuda yok');
        expect(tester.takeException(), isNull);
        await golden('png/sleep_sheet_${theme}_$lang.png');
      });
    }

    _widgets('Uykuya geç: tek oturum, önce lider (Velour olan), sonra diğeri', (tester) async {
      FakeAgent.sleep.configured();
      await _home(tester, h: 812);
      await tester.tap(find.bySemanticsLabel(_tr.gmStart));
      await _load(tester);
      await tester.tap(find.descendant(of: find.byType(ScreenSheet), matching: find.text(_tr.smModeSleep)));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, _tr.slStart));
      await _load(tester);
      final starts = _calls('POST', '/v1/sleep/start');
      expect(starts, hasLength(2));
      final session = (starts.first.$3 as Map)['session'] as Map;
      expect(session['leader'], 'theloth');
      expect((session['members'] as List).first, {'host': 'theloth', 'side': 'left', 'distance': 'mid'});
      expect((starts.last.$3 as Map)['session'], session);
      expect(FakeAgent.sleep.hosts['argo']!.session!['id'], FakeAgent.sleep.hosts['atlas']!.session!['id']);
      expect(find.byType(ScreenSheet), findsNothing);
      expect(find.text(_tr.smModeSleep), findsOneWidget, reason: 'kart uykuya döndü');
    });

    _widgets('kurulmamış grup: sihirbaz açılır', (tester) async {
      await _home(tester, h: 812);
      await tester.tap(find.bySemanticsLabel(_tr.gmStart));
      await _load(tester);
      await tester.tap(find.descendant(of: find.byType(ScreenSheet), matching: find.text(_tr.smModeSleep)));
      await tester.pump();
      expect(find.text(_tr.slSetupNeeded), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, _tr.slSetup));
      await _load(tester);
      expect(find.text(_tr.slWizardMachines), findsOneWidget);
      expect(_calls('POST', '/v1/sleep/start'), isEmpty);
    });
  });

  group('uyku ekranı', () {
    for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'en')]) {
      _widgets('kapalı, bütün bölümler $theme $lang', (tester) async {
        FakeAgent.sleep.configured();
        await _open(tester, dark: dark, lang: lang, h: 5150);
        final l = _l(lang);
        expect(find.text(l.slStart), findsOneWidget);
        for (final t in [l.slSceneEmbers, l.slLayerCrackle, l.slVelourList, l.slAlarmTime, l.slSunriseMin, l.slMorningScreen, l.slPhoneBackup, l.slJoin, l.slBrightnessNight, l.slCriticalHostDown, l.slReminder]) {
          expect(find.text(t), findsWidgets, reason: t);
        }
        expect(tester.takeException(), isNull);
        await golden('png/sleep_screen_off_${theme}_$lang.png');
      });
    }

    for (final (theme, dark, lang) in [('dark', true, 'tr'), ('light', false, 'en')]) {
      _widgets('uyurken (kahraman + makineler; laptop koptu) $theme $lang', (tester) async {
        FakeAgent.sleep.sleeping();
        FakeAgent.sleep.hosts['argo']!
          ..memberStates = {'laptop': 'down'}
          ..groupError = 'agent.sleep.memberDown';
        await _open(tester, dark: dark, lang: lang, h: 1500);
        final l = _l(lang);
        expect(find.text(l.slWake), findsOneWidget);
        expect(find.textContaining(l.slPhaseFade), findsOneWidget);
        expect(find.text(l.slDdcWarning('argo (PC)')), findsOneWidget);
        expect(find.text(l.slErrMemberDownHost('atlas')), findsOneWidget);
        expect(find.text(l.gmStateDown), findsWidgets);
        expect(tester.takeException(), isNull);
        await golden('png/sleep_screen_running_${theme}_$lang.png');
      });
    }

    _widgets('alarm çalarken kahraman: Ertele / Kapat (koyu, TR)', (tester) async {
      FakeAgent.sleep.sleeping(ringing: true);
      await _open(tester, dark: true, h: 900);
      expect(find.text(_tr.slSnoozeFor(9)), findsOneWidget);
      await golden('png/sleep_screen_ringing_dark_tr.png');
      await tester.tap(find.text(_tr.slSnoozeFor(9)));
      await _load(tester);
      expect(_calls('POST', '/v1/sleep/alarm').map((c) => (c.$3 as Map)['action']), ['snooze', 'snooze']);
    });

    _widgets('kısmi hata: hangi host başlamadı; yeniden dene / tek makineyle sür (açık, TR)', (tester) async {
      FakeAgent.sleep.configured();
      FakeAgent.sleep.hosts['atlas']!.startError = const AgentError('net.unreachable');
      await _open(tester, h: 1000);
      await tester.tap(find.text(_tr.slStart));
      await _load(tester);
      expect(find.text(_tr.slStartFailedSome), findsOneWidget);
      expect(find.text('atlas: ${_tr.agentUnreachable}'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/sleep_screen_failed_light_tr.png');
      FakeAgent.sleep.hosts['atlas']!.startError = null;
      final id = FakeAgent.sleep.hosts['argo']!.session!['id'];
      FakeAgent.calls.clear();
      await tester.tap(find.text(_tr.commonRetry));
      await _load(tester);
      final retry = _calls('POST', '/v1/sleep/start').single;
      expect(((retry.$3 as Map)['session'] as Map)['id'], id, reason: 'aynı oturum');
      expect(find.text(_tr.slStartFailedSome), findsNothing);
    });

    _widgets('hiçbiri başlamazsa "tek makineyle sür" lideri tek başına başlatır', (tester) async {
      FakeAgent.sleep.configured();
      FakeAgent.sleep.hosts['argo']!.startError = const AgentError('agent.sleep.noGroup', {}, 409);
      FakeAgent.sleep.hosts['atlas']!.startError = const AgentError('agent.sleep.noGroup', {}, 409);
      await _open(tester, h: 1100);
      await tester.tap(find.text(_tr.slStart));
      await _load(tester);
      expect(find.text(_tr.slStartFailedAll), findsOneWidget);
      expect(find.textContaining(_tr.slErrNoGroup), findsNWidgets(2));
      FakeAgent.sleep.hosts['argo']!.startError = null;
      FakeAgent.calls.clear();
      await tester.tap(find.text(_tr.slStartAlone));
      await _load(tester);
      final s = _calls('POST', '/v1/sleep/start').single;
      expect((((s.$3 as Map)['session'] as Map)['members'] as List).single, {'host': 'theloth', 'side': 'left', 'distance': 'mid'});
      expect(FakeAgent.sleep.hosts['argo']!.running, isTrue);
    });

    _widgets('grup ayarı iki makineye, makine ayarı yalnız ona; parlaklık canlı önizlenir', (tester) async {
      FakeAgent.sleep.configured();
      await _open(tester, h: 5600);
      await tester.tap(find.text(_tr.slLayerWind));
      await _load(tester);
      expect(_calls('PUT', '/v1/sleep').map((c) => c.$3), [
        {
          'settings': {
            'layers': {'wind': true},
          },
        },
        {
          'settings': {
            'layers': {'wind': true},
          },
        },
      ]);
      expect(FakeAgent.sleep.hosts.values.map((h) => h.settings['layers']['wind']), [true, true]);
      FakeAgent.calls.clear();
      // The second machine card's "Sağ" (atlas is on the right): only atlas gets it.
      await tester.tap(find.text(_tr.slSideLeft).last);
      await _load(tester);
      expect(_calls('PUT', '/v1/sleep').single.$3, {
        'settings': {'side': 'left'},
      });
      expect(FakeAgent.sleep.hosts['atlas']!.settings['side'], 'left');
      expect(FakeAgent.sleep.hosts['argo']!.settings['side'], 'left');
      FakeAgent.calls.clear();
      final night = find.bySemanticsLabel(_tr.slBrightnessNight).first;
      await tester.drag(night, const Offset(60, 0));
      await _load(tester);
      expect(_calls('POST', '/v1/sleep/preview'), isNotEmpty);
      expect(_calls('PUT', '/v1/sleep').last.$3, isA<Map>());
      expect((((_calls('PUT', '/v1/sleep').last.$3 as Map)['settings'] as Map)['brightness'] as Map).keys, ['night']);
    });

    _widgets('alarm ayarları: saat, günler, ses; eksik blok güncelleme ister', (tester) async {
      FakeAgent.sleep.configured();
      for (final h in FakeAgent.sleep.hosts.values) {
        h.settings.remove('notify');
      }
      await _open(tester, h: 5600);
      await tester.tap(find.bySemanticsLabel(_tr.slDaySat));
      await _load(tester);
      expect(FakeAgent.sleep.hosts['argo']!.settings['alarm']['days'], [1, 2, 3, 4, 5, 6]);
      expect(FakeAgent.sleep.hosts['atlas']!.settings['alarm']['days'], [1, 2, 3, 4, 5, 6]);
      await tester.tap(find.bySemanticsLabel(_tr.slDaySat));
      await _load(tester);
      expect(FakeAgent.sleep.hosts['argo']!.settings['alarm']['days'], 'weekdays');
      await tester.tap(find.text(_tr.slSoundChime));
      await _load(tester);
      expect(FakeAgent.sleep.hosts.values.map((h) => h.settings['alarm']['sound']), ['chime', 'chime']);
      expect(find.text(_tr.slNeedsUpdate), findsOneWidget, reason: 'Bildirimler bloğu yok');
    });

    for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'en')]) {
      _widgets('sabah özeti kartı $theme $lang', (tester) async {
        FakeAgent.sleep.configured();
        final m = SleepMorning.fromParams(_morning(), at: DateTime.now().subtract(const Duration(minutes: 20)));
        await _open(tester, dark: dark, lang: lang, h: 1300, route: '/screen/sleep?morning=${Uri.encodeQueryComponent(jsonEncode(m.toJson()))}');
        final l = _l(lang);
        expect(find.text(l.slMorningCardTitle), findsOneWidget);
        expect(find.text('Yedek tamamlandı: notes'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/sleep_morning_${theme}_$lang.png');
        await tester.tap(find.byTooltip(l.commonClose));
        await _load(tester);
        expect(find.text(l.slMorningCardTitle), findsNothing);
      });
    }

    _widgets('eski ajanlar: güncelleme gerekiyor (açık, TR)', (tester) async {
      FakeAgent.sleep.unsupported.addAll(['argo', 'atlas']);
      await _open(tester, h: 760);
      expect(find.text(_tr.slNeedsUpdate), findsOneWidget);
      await golden('png/sleep_needs_update_light_tr.png');
    });
  });

  group('kurulum sihirbazı', () {
    for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'en')]) {
      _widgets('sihirbaz $theme $lang', (tester) async {
        await _open(tester, dark: dark, lang: lang, h: 900);
        final l = _l(lang);
        expect(find.text(l.slWizardMachines), findsOneWidget);
        expect(find.text(l.slWizardStep(1, 4)), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/sleep_wizard_${theme}_$lang.png');
      });
    }

    _widgets('akış: makineler, lider, yerleşim, DDC testi; Bitir her makineye yazar', (tester) async {
      await _open(tester, h: 1400);
      await tester.tap(find.text(_tr.commonContinue));
      await _load(tester);
      expect(find.text(_tr.slWizardLeader), findsOneWidget);
      expect(find.text(_tr.slWizardHasVelour), findsOneWidget);
      await tester.tap(find.text(_tr.commonContinue));
      await _load(tester);
      // atlas (laptop) stands at the foot of the bed.
      await tester.tap(find.text(_tr.slSideFoot).last);
      await tester.pump();
      await tester.tap(find.text(_tr.commonContinue));
      await _load(tester);
      expect(find.text(_tr.slWizardDdc), findsOneWidget);
      await tester.tap(find.text(_tr.slWizardDdcTest).first);
      await _load(tester);
      expect(_calls('POST', '/v1/sleep/preview').single.$3, {'brightness': 10});
      expect(find.text(_tr.slWizardDdcOk(_tr.slDimBacklight)), findsOneWidget);
      await golden('png/sleep_wizard_ddc_light_tr.png');
      expect(_calls('PUT', '/v1/sleep'), isEmpty, reason: 'Bitir’den önce hiçbir şey yazılmaz');
      await tester.tap(find.text(_tr.gmSetupFinish));
      await _load(tester);
      final st = FakeAgent.sleep.hosts;
      expect(st['atlas']!.settings['side'], 'foot');
      expect(st['argo']!.settings['group'], {
        'members': ['theloth', 'laptop'],
        'leader': 'theloth',
      });
      expect(st['atlas']!.settings['group'], st['argo']!.settings['group']);
      expect(find.byType(SleepHero), findsOneWidget);
    });
  });

  group('alarm ekranı', () {
    for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'en')]) {
      _widgets('tam ekran $theme $lang', (tester) async {
        FakeAgent.sleep.sleeping(ringing: true);
        final at = DateTime(2026, 11, 23, 7, 30).millisecondsSinceEpoch;
        await _open(tester, dark: dark, lang: lang, h: 812, route: '/screen/sleep/alarm?at=$at');
        final l = _l(lang);
        expect(find.text('07:30'), findsOneWidget);
        expect(find.text(l.slSnoozeFor(9)), findsOneWidget);
        expect(find.text(l.slAlarmMachines(2)), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/sleep_alarm_${theme}_$lang.png');
      });
    }

    _widgets('Kapat: iki makine, yedek iptal, ekran kapanır', (tester) async {
      FakeAgent.sleep.sleeping(ringing: true);
      final h = await _open(tester, h: 812, route: '/screen/sleep/alarm');
      await tester.tap(find.text(_tr.slDismiss));
      await _load(tester);
      expect(_calls('POST', '/v1/sleep/alarm'), hasLength(2));
      expect(h.sleepAlarms.backups.last, isNull);
      expect(find.byType(SleepAlarmScreen), findsNothing);
    });

    _widgets('uygulama kilitliyken alarm ekranı tek başına açılır; yalnız ertele/kapat', (tester) async {
      FakeAgent.sleep.sleeping(ringing: true);
      final h = _harness(pin: '246813');
      final c = await h.pump(tester);
      _size(tester, 375, 812);
      await _load(tester);
      expect(find.byType(LockScreen), findsOneWidget);
      c.read(sleepAlarmRequestProvider.notifier).open('/screen/sleep/alarm?at=${DateTime(2026, 11, 23, 7, 30).millisecondsSinceEpoch}');
      await _load(tester);
      expect(find.byType(SleepAlarmScreen), findsOneWidget);
      expect(find.byType(LockScreen), findsNothing);
      await tester.tap(find.text(_tr.slSnoozeFor(9)));
      await _load(tester);
      expect(_calls('POST', '/v1/sleep/alarm'), hasLength(2));
      expect(find.byType(LockScreen), findsOneWidget, reason: 'sonra uygulama kilitli kalır');
    });
  });
}
