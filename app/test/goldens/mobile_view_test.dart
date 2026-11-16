// 11.4 Mobile view, phone screen: recorded mousepad (GTK3, light TR) and Firefox (web content, dark EN) trees,
// partial tree strip, unsupported-app card, missing-helper card, password field confirmation, context actions,
// tap → agent actions (with token), SSE "changed" → re-read, DELETE on exit; entry points: the window menu in the
// desktop panel and the live screen strip (preview from the same stream; the view follows focus changes).
// Rendered at 375 px width. Fake agent; nothing reaches the PC.
// To update: flutter test test/goldens/mobile_view_test.dart --update-goldens
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/desktop/desktop_data.dart';
import 'package:tiphys/features/desktop/live_screen.dart';
import 'package:tiphys/features/desktop/live_stream.dart';
import 'package:tiphys/features/desktop/mobile_view_screen.dart';

import '../helpers/harness.dart';
import 'live_screen_test.dart' show FakeLive, desktopPng, frameBytes;

Future<void> _wait(WidgetTester tester) async {
  // The thumbnail is decoded in real time.
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

final _live = <FakeLive>[];

Harness _harness() => Harness(extra: [
      controlAuthProvider.overrideWithValue((_) async => true),
      liveConnectorProvider.overrideWithValue((host, token, query) async {
        final c = FakeLive(query);
        _live.add(c);
        return c;
      }),
    ]);

/// Opens the mobile view on top of the desktop panel (375 px width).
Future<void> _open(WidgetTester tester, {String address = '0x55d1a0', bool dark = false, String lang = 'tr'}) async {
  await _harness().pump(tester, route: '/system/desktop?host=argo', dark: dark, lang: lang);
  tester.view.physicalSize = const Size(375 * 2, 812 * 2);
  unawaited(tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => MobileViewScreen(hostId: 'argo', address: address))));
  await _wait(tester);
}

/// Mobile view actions sent to the agent (excluding the generation).
List<String> _posts() => [
      for (final c in FakeAgent.calls)
        if (c.$1 == 'POST' && c.$2.startsWith('/v1/desktop/ui/')) '${c.$2.split('/').last} ${{...c.$3 as Map}..remove('gen')..remove('address')}',
    ];

/// The mobile view's vertical scrollable (not the panel below or the horizontal chip strips).
final _scroll = find.descendant(of: find.byType(CustomScrollView).last, matching: find.byType(Scrollable)).first;

int _gets() => FakeAgent.calls.where((c) => c.$1 == 'GET' && c.$2 == '/v1/desktop/ui').length;

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.headersByPath.clear();
    FakeAgent.resetUi();
    FakeAgent.desktop = sampleDesktop();
    _live.clear();
  });

  testWidgets('GTK (mousepad) açık TR: menü çubuğu çipleri, açık menü kartı, düzenleyici; dokun → eylem', (tester) async {
    FakeAgent.ui = sampleUiMousepad();
    await _open(tester, address: '0x55d1b0');
    expect(find.text('Mobil görünüm'), findsOneWidget);
    expect(find.text('Untitled 1 - Mousepad'), findsOneWidget);
    expect(find.text('MENÜ'), findsOneWidget);
    expect(find.text('Open Recent'), findsOneWidget);
    expect(FakeAgent.calls.firstWhere((c) => c.$2 == '/v1/desktop/ui').$3, {'address': '0x55d1b0'});
    expect(FakeAgent.headersByPath['/v1/desktop/ui'], {'X-Tiphys-Control': 'tpc_fake'});
    expect(FakeAgent.uiSubscribers, 1);
    expect(tester.takeException(), isNull);
    await golden('png/mobile_view_gtk_light_tr.png');
    // Screen reader: chip is a button with tap + long-press actions; an open menu is "expanded".
    expect(tester.getSemantics(find.bySemanticsLabel('Edit')), isSemantics(isButton: true, hasTapAction: true, hasLongPressAction: true, isEnabled: true));
    expect(tester.getSemantics(find.bySemanticsLabel('File').first), isSemantics(isButton: true, hasExpandedState: true, isExpanded: true));

    await tester.tap(find.text('Edit'));
    await settle(tester);
    await tester.tap(find.text('New Window'));
    await settle(tester);
    expect(_posts(), ['act {id: 0.0.0.1, action: click}', 'act {id: 0.0.0.0.1, action: click}']);
    expect(_gets(), 3, reason: 'her eylemden sonra yeniden okunur');
    // A disabled item is not sent.
    await tester.tap(find.text('Reload'), warnIfMissed: false);
    await settle(tester);
    expect(_posts(), hasLength(2));
    // Text to the editor: send button.
    final editor = find.widgetWithText(TextField, 'Metin alanı');
    await tester.scrollUntilVisible(editor, 200, scrollable: _scroll);
    expect(tester.widget<TextField>(editor).controller!.text, 'Alışveriş listesi:\n- süt\n- ekmek');
    await tester.enterText(editor, 'yeni satır');
    await tester.tap(find.byTooltip('Gönder'));
    await settle(tester);
    expect(_posts().last, 'text {id: 0.2.0.0.0, text: yeni satır}');
    expect(find.text('Gönderildi'), findsOneWidget);
    // No tap target smaller than 44 px.
    // (IconButton's InkWell is 40 px; the tap area is expanded to 48 px.)
    final icons = find.descendant(of: find.byType(IconButton), matching: find.byType(InkWell)).evaluate().toSet();
    for (final e in find.descendant(of: find.byType(MobileViewScreen), matching: find.byType(InkWell)).evaluate().where((e) => !icons.contains(e))) {
      final s = tester.getSize(find.byWidget(e.widget));
      expect(s.height, greaterThanOrEqualTo(44), reason: '${e.widget}');
    }
    // The view closes on exit.
    await tester.tap(find.byTooltip('Geri'));
    await settle(tester);
    expect(FakeAgent.calls.last.$1, 'DELETE');
    expect(FakeAgent.uiSubscribers, 0);
    await _finish(tester);
  });

  testWidgets('Firefox koyu EN: araç çubuğu + adres alanı, sekmeler, web içeriği; alan/sekme/onay kutusu/kaydırıcı', (tester) async {
    await _open(tester, dark: true, lang: 'en');
    expect(find.text('Mobile view'), findsOneWidget);
    expect(find.text('GEZINTI'), findsOneWidget);
    expect(find.text('Haberler'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Adres'), findsOneWidget);
    expect(find.text('https://example.com/giris'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await golden('png/mobile_view_firefox_dark_en.png');

    await tester.enterText(find.widgetWithText(TextField, 'Adres'), 'example.org');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await settle(tester);
    await tester.tap(find.text('Haberler'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Şifremi unuttum'), 200, scrollable: _scroll);
    await settle(tester);
    await golden('png/mobile_view_firefox_page_dark_en.png');
    await tester.tap(find.text('Beni hatırla'));
    await settle(tester);
    await tester.tap(find.text('Şifremi unuttum'));
    await settle(tester);
    expect(_posts(), [
      'text {id: 0.2.0, text: example.org}',
      'act {id: 1.1, action: switch}',
      'act {id: 2.0.1.3, action: click}',
      'act {id: 2.0.1.8, action: jump}',
    ]);
    // The slider sends its value on release.
    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await settle(tester);
    expect(_posts().last, startsWith('value {id: 2.0.1.7, value: '));
    await _finish(tester);
  });

  testWidgets('şifre alanı: boş başlar, gizli; göndermeden önce onay (vazgeç → gitmez, onay → confirm: true)', (tester) async {
    await _open(tester);
    final pw = find.widgetWithText(TextField, 'Şifre');
    await tester.scrollUntilVisible(pw, 200, scrollable: _scroll);
    await settle(tester);
    expect(tester.widget<TextField>(pw).obscureText, isTrue);
    expect(tester.widget<TextField>(pw).controller!.text, isEmpty);
    await tester.enterText(pw, 'gizli-123');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await settle(tester);
    expect(find.text('"Şifre" şifre alanına yazılsın mı? Metin PC\'ye gönderilir.'), findsOneWidget);
    await golden('png/mobile_view_password_light_tr.png');
    await tester.tap(find.text('Vazgeç'));
    await settle(tester);
    expect(_posts(), isEmpty);
    await tester.tap(find.byTooltip('Şifreyi gönder'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Şifreyi gönder'));
    await settle(tester);
    expect(_posts(), ['text {id: 2.0.1.2, text: gizli-123, confirm: true}']);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Şifre')).controller!.text, isEmpty);
    await _finish(tester);
  });

  testWidgets('basılı tut: bileşenin eylemleri + odakla; eski kuşak sessizce yenilenip yeniden denenir', (tester) async {
    await _open(tester);
    await tester.scrollUntilVisible(find.text('Giriş yap'), 200, scrollable: _scroll);
    await settle(tester);
    await tester.longPress(find.text('Giriş yap'));
    await settle(tester);
    expect(find.text('Bas'), findsOneWidget);
    expect(find.text('Odakla'), findsOneWidget);
    await golden('png/mobile_view_context_light_tr.png');
    await tester.tap(find.text('Odakla'));
    await settle(tester);
    expect(_posts(), ['act {id: 2.0.1.5, op: focus}']);
    // The generation advanced on the agent (e.g. another read): retried without the user seeing anything.
    FakeAgent.uiGen++;
    FakeAgent.calls.clear();
    await tester.tap(find.text('Giriş yap'));
    await settle(tester);
    expect(_posts(), ['act {id: 2.0.1.5, action: press}', 'act {id: 2.0.1.5, action: press}']);
    expect(find.byType(SnackBar), findsNothing);
    // Any other error shows a brief notice.
    FakeAgent.uiErrors.add(const AgentError('agent.ui.noAction', {}, 400));
    await tester.tap(find.text('Giriş yap'));
    await settle(tester);
    expect(find.text('Bu bileşenin böyle bir eylemi yok.'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('alan kimliği: yol başka alana kayarsa taslak silinir, aynı alansa korunur', (tester) async {
    await _open(tester);
    final user = find.widgetWithText(TextField, 'Kullanıcı adı');
    await tester.scrollUntilVisible(user, 200, scrollable: _scroll);
    await settle(tester);
    await tester.enterText(user, 'taslak');
    // Same field (same path + role + name): the draft survives a refresh.
    FakeAgent.uiEvents.add(('changed', '{}'));
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(tester.widget<TextField>(user).controller!.text, 'taslak');
    // A sibling was added: a different field now sits at the same path.
    final nodes = [for (final n in sampleUiFirefox()['nodes'] as List) {...n as Map}];
    nodes.firstWhere((n) => n['id'] == '2.0.1.1')
      ..['name'] = 'E-posta'
      ..['text'] = '';
    FakeAgent.ui = {...sampleUiFirefox(), 'nodes': nodes};
    FakeAgent.uiEvents.add(('changed', '{}'));
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(user, findsNothing);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'E-posta')).controller!.text, isEmpty, reason: 'taslak başka alana geçmez');
    expect(_posts(), isEmpty);
    await _finish(tester);
  });

  testWidgets('kısmi ağaç şeridi, arama süzer, SSE "changed" → birleştirilmiş yeniden okuma', (tester) async {
    FakeAgent.ui = {...sampleUiFirefox(), 'partial': true};
    await _open(tester);
    expect(find.textContaining('Kısmi:'), findsOneWidget);
    await golden('png/mobile_view_partial_light_tr.png');
    await tester.enterText(find.widgetWithText(TextField, 'Bileşen ara'), 'ŞİFRE');
    await settle(tester);
    expect(find.text('Şifremi unuttum'), findsOneWidget);
    expect(find.text('Geri'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Bileşen ara'), 'yok böyle');
    await settle(tester);
    expect(find.text('Eşleşen bileşen yok.'), findsOneWidget);
    final before = _gets();
    FakeAgent.uiEvents.add(('changed', '{}'));
    FakeAgent.uiEvents.add(('changed', '{}'));
    await tester.pump(const Duration(milliseconds: 100));
    await settle(tester);
    expect(_gets(), before + 1);
    await _finish(tester);
  });

  testWidgets('desteklenmeyen uygulama → canlı ekran önerisi; yardımcı eksik → kart; boş ağaç', (tester) async {
    FakeAgent.ui = const AgentError('agent.ui.unsupported', {}, 422);
    await _open(tester, address: '0x55d1b0');
    expect(find.text('Bu uygulama bileşenlerini paylaşmıyor'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Canlı ekranı aç'), findsOneWidget);
    expect(FakeAgent.uiSubscribers, 0);
    await golden('png/mobile_view_unsupported_light_tr.png');

    FakeAgent.ui = const AgentError('agent.ui.helperMissing', {}, 503);
    await tester.tap(find.byTooltip('Yenile'));
    await settle(tester);
    expect(find.text("PC'de erişilebilirlik yardımcısı eksik"), findsOneWidget);
    FakeAgent.ui = {...sampleUiFirefox(), 'nodes': <Object>[]};
    await tester.tap(find.text('Tekrar dene'));
    await settle(tester);
    expect(find.text('Bu pencerede gösterilecek bileşen yok.'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('masaüstü panelinden: pencere menüsünde "Mobil görünüm"', (tester) async {
    await _harness().pump(tester, route: '/system/desktop?host=argo');
    await tester.longPress(find.text('Tiphys — Mozilla Firefox'));
    await settle(tester);
    await tester.tap(find.text('Mobil görünüm'));
    await _wait(tester);
    expect(find.byType(MobileViewScreen), findsOneWidget);
    expect(FakeAgent.calls.firstWhere((c) => c.$2 == '/v1/desktop/ui').$3, {'address': '0x55d1a0'});
    expect(find.bySemanticsLabel('Pencere önizlemesi'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('canlı ekran şeridinden: önizleme aynı akış, odak değişince görünüm de geçer, geri → canlı ekran', (tester) async {
    await _harness().pump(tester, route: '/system/desktop/live?host=argo');
    final c = _live.single;
    c.hello();
    c.ctrl.add(frameBytes(1, desktopPng(), 480, 270));
    void focus(String address, String cls) => c.ctrl.add(jsonEncode({'type': 'focus', 'address': address, 'class': cls, 'initialClass': cls, 'title': 'Giriş — Mozilla Firefox', 'pid': 4242, 'workspace': 1}));
    focus('0x55d1a0', 'firefox-esr');
    await _wait(tester);
    await tester.tap(find.byTooltip('Mobil görünüm'));
    await _wait(tester);
    expect(find.byType(MobileViewScreen), findsOneWidget);
    expect(find.descendant(of: find.byType(MobileViewScreen), matching: find.byType(LiveCanvas)), findsOneWidget);
    expect(_live, hasLength(1), reason: 'yeni akış açılmaz');
    await tester.enterText(find.widgetWithText(TextField, 'Bileşen ara'), 'geri');
    await settle(tester);
    focus('0x55d1b0', 'org.xfce.mousepad');
    FakeAgent.ui = sampleUiMousepad();
    await _wait(tester);
    expect(FakeAgent.calls.lastWhere((x) => x.$2 == '/v1/desktop/ui').$3, {'address': '0x55d1b0'});
    expect(find.text('Untitled 1 - Mousepad'), findsOneWidget);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Bileşen ara')).controller!.text, isEmpty, reason: 'pencere değişince arama temizlenir');
    await tester.tap(find.byTooltip('Canlı ekranı aç'));
    await _wait(tester);
    expect(find.byType(MobileViewScreen), findsNothing);
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(FakeAgent.calls.last.$1, 'DELETE');
    await _finish(tester);
  });
}
