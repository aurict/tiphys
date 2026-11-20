// Game mode (PLAN.md §19): the screen (off / on / driving), setup wizard, feature-off explanation, settings that PUT at
// once, start/stop in one tap, friendly errors, and the home card. Light/dark × TR/EN at 375 px, one tablet width.
// To update: flutter test test/goldens/gamemode_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/gamemode/gamemode_screen.dart';
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/gamemode_fixtures.dart';
import '../helpers/harness.dart';

final _tr = AppLocalizationsTr();
final _en = AppLocalizationsEn();

const _route = '/gamemode?host=argo';
final _features = [...Harness.defaultAgentFeatures, 'gamemode'];

void _size(WidgetTester tester, double w, double h) => tester.view.physicalSize = Size(w * 2, h * 2);

Future<void> _load(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await settle(tester);
}

/// testWidgets that restores the shadow setting and stops the screens' polling timers.
void _widgets(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
  FakeAgent.resetGame();
  FakeAgent.calls.clear();
  await body(tester);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 70));
  debugDisableShadows = true;
});

Future<void> _open(
  WidgetTester tester, {
  bool dark = false,
  String lang = 'tr',
  double w = 375,
  double h = 1900,
  String route = _route,
  List<String>? features,
}) async {
  await Harness(agentFeatures: features ?? _features).pump(tester, route: route, dark: dark, lang: lang);
  _size(tester, w, h);
  await _load(tester);
}

Profile _homeProfile() {
  final j = jsonDecode(File('assets/profile/example.json').readAsStringSync()) as Map<String, dynamic>;
  (j['app']['home'] as Map<String, dynamic>)['cards'] = ['gameMode', 'infra', 'claude', 'system'];
  return codec.decode(jsonEncode(j)).toProfile();
}

Iterable<(String, void Function(FakeGameState))> get _states => [('off', (s) {}), ('on', (s) => s.on()), ('driving', (s) => s.drive())];

void main() {
  test('kart varsayılan değil, tümünde var', () {
    expect(allHomeCards, contains('gameMode'));
    expect(defaultHomeCards, isNot(contains('gameMode')));
  });

  group('ekran', () {
    const variants = [('light', false, 'tr'), ('dark', true, 'tr'), ('light', false, 'en'), ('dark', true, 'en')];
    for (final (name, init) in _states) {
      for (final (theme, dark, lang) in variants) {
        _widgets('$name $theme $lang, 375 px', (tester) async {
          init(FakeAgent.game);
          await _open(tester, dark: dark, lang: lang);
          final l = lang == 'tr' ? _tr : _en;
          expect(find.text(l.gmTitle), findsWidgets);
          expect(find.text(name == 'off' ? l.gmStart : l.gmStop), findsOneWidget);
          if (name == 'driving') expect(find.text('Bursa → Münih'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await golden('png/gamemode_${name}_${theme}_$lang.png');
        });
      }
    }

    _widgets('tablet genişliği, sürüş', (tester) async {
      FakeAgent.game.drive();
      await _open(tester, dark: true, w: 820, h: 1500);
      expect(tester.takeException(), isNull);
      await golden('png/gamemode_driving_dark_tr_tablet.png');
    });

    _widgets('uzun şarkı ve sanatçı adı taşmaz', (tester) async {
      FakeAgent.game.on();
      FakeAgent.game.music = {
        'title': 'Bir Zamanlar Anadolu’da Çok Uzun Bir Şarkı Adı ' * 3,
        'artist': 'Sanatçı Bir ve Sanatçı İki ve Sanatçı Üç ' * 3,
        'playing': true,
      };
      await _open(tester, w: 375, h: 1900);
      expect(tester.takeException(), isNull);
      await golden('png/gamemode_long_light_tr.png');
    });

    _widgets('yükleniyor ve hata durumu', (tester) async {
      FakeAgent.game.error = const AgentError('net.unreachable');
      await _open(tester);
      expect(find.text(_tr.agentUnreachable), findsOneWidget);
      expect(find.text(_tr.commonRetry), findsOneWidget);
      FakeAgent.game.error = null;
      await tester.tap(find.text(_tr.commonRetry));
      await _load(tester);
      expect(find.text(_tr.gmStart), findsOneWidget);
    });
  });

  group('başlat / durdur', () {
    _widgets('tek dokunuşla başlar ve durur', (tester) async {
      await _open(tester);
      await tester.tap(find.text(_tr.gmStart));
      await _load(tester);
      expect(FakeAgent.calls.where((c) => c.$2 == '/v1/gamemode/start'), hasLength(1));
      expect(find.text(_tr.gmStop), findsOneWidget);
      expect(find.text(_tr.gmOnAt('argo (PC)')), findsWidgets);
      await tester.tap(find.text(_tr.gmStop));
      await _load(tester);
      expect(FakeAgent.calls.where((c) => c.$2 == '/v1/gamemode/stop'), hasLength(1));
      expect(find.text(_tr.gmStart), findsOneWidget);
      expect(FakeAgent.game.running, isFalse);
    });

    _widgets('hata dostça gösterilir (noSource, noDisplay)', (tester) async {
      await _open(tester);
      FakeAgent.game.startError = const AgentError('agent.gamemode.noDisplay', {}, 503);
      await tester.tap(find.text(_tr.gmStart));
      await _load(tester);
      expect(find.text(_tr.gmErrNoDisplay), findsOneWidget);
      expect(find.text(_tr.gmStart), findsOneWidget, reason: 'iyimser durum geri alınır');
      await tester.pump(const Duration(seconds: 5));
      FakeAgent.game.startError = const AgentError('agent.gamemode.noSource', {}, 409);
      await tester.tap(find.text(_tr.gmStart));
      await _load(tester);
      expect(find.text(_tr.gmErrNoSource), findsOneWidget);
    });
  });

  group('ayarlar', () {
    _widgets('her değişiklik hemen PUT edilir', (tester) async {
      await _open(tester);
      List<Object?> puts() => [
        for (final c in FakeAgent.calls)
          if (c.$1 == 'PUT' && c.$2 == '/v1/gamemode') c.$3,
      ];
      await tester.tap(find.text(_tr.gmSceneDrive));
      await _load(tester);
      expect(puts().last, {
        'settings': {'scene': 'drive'},
      });
      await tester.tap(find.text(_tr.gmLyrics));
      await _load(tester);
      expect(puts().last, {
        'settings': {'lyrics': false},
      });
      await tester.tap(find.text(_tr.gmMotionHigh));
      await _load(tester);
      expect(puts().last, {
        'settings': {'motion': 'high'},
      });
      await tester.tap(find.text(_tr.gmClock24));
      await _load(tester);
      expect(puts().last, {
        'settings': {'clock24': false},
      });
      await tester.tap(find.text('30'));
      await _load(tester);
      expect(puts().last, {
        'settings': {'dimIdleMinutes': 30},
      });
      expect(FakeAgent.game.settings['scene'], 'drive');
    });

    _widgets('parlaklık: dokunma kapatılınca kaydırıcı çalışır, sürüklemeden sonra tek PUT', (tester) async {
      await _open(tester);
      // "Don't touch" is on: the slider is disabled.
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      await tester.tap(find.text(_tr.gmBrightnessKeep));
      await _load(tester);
      expect(FakeAgent.game.settings['brightness'], 60);
      final before = FakeAgent.calls.where((c) => c.$1 == 'PUT').length;
      await tester.drag(find.byType(Slider), const Offset(-120, 0));
      await _load(tester);
      expect(FakeAgent.calls.where((c) => c.$1 == 'PUT').length, before + 1);
      expect(FakeAgent.game.settings['brightness'], lessThan(60));
      await tester.tap(find.text(_tr.gmBrightnessKeep));
      await _load(tester);
      expect(FakeAgent.game.settings['brightness'], isNull);
    });
  });

  group('kurulum (kaynak PC)', () {
    _widgets('eklenti ve harita durumu; kur ve kaldır', (tester) async {
      FakeAgent.game.on();
      await _open(tester);
      await tester.scrollUntilVisible(find.text(_tr.gmPlugin), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text(_tr.gmPluginMissing), findsOneWidget);
      expect(find.text(_tr.gmMapMissing), findsOneWidget);
      await tester.tap(find.text(_tr.gmPluginInstall));
      await _load(tester);
      expect(FakeAgent.calls.where((c) => c.$2 == '/v1/gamemode/plugin').first.$3, {'action': 'install'});
      expect(find.text(_tr.gmPluginInstalled('1.12.1')), findsOneWidget);
      await tester.tap(find.text(_tr.gmPluginRemove));
      await settle(tester);
      await tester.tap(find.text(_tr.gmPluginRemove).last);
      await _load(tester);
      expect(find.text(_tr.gmPluginMissing), findsOneWidget);
    });

    _widgets('Velour kumandası kaynak hostta açılır', (tester) async {
      FakeAgent.game.on();
      await _open(tester);
      await tester.scrollUntilVisible(find.text(_tr.gmOpenVelour), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text(_tr.gmOpenVelour));
      await _load(tester);
      expect(find.byType(GameModeScreen), findsNothing);
    });
  });

  group('özellik kapalı', () {
    _widgets('açıklama ve ajan ayarlarına yönlendirme', (tester) async {
      await _open(tester, features: Harness.defaultAgentFeatures);
      expect(find.text(_tr.gmFeatureOffTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/gamemode_feature_off_light_tr.png');
      await tester.tap(find.text(_tr.gmFeatureOpenSettings));
      await _load(tester);
      expect(find.byType(GameModeScreen), findsNothing);
    });

    _widgets('eski ajan (route yok): aynı açıklama', (tester) async {
      FakeAgent.game.error = const AgentError('agent.route.notFound', {}, 404);
      await _open(tester);
      expect(find.text(_tr.gmFeatureOffTitle), findsOneWidget);
    });
  });

  group('kurulum sihirbazı', () {
    _widgets('kaynak yoksa sihirbaz açılır (koyu, TR)', (tester) async {
      FakeAgent.game.configured = false;
      await _open(tester, dark: true, h: 1100);
      expect(find.text(_tr.gmSetupConnect), findsOneWidget);
      expect(find.text(_tr.gmStart), findsNothing);
      expect(tester.takeException(), isNull);
      await golden('png/gamemode_wizard_dark_tr.png');
    });

    _widgets('sihirbaz (açık, EN)', (tester) async {
      FakeAgent.game.configured = false;
      await _open(tester, lang: 'en', h: 1100);
      expect(find.text(_en.gmSetupConnect), findsOneWidget);
      await golden('png/gamemode_wizard_light_en.png');
    });

    _widgets('akış: jeton oluşturulur, ekran ajanına yazılır, test sonucu gösterilir, jeton saklanmaz', (tester) async {
      FakeAgent.game.configured = false;
      await _open(tester, h: 1100);
      // Display: argo (the route's host); source: the other host with the feature (atlas).
      await tester.tap(find.text(_tr.gmSetupConnect));
      await _load(tester);
      final st = FakeAgent.game;
      expect(st.tokensCreated.single['scopes'], ['gamemode']);
      expect(st.storedSource, {'url': 'https://atlas.example.ts.net:7443', 'token': 'tps_secret_1'});
      expect(find.text(_tr.gmSetupDoneTitle), findsOneWidget);
      expect(find.textContaining('tps_'), findsNothing);
      // Nothing was started by the test.
      expect(FakeAgent.calls.where((c) => c.$2 == '/v1/gamemode/start'), isEmpty);
      await golden('png/gamemode_wizard_done_light_tr.png');
      await tester.tap(find.text(_tr.gmSetupFinish));
      await _load(tester);
      expect(find.text(_tr.gmStart), findsOneWidget);
    });

    _widgets('hata: jeton iptal edilir ve hata gösterilir', (tester) async {
      FakeAgent.game.configured = false;
      FakeAgent.game.putError = const AgentError('net.unreachable');
      await _open(tester, h: 1100);
      await tester.tap(find.text(_tr.gmSetupConnect));
      await _load(tester);
      expect(FakeAgent.game.tokensRevoked, ['game-mode-1']);
      expect(find.text(_tr.agentUnreachable), findsOneWidget);
      expect(find.text(_tr.gmSetupConnect), findsOneWidget, reason: 'yeniden denenebilir');
    });

    _widgets('yeniden kur satırı sihirbazı açar', (tester) async {
      await _open(tester);
      await tester.scrollUntilVisible(find.text(_tr.gmReconfigure), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text(_tr.gmReconfigure));
      await _load(tester);
      expect(find.text(_tr.gmSetupConnect), findsOneWidget);
    });
  });

  group('ana sayfa kartı', () {
    Future<void> home(WidgetTester tester, {bool dark = false, String lang = 'tr'}) async {
      await Harness(profile: _homeProfile(), agentFeatures: _features).pump(tester, dark: dark, lang: lang);
      _size(tester, 375, 760);
      await _load(tester);
    }

    for (final (name, init) in _states) {
      for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'tr'), ('dark', true, 'en')]) {
        _widgets('kart $name $theme $lang', (tester) async {
          init(FakeAgent.game);
          await home(tester, dark: dark, lang: lang);
          final l = lang == 'tr' ? _tr : _en;
          expect(find.text(l.gmTitle), findsOneWidget);
          expect(find.bySemanticsLabel(name == 'off' ? l.gmStart : l.gmStop), findsOneWidget);
          expect(
            find.text(switch (name) {
              'off' => l.gmOff,
              'on' => l.gmOnAt('argo (PC)'),
              _ => l.gmDriving('Bursa', 'Münih'),
            }),
            findsOneWidget,
          );
          if (name != 'off') expect(find.text('Mavi Mavi · Sezen Aksu'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await golden('png/gamemode_card_${name}_${theme}_$lang.png');
        });
      }
    }

    _widgets('karttaki düğme tek dokunuşla açar ve kapatır; karta dokununca ekran açılır', (tester) async {
      await home(tester);
      await tester.tap(find.bySemanticsLabel(_tr.gmStart));
      await _load(tester);
      expect(FakeAgent.game.running, isTrue);
      await tester.tap(find.bySemanticsLabel(_tr.gmStop));
      await _load(tester);
      expect(FakeAgent.game.running, isFalse);
      await tester.tap(find.text(_tr.gmTitle));
      await _load(tester);
      expect(find.byType(GameModeScreen), findsOneWidget);
    });

    _widgets('kaynak kurulu değilse "Kurulum gerekli", düğme yok', (tester) async {
      FakeAgent.game.configured = false;
      await home(tester);
      expect(find.text(_tr.gmCardSetup), findsOneWidget);
      expect(find.bySemanticsLabel(_tr.gmStart), findsNothing);
    });

    _widgets('özellik hiçbir hostta yoksa kart görünmez', (tester) async {
      await Harness(profile: _homeProfile()).pump(tester);
      await _load(tester);
      expect(find.text(_tr.gmTitle), findsNothing);
    });
  });
}
