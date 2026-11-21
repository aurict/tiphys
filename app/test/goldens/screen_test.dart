// Screen modes (PLAN.md §20 U7): the home card (closed / Work / Focus / Game), the mode chooser sheet, the screen with
// its three tabs and the Focus hero, the setup wizard with its code sharing step, the §19 fallback for an older agent,
// and the flows behind them (one-tap stop, start with a preset, hot switch, settings PUTs, explicit consent before code
// sharing is turned on at the source). Light/dark × TR/EN at 375 px.
// To update: flutter test test/goldens/screen_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/screen/screen_screen.dart';
import 'package:tiphys/features/screen/screen_sheet.dart';
import 'package:tiphys/features/screen/screen_summary.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/harness.dart';
import '../helpers/screen_fixtures.dart';

final _tr = AppLocalizationsTr();
final _en = AppLocalizationsEn();
AppLocalizations _l(String lang) => lang == 'tr' ? _tr : _en;

final _features = [...Harness.defaultAgentFeatures, 'screen', 'gamemode'];

void _size(WidgetTester tester, double w, double h) => tester.view.physicalSize = Size(w * 2, h * 2);

Future<void> _load(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await settle(tester);
}

/// testWidgets that resets the fake agent, restores the shadow setting and stops the polling and countdown timers.
void _widgets(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
  FakeAgent.resetScreen();
  FakeAgent.calls.clear();
  await body(tester);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 70));
  debugDisableShadows = true;
});

Future<Harness> _open(WidgetTester tester, {bool dark = false, String lang = 'tr', double w = 375, double h = 2600, String route = '/screen?host=argo', List<String>? features}) async {
  final harness = Harness(agentFeatures: features ?? _features);
  await harness.pump(tester, route: route, dark: dark, lang: lang);
  _size(tester, w, h);
  await _load(tester);
  return harness;
}

/// The profile still says "gameMode" (a file from before §20): the card shows as the screen mode card in its place.
Profile _homeProfile() {
  final j = jsonDecode(File('assets/profile/example.json').readAsStringSync()) as Map<String, dynamic>;
  (j['app']['home'] as Map<String, dynamic>)['cards'] = ['claude', 'system', 'gameMode', 'infra'];
  return codec.decode(jsonEncode(j)).toProfile();
}

Future<void> _home(WidgetTester tester, {bool dark = false, String lang = 'tr', double h = 760}) async {
  await Harness(profile: _homeProfile(), agentFeatures: _features).pump(tester, dark: dark, lang: lang);
  _size(tester, 375, h);
  await _load(tester);
}

/// Scrolls the page until [f] is built and visible, then taps it.
Future<void> _tapScrolled(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
  await tester.pump();
  await tester.tap(f);
}

List<(String, String, Object?)> _calls(String method, String path) => [
  for (final c in FakeAgent.calls)
    if (c.$1 == method && c.$2 == path) c,
];

Iterable<(String, void Function(FakeScreenState))> get _states => [
  ('closed', (s) {}),
  ('work', (s) => s.work()),
  ('focus', (s) => s.focus()),
  ('game', (s) => s.game()),
];

void main() {
  group('ana sayfa kartı', () {
    for (final (name, init) in _states) {
      for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'tr'), ('dark', true, 'en')]) {
        _widgets('kart $name $theme $lang', (tester) async {
          init(FakeAgent.screen);
          await _home(tester, dark: dark, lang: lang);
          final l = _l(lang);
          final host = 'argo (PC)';
          switch (name) {
            case 'closed':
              expect(find.text(l.smTitle), findsOneWidget);
              expect(find.text(l.gmOff), findsOneWidget);
              expect(find.text(l.smLastUsed(l.smModeWork, host)), findsOneWidget);
              expect(find.bySemanticsLabel(l.gmStart), findsOneWidget);
            case 'work':
              expect(find.text('${l.smModeWork} · $host'), findsOneWidget);
              expect(find.text('${l.smClaudeSessions(2)} · ${l.smJobs(1)}'), findsOneWidget);
              expect(find.textContaining(l.smMirroring('atlas')), findsOneWidget);
              expect(find.bySemanticsLabel(l.smStopAll), findsOneWidget);
            case 'focus':
              expect(find.text('${l.smModeFocus} · $host'), findsOneWidget);
              expect(find.textContaining(l.smFocusLeft('14:32')), findsOneWidget);
              expect(find.text('Ekran modları W6 uygulaması'), findsOneWidget);
            case 'game':
              expect(find.text(l.gmSceneNow(l.gmSceneMusic)), findsOneWidget);
              expect(find.text('Mavi Mavi · Sezen Aksu'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await golden('png/screen_card_${name}_${theme}_$lang.png');
        });
      }
    }

    _widgets('açıkken tek dokunuş her şeyi kapatır; karta dokununca ekran açılır', (tester) async {
      FakeAgent.screen.work();
      await _home(tester);
      await tester.tap(find.bySemanticsLabel(_tr.smStopAll));
      await _load(tester);
      expect(_calls('POST', '/v1/screen/stop'), hasLength(1));
      expect(FakeAgent.screen.running, isFalse);
      expect(find.text(_tr.gmOff), findsOneWidget);
      await tester.tap(find.text(_tr.smTitle));
      await _load(tester);
      expect(find.byType(ScreenModeScreen), findsOneWidget);
    });

    _widgets('özellik hiçbir hostta yoksa kart görünmez', (tester) async {
      await Harness(profile: _homeProfile()).pump(tester);
      await _load(tester);
      expect(find.text(_tr.smTitle), findsNothing);
    });
  });

  group('mod seçme sayfası', () {
    for (final (theme, dark, lang) in [('dark', true, 'tr'), ('light', false, 'en')]) {
      _widgets('sayfa $theme $lang', (tester) async {
        await _home(tester, dark: dark, lang: lang, h: 812);
        final l = _l(lang);
        await tester.tap(find.bySemanticsLabel(l.gmStart));
        await _load(tester);
        expect(find.byType(ScreenSheet), findsOneWidget);
        for (final m in [l.smModeWork, l.smModeFocus, l.smModeGame]) {
          expect(find.descendant(of: find.byType(ScreenSheet), matching: find.text(m)), findsOneWidget);
        }
        expect(find.text(l.smMirror('atlas')), findsOneWidget);
        expect(find.text(l.smFromSelf), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/screen_sheet_${theme}_$lang.png');
      });
    }

    _widgets('hazır düzen ("bu makinenin kendisi") kart kaynaklarını yazar, sonra başlatır', (tester) async {
      await _home(tester, h: 812);
      await tester.tap(find.bySemanticsLabel(_tr.gmStart));
      await _load(tester);
      await tester.tap(find.text(_tr.smFromSelf));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, _tr.gmStart));
      await _load(tester);
      final put = _calls('PUT', '/v1/screen').single.$3 as Map;
      final cards = ((put['settings'] as Map)['modes'] as Map)['work']['layout']['cards'] as List;
      expect(cards.map((c) => (c as Map)['source']).toSet(), {'self'});
      expect(_calls('POST', '/v1/screen/start').single.$3, {'mode': 'work'});
      expect(FakeAgent.calls.indexWhere((c) => c.$2 == '/v1/screen/start'), greaterThan(FakeAgent.calls.indexWhere((c) => c.$1 == 'PUT')));
      expect(find.byType(ScreenSheet), findsNothing);
      expect(find.text('${_tr.smModeWork} · argo (PC)'), findsOneWidget);
    });

    _widgets('açıkken aynı sayfa modlar arası sıcak geçiş yapar', (tester) async {
      FakeAgent.screen.work();
      await _open(tester, h: 2600);
      await tester.tap(find.text(_tr.smChangeMode));
      await _load(tester);
      await tester.tap(find.descendant(of: find.byType(ScreenSheet), matching: find.text(_tr.smModeFocus)));
      await tester.pump();
      await tester.tap(find.text(_tr.smSwitchTo(_tr.smModeFocus)));
      await _load(tester);
      expect(_calls('POST', '/v1/screen/mode').single.$3, {'mode': 'focus'});
      expect(_calls('POST', '/v1/screen/start'), isEmpty);
      expect(FakeAgent.screen.mode, 'focus');
    });

    _widgets('başlatma hatası dostça gösterilir', (tester) async {
      FakeAgent.screen.startError = const AgentError('agent.screen.noDisplay', {}, 503);
      await _home(tester, h: 812);
      await tester.tap(find.bySemanticsLabel(_tr.gmStart));
      await _load(tester);
      await tester.tap(find.widgetWithText(FilledButton, _tr.gmStart));
      await _load(tester);
      expect(find.text(_tr.gmErrNoDisplay), findsOneWidget);
      expect(find.byType(ScreenSheet), findsOneWidget, reason: 'sayfa açık kalır');
    });
  });

  group('ekran', () {
    for (final (tab, init, variants) in <(String, void Function(FakeScreenState), List<(String, bool, String)>)>[
      ('work', (s) => s.work(), [('light', false, 'tr'), ('dark', true, 'en')]),
      ('focus', (s) => s.focus(), [('dark', true, 'tr'), ('light', false, 'en')]),
      ('game', (s) => s.game(drive: true), [('light', false, 'tr'), ('dark', true, 'en')]),
    ]) {
      for (final (theme, dark, lang) in variants) {
        _widgets('sekme $tab $theme $lang', (tester) async {
          init(FakeAgent.screen);
          await _open(tester, dark: dark, lang: lang, route: '/screen?host=argo&tab=$tab');
          final l = _l(lang);
          expect(find.text(l.smTitle), findsWidgets);
          expect(find.text(l.gmStop), findsOneWidget);
          if (tab == 'focus') expect(find.text('14:32'), findsOneWidget);
          if (tab == 'game') expect(find.text('Bursa → Münih'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await golden('png/screen_${tab}_${theme}_$lang.png');
        });
      }
    }

    _widgets('odak kahramanı: duraklatılmış, kapalı (koyu, TR)', (tester) async {
      FakeAgent.screen.focus(paused: true);
      await _open(tester, dark: true, h: 900, route: '/screen?host=argo&tab=focus');
      expect(find.text(_tr.smFocusResume), findsOneWidget);
      expect(find.text(_tr.smFocusPaused), findsOneWidget);
      await golden('png/screen_focus_hero_paused_dark_tr.png');
    });

    // W7: the session summary card, opened from its notification (the numbers ride in the route; memory only).
    for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'en')]) {
      _widgets('oturum özeti kartı $theme $lang', (tester) async {
        final s = ScreenSummary.fromParams(
          {'minutes': 72, 'modes': 'work,focus', 'rounds': 2, 'commits': 3, 'jobs': 4, 'failed': 1, 'sessions': 2, 'waits': 5},
          host: 'argo',
          at: DateTime.now(),
          held: 6,
        );
        final q = Uri.encodeQueryComponent(jsonEncode(s.toJson()));
        await _open(tester, dark: dark, lang: lang, h: 1100, route: '/screen?host=argo&summary=$q');
        final l = _l(lang);
        expect(find.text(l.smSummaryCardTitle), findsOneWidget);
        expect(find.text('${l.smSummaryJobsLabel} · ${l.smSummaryJobsFailed(1)}'), findsOneWidget);
        await golden('png/screen_summary_${theme}_$lang.png');
        await tester.tap(find.byTooltip(l.commonClose));
        await settle(tester);
        expect(find.text(l.smSummaryCardTitle), findsNothing);
      });
    }

    _widgets('kapalı (açık, TR)', (tester) async {
      await _open(tester, h: 1000);
      expect(find.text(_tr.gmStart), findsOneWidget);
      expect(find.text(_tr.smLastUsed(_tr.smModeWork, 'argo (PC)')), findsOneWidget);
      await golden('png/screen_closed_light_tr.png');
    });

    _widgets('odak kontrolleri: duraklat, atla, sıfırla, görev; perde', (tester) async {
      FakeAgent.screen.focus();
      await _open(tester, route: '/screen?host=argo&tab=focus');
      await tester.tap(find.text(_tr.smFocusPause));
      await _load(tester);
      expect(_calls('POST', '/v1/screen/focus').last.$3, {'action': 'pause'});
      expect(find.text(_tr.smFocusResume), findsOneWidget);
      await tester.tap(find.text(_tr.smFocusSkip));
      await _load(tester);
      expect(_calls('POST', '/v1/screen/focus').last.$3, {'action': 'skip'});
      expect(find.text(_tr.smPhaseShort), findsWidgets);
      await tester.enterText(find.byType(TextField).first, 'Yeni görev');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _load(tester);
      expect(_calls('POST', '/v1/screen/focus').last.$3, {'task': 'Yeni görev'});
      await tester.tap(find.text(_tr.smFocusReset));
      await _load(tester);
      expect(_calls('POST', '/v1/screen/focus').last.$3, {'action': 'reset'});
      await tester.tap(find.text(_tr.smVeil));
      await _load(tester);
      expect(_calls('POST', '/v1/screen/veil').single.$3, {'on': true});
    });

    _widgets('ayarlar hemen PUT edilir: şehir, düzen, süre, yerleşim', (tester) async {
      FakeAgent.screen.work();
      await _open(tester, route: '/screen?host=argo&tab=work');
      Object? lastPut() => _calls('PUT', '/v1/screen').last.$3;
      await tester.tap(find.text('2D'));
      await _load(tester);
      expect(lastPut(), {
        'settings': {
          'modes': {
            'work': {'city': '2d'},
          },
        },
      });
      // Turning the Git card off writes the whole layout (template order, the card off).
      await tester.tap(find.bySemanticsLabel('Git').last);
      await _load(tester);
      final cards = (((lastPut() as Map)['settings'] as Map)['modes'] as Map)['work']['layout']['cards'] as List;
      expect(cards.firstWhere((c) => (c as Map)['kind'] == 'git'), {'kind': 'git', 'source': 'atlas', 'enabled': false});
      await tester.tap(find.text(_tr.smPlacementScratch));
      await _load(tester);
      expect(lastPut(), {
        'settings': {'placement': 'scratch'},
      });
      expect(find.text('Super + `'), findsWidgets);
      await tester.tap(find.text(_tr.smModeFocus).first);
      await _load(tester);
      await tester.tap(find.byTooltip(_tr.smMore).first);
      await _load(tester);
      expect(lastPut(), {
        'settings': {
          'modes': {
            'focus': {'focusMin': 30},
          },
        },
      });
      await tester.tap(find.text(_tr.smAmbientRain));
      await _load(tester);
      expect(FakeAgent.screen.settings['modes']['focus']['ambient'], 'rain');
    });

    _widgets('kod paylaşımı: kaynakta açmak için açık onay; vazgeçilirse hiçbir şey yazılmaz', (tester) async {
      FakeAgent.screen.work();
      await _open(tester, route: '/screen?host=argo&tab=work');
      expect(find.text(_tr.smShareIsOff('atlas')), findsOneWidget);
      await tester.tap(find.text(_tr.smShareOpen));
      await settle(tester);
      expect(find.text(_tr.smShareConfirm('atlas', 'argo (PC)')), findsOneWidget);
      await tester.tap(find.text(_tr.commonCancel));
      await _load(tester);
      expect(FakeAgent.screen.shareCode['atlas'], isFalse);
      expect(FakeAgent.calls.where((c) => c.$1 == 'PUT'), isEmpty);
      await tester.tap(find.text(_tr.smShareOpen));
      await settle(tester);
      await tester.tap(find.text(_tr.smShareOn));
      await _load(tester);
      expect(FakeAgent.screen.shareCode, {'argo': false, 'atlas': true}, reason: 'yalnız kaynakta, ekran hostunda değil');
      expect(find.text(_tr.smShareIsOn('atlas')), findsOneWidget);
    });

    _widgets('eski ajan: Oyun çalışır, Çalışma/Odak güncelleme ister (açık, TR)', (tester) async {
      FakeAgent.screen.legacy = true;
      await _open(tester, h: 1900);
      expect(find.text(_tr.smLegacyNote('argo (PC)')), findsOneWidget);
      expect(find.text(_tr.gmScene), findsOneWidget, reason: 'Oyun sekmesi açılır');
      await golden('png/screen_legacy_light_tr.png');
      await tester.tap(find.text(_tr.smModeWork).first);
      await _load(tester);
      expect(find.text(_tr.smNeedsUpdateTitle), findsOneWidget);
      await tester.tap(find.text(_tr.gmStart));
      await _load(tester);
      // The sheet offers Game only.
      await tester.tap(find.descendant(of: find.byType(ScreenSheet), matching: find.widgetWithText(FilledButton, _tr.gmStart)));
      await _load(tester);
      expect(_calls('POST', '/v1/gamemode/start'), hasLength(1));
    });

    _widgets('eski adres /gamemode Oyun sekmesine gider', (tester) async {
      FakeAgent.screen.game();
      await _open(tester, route: '/gamemode?host=argo');
      expect(find.byType(ScreenModeScreen), findsOneWidget);
      expect(find.text(_tr.gmScene), findsOneWidget);
    });

    _widgets('özellik kapalı: açıklama ve ajan ayarları', (tester) async {
      await _open(tester, h: 900, features: Harness.defaultAgentFeatures);
      expect(find.text(_tr.smFeatureOffTitle), findsOneWidget);
      await golden('png/screen_feature_off_light_tr.png');
      await tester.tap(find.text(_tr.gmFeatureOpenSettings));
      await _load(tester);
      expect(find.byType(ScreenModeScreen), findsNothing);
    });

    _widgets('kurulum: eklenti kur ve kaldır, kısayol durumu', (tester) async {
      FakeAgent.screen.game();
      await _open(tester, route: '/screen?host=argo&tab=game');
      expect(find.text(_tr.gmPluginMissing), findsOneWidget);
      expect(find.text(_tr.smBindUnused), findsOneWidget);
      await tester.tap(find.text(_tr.gmPluginInstall));
      await _load(tester);
      expect(find.text(_tr.gmPluginInstalled('1.12.1')), findsOneWidget);
    });
  });

  group('kurulum sihirbazı', () {
    for (final (theme, dark, lang) in [('dark', true, 'tr'), ('light', false, 'en')]) {
      _widgets('sihirbaz $theme $lang', (tester) async {
        await _open(tester, dark: dark, lang: lang, h: 1200);
        final l = _l(lang);
        await _tapScrolled(tester, find.text(l.smSourceAdd));
        await _load(tester);
        expect(find.text(l.gmSetupConnect), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/screen_wizard_${theme}_$lang.png');
      });
    }

    _widgets('akış: jeton, ekran ajanı, sonuç; kod paylaşımı ayrı adım ve varsayılan kapalı', (tester) async {
      FakeAgent.screen.sources.clear();
      await _open(tester, h: 1400);
      await _tapScrolled(tester, find.text(_tr.smSourceAdd));
      await _load(tester);
      await tester.tap(find.text(_tr.gmSetupConnect));
      await _load(tester);
      final st = FakeAgent.screen;
      expect(st.tokensCreated.single['scopes'], ['screen']);
      expect(st.storedTokens, {'atlas': 'tps_secret_1'});
      expect(find.textContaining('tps_'), findsNothing);
      expect(find.text(_tr.smShareStepTitle), findsOneWidget);
      expect(st.shareCode['atlas'], isFalse, reason: 'varsayılan kapalı');
      expect(_calls('POST', '/v1/screen/start'), isEmpty, reason: 'test hiçbir şey başlatmaz');
      await golden('png/screen_wizard_done_light_tr.png');
      // Turning sharing on asks first.
      await tester.tap(find.byType(Switch).last);
      await settle(tester);
      expect(find.text(_tr.smShareConfirm('atlas', 'argo (PC)')), findsOneWidget);
      await tester.tap(find.text(_tr.smShareOn));
      await _load(tester);
      expect(st.shareCode['atlas'], isTrue);
      await tester.tap(find.text(_tr.gmSetupFinish));
      await _load(tester);
      expect(find.byType(ScreenHero), findsOneWidget);
    });

    _widgets('kaynak kaldırma onaylı; jeton iptal edilir', (tester) async {
      FakeAgent.screen.tokens.add({'id': 'old-1', 'name': 'Screen mode: argo (PC)', 'scopes': ['screen']});
      await _open(tester);
      await _tapScrolled(tester, find.byTooltip(_tr.smSourceActions('atlas')));
      await settle(tester);
      await tester.tap(find.text(_tr.smSourceRemove));
      await settle(tester);
      await tester.tap(find.text(_tr.smSourceRemove).last);
      await _load(tester);
      expect(FakeAgent.screen.sources, isEmpty);
      expect(FakeAgent.screen.tokensRevoked, ['old-1']);
    });
  });
}

