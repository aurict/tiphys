// 11.2/11.3 Firefox bridge, phone screens: tabs sheet (light TR, dark EN, empty, not connected → setup card,
// multi-select), tabs sheet actions (tap = switch, swipe = close + undo, multi-close confirmation, new tab
// validation, live SSE update, send to phone), per-tab page, reader view (TR, summarize with Claude, password
// page refusal), page remote (media card, scrolling, typing), permission card; the "Tarayıcı" row in the desktop
// panel; Tabs / Send to phone / Close window (agent endpoint) / media card from the live screen strip. Fake agent;
// nothing reaches the PC. To update: flutter test test/goldens/browser_test.dart --update-goldens
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/desktop/browser.dart';
import 'package:tiphys/features/desktop/browser_screen.dart';
import 'package:tiphys/features/desktop/desktop_data.dart';
import 'package:tiphys/features/desktop/live_stream.dart';
import 'package:tiphys/features/desktop/remote_strip.dart';
import 'package:tiphys/features/system/media.dart';

import '../helpers/harness.dart';
import 'live_screen_test.dart' show FakeLive, desktopPng, frameBytes;

const _connected = {'connected': true, 'version': 1, 'ext': '0.1.0', 'permissions': {'content': true}};

Future<void> _wait(WidgetTester tester) async {
  // Favicons are decoded in real time.
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
  debugDisableShadows = true;
}

List<String> _posts() => [for (final c in FakeAgent.calls.where((c) => c.$1 == 'POST')) '${c.$2}${c.$3 is Map && (c.$3 as Map).isNotEmpty ? ' ${c.$3}' : ''}'];

/// Send-to-phone calls.
final _opened = <String>[];

Harness _harness() => Harness(extra: [
      controlAuthProvider.overrideWithValue((_) async => true),
      phoneOpenerProvider.overrideWithValue((url) async {
        _opened.add(url);
        return true;
      }),
    ]);

/// Opens the sheet on top of the desktop panel.
Future<void> _open(WidgetTester tester, Widget page, {bool dark = false, String lang = 'tr'}) async {
  await _harness().pump(tester, route: '/system/desktop?host=argo', dark: dark, lang: lang);
  unawaited(tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => page)));
  await _wait(tester);
}

BrowserTab _tab(int id) => parseTabs(sampleTabs()).firstWhere((t) => t.id == id);

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.browser = Map.of(_connected);
    FakeAgent.browserTabs = sampleTabs();
    FakeAgent.browserPage.clear();
    FakeAgent.browserEvents = StreamController.broadcast();
    FakeAgent.browserSubscribers = 0;
    _opened.clear();
  });
  tearDown(() => FakeAgent.browser = null);

  group('sekme sayfası', () {
    testWidgets('açık TR: pencereye göre gruplar, etkin sekme, rozetler, uzun başlık', (tester) async {
      await _open(tester, const BrowserTabsScreen(hostId: 'argo'));
      expect(find.text('Sekmeler'), findsOneWidget);
      expect(find.text('PENCERE 1 · 4 SEKME'), findsOneWidget);
      expect(find.text('Tiphys — uzaktan kontrol'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Tiphys — uzaktan kontrol, github\.com, etkin sekme$')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Gelen kutusu \(3\) — Posta, mail\.example\.com, sabitli$')), findsOneWidget);
      expect(FakeAgent.browserSubscribers, 1);
      expect(tester.takeException(), isNull);
      await golden('png/browser_tabs_light_tr.png');
      // Search filters.
      await tester.enterText(find.byType(TextField), 'istanbul');
      await settle(tester);
      expect(find.text('Hava durumu — İstanbul'), findsOneWidget);
      expect(find.text('Tiphys — uzaktan kontrol'), findsNothing);
      await tester.enterText(find.byType(TextField), 'yok-boyle');
      await settle(tester);
      expect(find.text('Aramaya uyan sekme yok.'), findsOneWidget);
      // Live update (SSE).
      await tester.enterText(find.byType(TextField), '');
      FakeAgent.browserEvents.add(('tabs', jsonEncode({'tabs': sampleTabs().take(1).toList()})));
      await settle(tester);
      expect(find.text('Tiphys — uzaktan kontrol'), findsNothing);
      expect(find.text('PENCERE 1 · 1 SEKME'), findsOneWidget);
      await _finish(tester);
      expect(FakeAgent.browserSubscribers, 0, reason: 'sayfa kapanınca akış kapanır');
    });

    testWidgets('koyu EN', (tester) async {
      await _open(tester, const BrowserTabsScreen(hostId: 'argo'), dark: true, lang: 'en');
      expect(find.text('WINDOW 2 · 2 TABS'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/browser_tabs_dark_en.png');
      await _finish(tester);
    });

    testWidgets('boş', (tester) async {
      FakeAgent.browserTabs = [];
      await _open(tester, const BrowserTabsScreen(hostId: 'argo'));
      expect(find.text('Açık sekme yok.'), findsOneWidget);
      await golden('png/browser_tabs_empty_light_tr.png');
      await _finish(tester);
    });

    testWidgets('bağlı değil: kurulum kartı, oturum istenmez; kopyala; yeniden dene bağlanınca liste gelir', (tester) async {
      FakeAgent.browser = {'connected': false, 'version': null, 'ext': null, 'permissions': {'content': false}};
      await _open(tester, const BrowserTabsScreen(hostId: 'argo'));
      expect(find.text('Firefox köprüsü bağlı değil'), findsOneWidget);
      expect(find.text(browserInstallCommand), findsOneWidget);
      expect(find.text('xpinstall.signatures.required'), findsOneWidget);
      expect(FakeAgent.calls.where((c) => c.$2 == '/v1/desktop/control/session'), isEmpty);
      expect(tester.takeException(), isNull);
      await golden('png/browser_setup_light_tr.png');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(find.byTooltip('Kopyala: $browserInstallCommand'));
      await settle(tester);
      expect(find.text('Kopyalandı'), findsOneWidget);
      FakeAgent.browser = Map.of(_connected);
      await tester.ensureVisible(find.text('Tekrar dene'));
      await tester.tap(find.text('Tekrar dene'));
      await _wait(tester);
      expect(find.text('Tiphys — uzaktan kontrol'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('eski ajan / oturum bitti: hata kartı', (tester) async {
      await _open(tester, const BrowserTabsScreen(hostId: 'argo'));
      FakeAgent.browserEvents.addError(const AgentError('agent.control.sessionRequired', {}, 403));
      await settle(tester);
      expect(find.textContaining('Kontrol oturumu'), findsWidgets);
      expect(find.text('Tekrar dene'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('dokun = sekmeye geç; kaydır = kapat + geri al; yeni sekme doğrulanır', (tester) async {
      debugDisableShadows = true;
      await _open(tester, const BrowserTabsScreen(hostId: 'argo'));
      await tester.tap(find.text('Lo-fi çalışma müziği · canlı yayın'));
      await settle(tester);
      expect(_posts(), ['/v1/desktop/control/session {minutes: 15}', '/v1/desktop/browser/tabs/13/activate']);
      expect(FakeAgent.headersByPath['/v1/desktop/browser/tabs/13/activate'], {'X-Tiphys-Control': 'tpc_fake'});
      expect(find.text('Sekmeye geçildi'), findsOneWidget);

      await tester.drag(find.text('Hava durumu — İstanbul'), const Offset(-400, 0));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/close {ids: [21]}');
      expect(find.text('Hava durumu — İstanbul'), findsNothing);
      await tester.tap(find.text('Kapatılanı geri aç'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/restore');
      expect(find.text('Son kapatılan sekme geri açıldı'), findsOneWidget);

      await tester.tap(find.byTooltip('Yeni sekme'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'javascript:alert(1)');
      await tester.tap(find.text('Aç'));
      await settle(tester);
      expect(find.text('Geçerli bir http/https adresi yazın'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'example.com');
      await tester.tap(find.text('Aç'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs {url: https://example.com}');
      await tester.tap(find.byTooltip('Kapatılanı geri aç'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/restore');
      // No tap target smaller than 44 px.
      for (final e in find.byType(IconButton).evaluate()) {
        final s = tester.getSize(find.byWidget(e.widget));
        expect(s.height, greaterThanOrEqualTo(44));
      }
      await _finish(tester);
    });

    testWidgets('kaydır = kapat, ekrandan çıkınca "geri aç" bildirimi de kapanır (eski context kullanılmaz)', (tester) async {
      await _open(tester, const BrowserTabsScreen(hostId: 'argo'));
      await tester.drag(find.text('Hava durumu — İstanbul'), const Offset(-400, 0));
      await settle(tester);
      expect(find.text('Kapatılanı geri aç'), findsOneWidget);
      await tester.tap(find.byTooltip('Geri'));
      await settle(tester);
      expect(find.byType(BrowserTabsScreen), findsNothing);
      expect(find.text('Kapatılanı geri aç'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(_posts().where((p) => p.endsWith('/restore')), isEmpty);
      await _finish(tester);
    });

    testWidgets('basılı tut = çoklu seçim; seçilenleri kapat onaylı', (tester) async {
      await _open(tester, const BrowserTabsScreen(hostId: 'argo'));
      await tester.longPress(find.text('Gelen kutusu (3) — Posta'));
      await settle(tester);
      await tester.tap(find.text('Lo-fi çalışma müziği · canlı yayın'));
      await settle(tester);
      expect(find.text('2 seçili'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/browser_tabs_select_light_tr.png');
      await tester.tap(find.byTooltip('Sekmeleri kapat'));
      await settle(tester);
      expect(find.text('2 sekme kapatılsın mı?'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await settle(tester);
      expect(_posts().where((p) => p.contains('/browser/')), isEmpty);
      await tester.tap(find.byTooltip('Sekmeleri kapat'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Sekmeleri kapat'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/close {ids: [11, 13]}');
      expect(find.text('2 seçili'), findsNothing);
      await _finish(tester);
    });

    testWidgets('sekme sayfası: telefona al, sabitle, sessize al', (tester) async {
      await _open(tester, const BrowserTabsScreen(hostId: 'argo'));
      await tester.tap(find.byTooltip('Sekme işlemleri').at(1));
      await settle(tester);
      expect(find.text('Telefona al'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/browser_tab_sheet_light_tr.png');
      await tester.tap(find.text('Telefona al'));
      await settle(tester);
      expect(_opened, ['https://github.com/example/tiphys']);
      await tester.tap(find.byTooltip('Sekme işlemleri').first);
      await settle(tester);
      expect(find.text('Sabitlemeyi kaldır'), findsOneWidget);
      await tester.tap(find.text('Sabitlemeyi kaldır'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/11/pin');
      // No send-to-phone on an about: tab.
      await tester.dragUntilVisible(find.text('Ayarlar').last, find.byType(CustomScrollView), const Offset(0, -200));
      await tester.tap(find.byTooltip('Sekme işlemleri').last);
      await settle(tester);
      expect(find.text('Telefona al'), findsNothing);
      await tester.tap(find.text('Sessize al'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/22/mute');
      await _finish(tester);
    });
  });

  group('sayfa içeriği', () {
    testWidgets('okuma görünümü TR: başlık, yazar, başlıklar/listeler; yazı boyutu; Claude\'a özetlet', (tester) async {
      await _open(tester, BrowserReaderScreen(hostId: 'argo', tab: _tab(14), content: true));
      expect(find.text('Hyprland pencere kuralları'), findsOneWidget);
      expect(find.text('Ayşe Yılmaz · Örnek Wiki'), findsOneWidget);
      expect(find.text('Temel kullanım'), findsOneWidget);
      expect(find.text('Çalışma alanına taşı'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/browser_reader_light_tr.png');
      final before = tester.getSize(find.text('Temel kullanım')).height;
      await tester.tap(find.byTooltip('Yazıyı büyüt'));
      await settle(tester);
      expect(tester.getSize(find.text('Temel kullanım')).height, greaterThan(before));
      await tester.tap(find.text('Claude\'a özetlet'));
      await settle(tester);
      expect(find.textContaining('Bu web sayfasını Türkçe olarak kısaca özetle'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('okuma: şifre alanı olan sayfa nazikçe reddedilir', (tester) async {
      debugDisableShadows = true;
      FakeAgent.browserPage['reader'] = const AgentError('agent.browser.passwordField', {}, 409);
      await _open(tester, BrowserReaderScreen(hostId: 'argo', tab: _tab(11), content: true));
      expect(find.text('Bu sayfada şifre alanı var; güvenlik için okunmuyor ve yazılmıyor.'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('izin yok: kart; izin verilince yeniden dene ile okunur', (tester) async {
      FakeAgent.browser = {'connected': true, 'permissions': {'content': false}};
      await _open(tester, BrowserReaderScreen(hostId: 'argo', tab: _tab(14), content: false));
      expect(find.text('Sayfa içeriği izni gerekli'), findsOneWidget);
      expect(FakeAgent.calls.where((c) => c.$2.endsWith('/reader')), isEmpty);
      expect(tester.takeException(), isNull);
      await golden('png/browser_permission_light_tr.png');
      FakeAgent.browser = Map.of(_connected);
      await tester.tap(find.text('Tekrar dene'));
      await _wait(tester);
      expect(find.text('Temel kullanım'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('sayfa kumandası: medya kartı, kaydırma, yazı gönder; medya yoksa nazik hata', (tester) async {
      await _open(tester, BrowserPageScreen(hostId: 'argo', tab: _tab(13), content: true));
      expect(find.text('Sayfadaki video ya da ses'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Oynat / Duraklat'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/13/media {action: toggle}');
      expect(find.text('Video · 12:34 / 45:10'), findsOneWidget);
      await tester.tap(find.text('1.5×'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/13/media {action: rate, rate: 1.5}');
      await tester.tap(find.byTooltip('10 sn ileri'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/13/media {action: seek, seconds: 10.0}');
      await tester.tap(find.byTooltip('Aşağı kaydır'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/13/scroll {fraction: 0.85}');
      expect(find.text('%42'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/browser_page_light_tr.png');
      await tester.enterText(find.byType(TextField), 'merhaba dünya');
      await tester.ensureVisible(find.text('Gönder'));
      await tester.tap(find.text('Gönder'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/13/text {text: merhaba dünya}');
      expect(find.text('Metin yazı alanına gönderildi'), findsOneWidget);
      FakeAgent.browserPage['media'] = const AgentError('agent.browser.noMedia', {}, 404);
      await tester.tap(find.byTooltip('10 sn geri'));
      await settle(tester);
      expect(find.text('Bu sayfada video ya da ses yok.'), findsOneWidget);
      await _finish(tester);
    });
  });

  testWidgets('375 px: sekmeler, kurulum, okuma, sayfa kumandası taşmaz', (tester) async {
    debugDisableShadows = true;
    for (final page in <Widget>[
      const BrowserTabsScreen(hostId: 'argo'),
      BrowserReaderScreen(hostId: 'argo', tab: _tab(14), content: true),
      BrowserPageScreen(hostId: 'argo', tab: _tab(14), content: true),
    ]) {
      await _open(tester, page);
      tester.view.physicalSize = const Size(375 * 2, 667 * 2);
      await _wait(tester);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    }
    FakeAgent.browser = {'connected': false, 'permissions': {'content': false}};
    await _open(tester, const BrowserTabsScreen(hostId: 'argo'));
    tester.view.physicalSize = const Size(375 * 2, 667 * 2);
    await _wait(tester);
    expect(find.text('Firefox köprüsü bağlı değil'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('masaüstü paneli: "Tarayıcı" satırı (eski ajanda yok) sekme sayfasını açar', (tester) async {
    debugDisableShadows = true;
    await _harness().pump(tester, route: '/system/desktop?host=argo');
    await _wait(tester);
    await tester.dragUntilVisible(find.text('Tarayıcı'), find.byType(CustomScrollView), const Offset(0, -200));
    expect(find.text('Firefox bağlı · sekmeler, okuma görünümü'), findsOneWidget);
    await tester.tap(find.text('Tarayıcı'));
    await _wait(tester);
    expect(find.byType(BrowserTabsScreen), findsOneWidget);
    expect(find.text('Tiphys — uzaktan kontrol'), findsOneWidget);
    await _finish(tester);
  });

  group('canlı ekran şeridi', () {
    Future<FakeLive> start(WidgetTester tester, List<FakeLive> conns, String cls, {String title = 'Tiphys — Mozilla Firefox'}) async {
      await Harness(extra: [
        controlAuthProvider.overrideWithValue((_) async => true),
        phoneOpenerProvider.overrideWithValue((url) async {
          _opened.add(url);
          return true;
        }),
        liveConnectorProvider.overrideWithValue((host, token, query) async {
          final c = FakeLive(query);
          conns.add(c);
          return c;
        }),
      ]).pump(tester, route: '/system/desktop/live?host=argo');
      final c = conns.single;
      c.hello();
      c.ctrl.add(frameBytes(1, desktopPng(), 480, 270));
      c.ctrl.add(jsonEncode({'type': 'focus', 'address': '0x55d1a0', 'class': cls, 'initialClass': cls, 'title': title, 'pid': 1, 'workspace': 1, 'appId': null}));
      await _wait(tester);
      return c;
    }

    testWidgets('Firefox: Sekmeler sayfası açılır, sekmeye geçince canlı ekrana döner; Telefona al etkin sekmeyi açar', (tester) async {
      debugDisableShadows = true;
      final conns = <FakeLive>[];
      final c = await start(tester, conns, 'firefox');
      await tester.dragUntilVisible(find.text('Telefona al'), find.byType(LiveRemoteStrip), const Offset(-80, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Telefona al'));
      await settle(tester);
      expect(_opened, ['https://github.com/example/tiphys']);
      await tester.dragUntilVisible(find.text('Sekmeler'), find.byType(LiveRemoteStrip), const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Sekmeler'));
      await _wait(tester);
      expect(find.byType(BrowserTabsScreen), findsOneWidget);
      await tester.tap(find.text('Hava durumu — İstanbul'));
      await _wait(tester);
      expect(_posts().last, '/v1/desktop/browser/tabs/21/activate');
      expect(find.byType(BrowserTabsScreen), findsNothing);
      expect(find.byType(LiveRemoteStrip), findsOneWidget);
      expect(c.input, isEmpty, reason: 'kısayol gönderilmedi');
      await _finish(tester);
    });

    testWidgets('genel: "Pencereyi kapat" Alt+F4 değil, onaydan sonra ajanın pencere kapatma ucu', (tester) async {
      debugDisableShadows = true;
      final conns = <FakeLive>[];
      final c = await start(tester, conns, 'org.example.unknown', title: 'Bilinmeyen');
      await tester.tap(find.byTooltip('Tüm kumandalar'));
      await settle(tester);
      expect(find.text('Alt+F4'), findsNothing);
      await tester.tap(find.text('Pencereyi kapat'));
      await settle(tester);
      expect(find.text('“Pencereyi kapat” PC\'ye gönderilsin mi?'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await settle(tester);
      expect(_posts().where((p) => p.endsWith('/close')), isEmpty);
      await tester.tap(find.byTooltip('Tüm kumandalar'));
      await settle(tester);
      await tester.tap(find.text('Pencereyi kapat'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Pencereyi kapat'));
      await settle(tester);
      expect(_posts().last, '/v1/desktop/windows/0x55d1a0/close');
      expect(FakeAgent.headersByPath['/v1/desktop/windows/0x55d1a0/close'], {'X-Tiphys-Control': 'tpc_fake'});
      expect(c.input, isEmpty);
      await _finish(tester);
    });

    testWidgets('mpv: Medya düğmesi medya kartını açar', (tester) async {
      debugDisableShadows = true;
      final conns = <FakeLive>[];
      await start(tester, conns, 'mpv', title: 'film.mkv - mpv');
      await tester.tap(find.text('Medya'));
      await _wait(tester);
      expect(find.byType(MediaScreen), findsOneWidget);
      await _finish(tester);
    });
  });
}
