// Setup wizard (K7), health check (K6), agent update (K8), live notifications settings (K9) and the desktop panel on
// a helper backend (P1). Light/dark × TR/EN, 375 px. Data is synthetic.
// To update: flutter test test/goldens/setup_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/onboarding/onboarding_state.dart';
import 'package:tiphys/features/system/agent_update.dart';
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';
import 'package:tiphys/state/providers.dart';
import 'package:tiphys/widgets/surfaces.dart' show upper;

import '../helpers/harness.dart';

final _tr = AppLocalizationsTr();
final _en = AppLocalizationsEn();

void _size(WidgetTester tester, double w, double h) => tester.view.physicalSize = Size(w * 2, h * 2);

Future<void> _io(WidgetTester tester) async {
  // Profile and secret writes are real file I/O.
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
}

/// testWidgets that restores the shadow setting the harness changes (golden() does it too).
void _widgets(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      // Refresh timers of the screens stop with the tree.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
      debugDisableShadows = true;
    });

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.resetSetup();
    FakeAgent.desktop = sampleDesktop();
  });

  group('kurulum sihirbazı', () {
    const variants = [('light', false, 'tr'), ('dark', true, 'tr'), ('light', false, 'en'), ('dark', true, 'en')];
    for (final (theme, dark, lang) in variants) {
      _widgets('ilk açılış: tanıtım $theme $lang', (tester) async {
        await Harness(profile: Profile.empty, onboarded: false).pump(tester, dark: dark, lang: lang);
        expect(find.text(lang == 'tr' ? _tr.onbWelcomeTitle : _en.onbWelcomeTitle), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/setup_intro_${theme}_$lang.png');
      });
    }

    _widgets('atla: ana ekran, bir daha açılmaz', (tester) async {
      final h = Harness(profile: Profile.empty, onboarded: false);
      final c = await h.pump(tester);
      await tester.tap(find.text(_tr.onbSkip));
      await _io(tester);
      expect(find.text(_tr.onbWelcomeTitle), findsNothing);
      expect(c.router.routeInformationProvider.value.uri.path, '/');
      expect(c.read(onboardingSeenProvider), isTrue);
      expect(await h.vault.read(onboardingSeenKey), '1');
    });

    _widgets('host varsa ilk açılışta da gösterilmez', (tester) async {
      await Harness(onboarded: false).pump(tester);
      expect(find.text(_tr.onbWelcomeTitle), findsNothing);
    });

    for (final (theme, dark, lang) in [variants[0], variants[3]]) {
      _widgets('kurulum komutu $theme $lang', (tester) async {
        await Harness(profile: Profile.empty).pump(tester, route: '/welcome?step=install', dark: dark, lang: lang);
        expect(find.textContaining('install.sh | sh'), findsOneWidget);
        await golden('png/setup_install_${theme}_$lang.png');
      });
    }

    _widgets('kurulum komutu: Windows ve Docker, 375 px', (tester) async {
      await Harness(profile: Profile.empty).pump(tester, route: '/welcome?step=install');
      _size(tester, 375, 900);
      await tester.tap(find.text('Windows'));
      await settle(tester);
      expect(find.textContaining('install.ps1 | iex'), findsOneWidget);
      expect(find.text(upper(_tr.onbInstallRunWindows, 'tr')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/setup_install_windows_375_light_tr.png');
      await tester.tap(find.text(_tr.onbInstallDocker));
      await settle(tester);
      expect(find.textContaining('docker build'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    _widgets('eşleme: kod yapıştırılınca host eklenir, devam açılır', (tester) async {
      final h = Harness(profile: Profile.empty);
      final c = await h.pump(tester, route: '/welcome?step=pair');
      final cont = find.widgetWithText(FilledButton, _tr.commonContinue);
      expect(tester.widget<FilledButton>(cont).onPressed, isNull);
      await tester.tap(find.text(_tr.pairPasteTitle));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'nonsense');
      await tester.tap(find.text(_tr.pairPasteUse));
      await settle(tester);
      expect(find.text(_tr.pairPasteInvalid), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Adres: https://argo.my-tailnet.ts.net:7443\nToken: tph_example0123456789');
      await tester.tap(find.text(_tr.pairPasteUse));
      await _io(tester);
      final host = c.read(profileProvider).host('argo');
      expect((host?.name, host?.address, host?.agent?.url), ('argo', 'argo.my-tailnet.ts.net', 'https://argo.my-tailnet.ts.net:7443'));
      expect(await h.secrets.read('agent-argo'), 'tph_example0123456789');
      expect(find.text(_tr.onbPaired('argo')), findsOneWidget);
      expect(tester.widget<FilledButton>(cont).onPressed, isNotNull);
      await golden('png/setup_pair_light_tr.png');
    });

    for (final (theme, dark, lang) in [variants[0], variants[3]]) {
      _widgets('sağlık adımı $theme $lang', (tester) async {
        FakeAgent.doctor = sampleDoctor();
        await Harness().pump(tester, route: '/welcome?step=health&host=argo', dark: dark, lang: lang);
        _size(tester, 390, 1500);
        await settle(tester);
        expect(find.textContaining('sudo tailscale serve'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/setup_health_${theme}_$lang.png');
      });

      _widgets('özellikler adımı $theme $lang', (tester) async {
        await Harness(agentFeatures: const ['system', 'services', 'docker', 'git', 'desktop', 'control']).pump(tester, route: '/welcome?step=features&host=argo', dark: dark, lang: lang);
        _size(tester, 390, 1400);
        await settle(tester);
        expect(find.text(lang == 'tr' ? _tr.onbRiskControl : _en.onbRiskControl), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/setup_features_${theme}_$lang.png');
      });
    }

    _widgets('bitir: ana ekrana döner, işaretlenir', (tester) async {
      final h = Harness(onboarded: false);
      final c = await h.pump(tester, route: '/welcome?step=features&host=argo');
      await tester.tap(find.text(_tr.onbFinish));
      await _io(tester);
      expect(c.read(onboardingSeenProvider), isTrue);
      expect(c.router.routeInformationProvider.value.uri.path, '/');
    });

    _widgets('ayarlardaki satırdan açılır', (tester) async {
      await Harness().pump(tester, route: '/settings');
      await tester.tap(find.text(_tr.onbSettingsRow));
      await settle(tester);
      expect(find.text(_tr.onbWelcomeTitle), findsOneWidget);
    });
  });

  group('sağlık kontrolü ekranı', () {
    for (final (theme, dark, lang) in [('light', false, 'tr'), ('dark', true, 'en')]) {
      _widgets('sonuçlar $theme $lang', (tester) async {
        FakeAgent.doctor = sampleDoctor();
        await Harness().pump(tester, route: '/settings/hosts/health?id=argo', dark: dark, lang: lang);
        _size(tester, 390, 1500);
        await settle(tester);
        expect(find.text(lang == 'tr' ? _tr.doctorProblems.toUpperCase() : _en.doctorProblems.toUpperCase()), findsOneWidget);
        expect(tester.takeException(), isNull);
        await golden('png/health_${theme}_$lang.png');
      });
    }

    _widgets('eski ajan (404): ajanı güncelleyin', (tester) async {
      await Harness().pump(tester, route: '/settings/hosts/health?id=argo', lang: 'en');
      expect(find.text(_en.doctorMissingTitle), findsOneWidget);
      await golden('png/health_missing_light_en.png');
    });

    _widgets('yeniden çalıştır yeni bir istek atar', (tester) async {
      FakeAgent.doctor = sampleDoctor();
      await Harness().pump(tester, route: '/settings/hosts/health?id=argo');
      _size(tester, 390, 1500);
      await settle(tester);
      final before = FakeAgent.calls.where((c) => c.$2 == '/v1/doctor').length;
      await tester.tap(find.widgetWithText(OutlinedButton, _tr.doctorRerun));
      await settle(tester);
      expect(FakeAgent.calls.where((c) => c.$2 == '/v1/doctor').length, before + 1);
    });

    _widgets('sistem › ajan bölümünden açılır', (tester) async {
      FakeAgent.doctor = sampleDoctor();
      await Harness().pump(tester, route: '/system');
      await tester.scrollUntilVisible(find.text(_tr.doctorTitle), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text(_tr.doctorTitle));
      await settle(tester);
      expect(find.textContaining(_tr.doctorTitle), findsWidgets);
      expect(find.textContaining('sudo tailscale serve'), findsOneWidget);
    });
  });

  group('ajan güncelleme', () {
    Harness updateHarness({required List<String> versions, int tries = 5}) {
      var i = 0;
      return Harness(
        extra: [
          updateAuthProvider.overrideWithValue((_) async => true),
          updateWaitProvider.overrideWithValue((every: Duration.zero, tries: tries)),
        ],
        // Before apply the old version; afterwards the given sequence (restarting, then new).
        health: (url) async {
          final applied = FakeAgent.calls.any((c) => c.$2 == '/v1/update/apply');
          if (!applied) return {'name': 'argo', 'version': '0.3.0', 'features': {'system': true}};
          final v = versions[i < versions.length - 1 ? i++ : i];
          if (v == 'down') throw const AgentError('net.unreachable');
          return {'name': 'argo', 'version': v, 'features': {'system': true}};
        },
      );
    }

    Future<void> openRow(WidgetTester tester, String text) async {
      await tester.scrollUntilVisible(find.text(text), 300, scrollable: find.byType(Scrollable).first);
      await settle(tester);
    }

    _widgets('güncelleme var: onay, kilit, uygula, yeni sürümü bekle', (tester) async {
      FakeAgent.update = {'current': '0.3.0', 'latest': '0.4.0', 'available': true, 'managed': true, 'notesUrl': 'https://example.com/r'};
      await updateHarness(versions: ['down', 'down', '0.4.0']).pump(tester, route: '/system');
      await openRow(tester, _tr.updateAvailable('0.4.0'));
      await golden('png/system_update_light_tr.png');
      await tester.tap(find.text(_tr.updateAvailable('0.4.0')));
      await settle(tester);
      expect(find.textContaining('0.3.0 sürümünden 0.4.0'), findsOneWidget);
      await tester.tap(find.text(_tr.updateAction));
      await settle(tester);
      expect(FakeAgent.calls.where((c) => c.$2 == '/v1/update/apply').map((c) => c.$3), [{'version': '0.4.0', 'confirm': true}]);
      expect(find.textContaining('0.4.0 sürümünde'), findsOneWidget);
    });

    _widgets('zamanında gelmezse hata ve sağlık kontrolü bağlantısı', (tester) async {
      FakeAgent.update = {'current': '0.3.0', 'latest': '0.4.0', 'available': true, 'managed': true};
      await updateHarness(versions: ['down'], tries: 3).pump(tester, route: '/system', lang: 'en');
      await openRow(tester, _en.updateAvailable('0.4.0'));
      await tester.tap(find.text(_en.updateAvailable('0.4.0')));
      await settle(tester);
      await tester.tap(find.text(_en.updateAction));
      await settle(tester);
      expect(find.text(_en.updateTimeout('0.4.0')), findsOneWidget);
      await golden('png/update_timeout_light_en.png');
      await tester.tap(find.widgetWithText(TextButton, _en.doctorTitle));
      await settle(tester);
      expect(find.text(_en.doctorMissingTitle), findsOneWidget);
    });

    _widgets('ajan reddederse hata metni (özellik kapalı)', (tester) async {
      FakeAgent.update = {'current': '0.3.0', 'latest': '0.4.0', 'available': true, 'managed': true};
      FakeAgent.updateApply = const AgentError('agent.update.disabled', {}, 403);
      await updateHarness(versions: ['0.4.0']).pump(tester, route: '/system');
      await openRow(tester, _tr.updateAvailable('0.4.0'));
      await tester.tap(find.text(_tr.updateAvailable('0.4.0')));
      await settle(tester);
      await tester.tap(find.text(_tr.updateAction));
      await settle(tester);
      expect(find.text(_tr.updateErrDisabled), findsOneWidget);
    });

    _widgets('kendini güncelleyemeyen kurulum: elle güncelleme', (tester) async {
      FakeAgent.update = {'current': '0.3.0', 'latest': '0.4.0', 'available': true, 'managed': false};
      await Harness().pump(tester, route: '/system', dark: true, lang: 'en');
      await openRow(tester, _en.updateAvailable('0.4.0'));
      await tester.tap(find.text(_en.updateAvailable('0.4.0')));
      await settle(tester);
      expect(find.text(_en.updateManualTitle('0.4.0')), findsOneWidget);
      expect(FakeAgent.calls.where((c) => c.$2 == '/v1/update/apply'), isEmpty);
      await golden('png/update_manual_dark_en.png');
    });

    _widgets('ajan uygulamadan yeni: nazik uyarı', (tester) async {
      FakeAgent.statusVersion = '0.9.0';
      await Harness(agentVersion: '0.9.0').pump(tester, route: '/system');
      _size(tester, 390, 2400);
      await settle(tester);
      expect(find.text(_tr.agentNewerHint('0.9.0', kExpectedAgentVersion)), findsOneWidget);
    });
  });

  _widgets('bildirim ayarları: uygulama açıkken bölümü (açık, en)', (tester) async {
    await Harness().pump(tester, route: '/settings/notifications', lang: 'en');
    expect(find.text(_en.liveNotifyHint), findsOneWidget);
    await golden('png/notifications_live_light_en.png');
  });

  group('masaüstü: yardımcı arka uç', () {
    _widgets('macOS: olmayanlar gizli, kısa not', (tester) async {
      FakeAgent.capabilities = sampleMacCaps();
      await Harness().pump(tester, route: '/system/desktop?host=argo', lang: 'en');
      _size(tester, 390, 1300);
      await _io(tester); // icons decode in real time
      expect(find.textContaining('Not available on macOS: window thumbnails, workspaces'), findsOneWidget);
      expect(find.text(_en.desktopWorkspaces.toUpperCase()), findsNothing);
      expect(find.text(_en.moonlightEntry), findsNothing);
      expect(find.text(_en.desktopScreenOff), findsNothing);
      // No thumbnails requested from a backend without them.
      expect(FakeAgent.calls.where((c) => c.$2.endsWith('/thumb')), isEmpty);
      expect(tester.takeException(), isNull);
      await golden('png/desktop_helper_macos_light_en.png');
    });

    _widgets('yardımcı yok: neden çalışmadığı', (tester) async {
      FakeAgent.capabilities = {'backend': 'helper', 'capabilities': <String>[], 'error': 'agent.desktop.helperMissing'};
      await Harness().pump(tester, route: '/system/desktop?host=argo');
      expect(find.text(_tr.desktopHelperDown), findsOneWidget);
      expect(find.text(_tr.desktopErrHelperMissing), findsOneWidget);
      expect(find.text(_tr.desktopWindows.toUpperCase()), findsNothing);
    });

    _widgets('eski ajan (rota yok): Hyprland, her şey görünür', (tester) async {
      await Harness().pump(tester, route: '/system/desktop?host=argo');
      expect(find.text(_tr.desktopWorkspaces.toUpperCase()), findsOneWidget);
      expect(find.textContaining('üzerinde yok'), findsNothing);
    });
  });
}
