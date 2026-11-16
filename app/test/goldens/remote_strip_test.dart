// 11.1 Smart toolbar: per-app strip on the live screen driven by the agent's focus message (portrait: above the
// keyboard bar, landscape: column on the right), button → WS input events, text prompt, confirmation, "all remotes"
// page, hide/show; Settings › Desktop › Remotes (list, editing, invalid shortcut is not saved). Fake stream; nothing
// reaches the PC.
// To update: flutter test test/goldens/remote_strip_test.dart --update-goldens
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/features/desktop/desktop_data.dart';
import 'package:tiphys/features/desktop/live_screen.dart' show LiveKeyboardBar;
import 'package:tiphys/features/desktop/live_stream.dart';
import 'package:tiphys/features/desktop/remote_strip.dart';
import 'package:tiphys/state/providers.dart';

import '../helpers/harness.dart';
import 'live_screen_test.dart' show FakeLive, desktopPng, frameBytes;

const _route = '/system/desktop/live?host=argo';

class _Live {
  final conns = <FakeLive>[];
  Harness harness() => Harness(extra: [
        controlAuthProvider.overrideWithValue((_) async => true),
        liveConnectorProvider.overrideWithValue((host, token, query) async {
          final c = FakeLive(query);
          conns.add(c);
          return c;
        }),
      ]);
}

void _focus(FakeLive c, String cls, {String? appId, String title = 'Tiphys — Mozilla Firefox', String address = '0x55d1a0'}) => c.ctrl.add(jsonEncode({
      'type': 'focus',
      'address': address,
      'class': cls,
      'initialClass': cls,
      'title': title,
      'pid': 4242,
      'workspace': 1,
      'appId': appId,
    }));

/// The stream starts (frame decoded), focus is reported.
Future<FakeLive> _start(WidgetTester tester, _Live live, String cls, {String? appId}) async {
  final c = live.conns.single;
  c.hello();
  c.ctrl.add(frameBytes(1, desktopPng(), 480, 270));
  _focus(c, cls, appId: appId);
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
  return c;
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
  debugDisableShadows = true;
}

Map<String, Object> _key(String k, [List<String> mods = const []]) => {'type': 'key', 'key': k, 'mods': mods};

/// Saving the profile writes a real file: wait outside fake time.
Future<void> _io(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await settle(tester);
}

/// Scrolls the strip until the button is visible (the first button is "Mobil görünüm", so preset buttons shifted
/// right).
Future<void> _reveal(WidgetTester tester, String text) async {
  await tester.dragUntilVisible(find.text(text), find.byType(LiveRemoteStrip), const Offset(-60, 0));
  await settle(tester);
}

void _landscape(WidgetTester tester) => tester.view.physicalSize = const Size(844 * 2, 390 * 2);

void main() {
  setUp(FakeAgent.calls.clear);

  group('canlı ekran şeridi', () {
    testWidgets('odak yokken (eski ajan) şerit yok; Firefox odağında düğmeler olaya dönüşür, kitty\'ye geçince değişir', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route);
      final c = live.conns.single;
      c.hello();
      await settle(tester);
      expect(find.byType(LiveRemoteStrip), findsNothing);

      _focus(c, 'firefox-esr', appId: 'firefox');
      await settle(tester);
      expect(find.byType(LiveRemoteStrip), findsOneWidget);
      expect(find.text('Firefox'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Firefox kumandası')), findsOneWidget);
      // First "Mobil görünüm" (11.4), then the user's button (example profile: "GitHub" for firefox) before the preset
      // buttons; also shown for firefox-esr.
      final gh = tester.getTopLeft(find.text('GitHub'));
      expect(tester.getTopLeft(find.text('Mobil görünüm')).dx, lessThan(gh.dx));

      c.sent.clear();
      await _reveal(tester, 'GitHub');
      await tester.tap(find.text('GitHub'));
      // Ctrl+L opens the address bar: 300 ms wait on the agent before the text (so the field gets focus), later steps
      // 80 ms.
      // The wait is in the agent's input queue: everything is sent immediately and in order (network batching can't
      // break the spacing).
      await tester.pump(const Duration(milliseconds: 10));
      expect(c.input, [
        _key('L', ['ctrl']),
        {'type': 'wait', 'ms': 300},
        {'type': 'text', 'text': 'github.com'},
        {'type': 'wait', 'ms': 80},
        _key('Enter'),
      ]);
      c.sent.clear();
      await tester.dragUntilVisible(find.text('Geri'), find.byType(LiveRemoteStrip), const Offset(-80, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Geri'));
      await tester.dragUntilVisible(find.text('Yeni sekme'), find.byType(LiveRemoteStrip), const Offset(-80, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Yeni sekme'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(c.input, [_key('Left', ['alt']), _key('T', ['ctrl'])]);
      // No target smaller than 44 px.
      for (final e in find.descendant(of: find.byType(LiveRemoteStrip), matching: find.byType(InkWell)).evaluate()) {
        final s = tester.getSize(find.byWidget(e.widget));
        expect(s.height, greaterThanOrEqualTo(44));
        expect(s.width, greaterThanOrEqualTo(44));
      }

      _focus(c, 'kitty', title: '~');
      await settle(tester);
      expect(find.text('kitty'), findsOneWidget);
      expect(find.text('GitHub'), findsNothing);
      c.sent.clear();
      await _reveal(tester, 'Durdur (Ctrl+C)');
      await tester.tap(find.text('Durdur (Ctrl+C)'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(c.input, [_key('C', ['ctrl'])]);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('metin sor: Ctrl+L → metin → Enter; vazgeçince bir şey gitmez', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route);
      final c = await _start(tester, live, 'firefox');
      c.sent.clear();
      await _reveal(tester, 'Adres / ara');
      await tester.tap(find.text('Adres / ara'));
      await settle(tester);
      expect(find.text('Adres ya da arama'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await settle(tester);
      expect(c.input, isEmpty);
      await tester.tap(find.text('Adres / ara'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'tiphys şarkı');
      await tester.tap(find.text('Gönder'));
      await settle(tester);
      expect(c.input, [
        _key('L', ['ctrl']),
        {'type': 'wait', 'ms': 300},
        {'type': 'text', 'text': 'tiphys şarkı'},
        {'type': 'wait', 'ms': 80},
        _key('Enter'),
      ]);
      await _finish(tester);
    });

    testWidgets('onaylı düğme: vazgeç → olay yok, gönder → Ctrl+W', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route);
      final c = await _start(tester, live, 'firefox');
      c.sent.clear();
      await tester.dragUntilVisible(find.text('Sekmeyi kapat'), find.byType(LiveRemoteStrip), const Offset(-80, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Sekmeyi kapat'));
      await settle(tester);
      expect(find.text('“Sekmeyi kapat” PC\'ye gönderilsin mi?'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await settle(tester);
      expect(c.input, isEmpty);
      await tester.tap(find.text('Sekmeyi kapat'));
      await settle(tester);
      await tester.tap(find.text('Gönder'));
      await settle(tester);
      expect(c.input, [_key('W', ['ctrl'])]);
      await _finish(tester);
    });

    testWidgets('onay/metin sorulurken odak başka pencereye geçerse gönderilmez', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route);
      final c = await _start(tester, live, 'firefox');
      c.sent.clear();
      await tester.dragUntilVisible(find.text('Sekmeyi kapat'), find.byType(LiveRemoteStrip), const Offset(-80, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Sekmeyi kapat'));
      await settle(tester);
      _focus(c, 'firefox', address: '0x55d1ff', title: 'Başka pencere');
      await settle(tester);
      await tester.tap(find.text('Gönder'));
      await settle(tester);
      expect(c.input, isEmpty);
      expect(find.text('Odak başka pencereye geçti; gönderilmedi.'), findsOneWidget);
      // Also while asking for text.
      await tester.dragUntilVisible(find.text('Adres / ara'), find.byType(LiveRemoteStrip), const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Adres / ara'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'example.org');
      _focus(c, 'firefox');
      await settle(tester);
      await tester.tap(find.text('Gönder'));
      await settle(tester);
      expect(c.input, isEmpty);
      await _finish(tester);
    });

    testWidgets('tüm kumandalar sayfasından seçilen düğme çalışır; gizle → klavye çubuğunda göster düğmesi', (tester) async {
      final live = _Live();
      final container = await live.harness().pump(tester, route: _route);
      final c = await _start(tester, live, 'org.gnome.Nautilus');
      await tester.tap(find.byTooltip('Tüm kumandalar'));
      await settle(tester);
      expect(find.text('Yeni klasör'), findsOneWidget);
      expect(find.text('Ctrl+Shift+N'), findsOneWidget);
      c.sent.clear();
      await tester.tap(find.text('Yeni klasör'));
      await settle(tester);
      expect(c.input, [_key('N', ['ctrl', 'shift'])]);

      await tester.tap(find.byTooltip('Kumandayı gizle'));
      await settle(tester);
      expect(find.byType(LiveRemoteStrip), findsNothing);
      expect(container.read(liveRemoteCollapsedProvider), isTrue);
      await tester.tap(find.byTooltip('Kumandayı göster'));
      await settle(tester);
      expect(find.byType(LiveRemoteStrip), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  testWidgets('375 px dikey ve 667×375 yatay: taşma yok', (tester) async {
    final live = _Live();
    await live.harness().pump(tester, route: _route, lang: 'en');
    tester.view.physicalSize = const Size(375 * 2, 812 * 2);
    await _start(tester, live, 'com.visualstudio.code');
    expect(find.text('VS Code'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(667 * 2, 375 * 2);
    await settle(tester);
    expect(find.byType(LiveRemoteStrip), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('375 px ayar ekranları: taşma yok', (tester) async {
    await Harness().pump(tester, route: '/settings/remotes/edit?id=firefox-github');
    tester.view.physicalSize = const Size(375 * 2, 812 * 2);
    await settle(tester);
    await tester.tap(find.text('Metin sor'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    debugDisableShadows = true;
  });

  group('ekran görüntüleri', () {
    testWidgets('Firefox dikey tr', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true);
      await _start(tester, live, 'firefox', appId: 'firefox');
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_firefox_portrait_tr.png');
      await _finish(tester);
    });

    testWidgets('Firefox yatay en (sağda sütun)', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true, lang: 'en');
      _landscape(tester);
      await _start(tester, live, 'firefox', appId: 'firefox');
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_firefox_landscape_en.png');
      await _finish(tester);
    });

    testWidgets('yatay 812x375 (küçük telefon) + klavye çubuğu: sütun taşmaz, kaydırılır', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true);
      tester.view.physicalSize = const Size(812 * 2, 375 * 2);
      await _start(tester, live, 'firefox', appId: 'firefox');
      expect(find.byType(LiveKeyboardBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_firefox_landscape_small_tr.png');
      // On-screen keyboard open (~230 px in landscape): very little room left for the column.
      tester.view.viewInsets = const FakeViewPadding(bottom: 230 * 2);
      addTearDown(tester.view.resetViewInsets);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_firefox_landscape_small_keyboard_tr.png');
      // "Tüm kumandalar" is reachable by scrolling.
      await tester.scrollUntilVisible(find.byTooltip('Tüm kumandalar'), 60, scrollable: find.descendant(of: find.byType(LiveRemoteStrip), matching: find.byType(Scrollable)).first);
      await tester.tap(find.byTooltip('Tüm kumandalar'));
      await settle(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('genel profil dikey en', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true, lang: 'en');
      await _start(tester, live, 'steam');
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_generic_portrait_en.png');
      await _finish(tester);
    });

    testWidgets('VS Code yatay tr', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true);
      _landscape(tester);
      await _start(tester, live, 'code', appId: 'code');
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_vscode_landscape_tr.png');
      await _finish(tester);
    });

    testWidgets('tüm kumandalar sayfası tr', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true);
      await _start(tester, live, 'firefox', appId: 'firefox');
      await tester.tap(find.byTooltip('Tüm kumandalar'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_more_tr.png');
      await _finish(tester);
    });

    testWidgets('metin sorma en', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true, lang: 'en');
      await _start(tester, live, 'firefox', appId: 'firefox');
      await _reveal(tester, 'Address / search');
      await tester.tap(find.text('Address / search'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_prompt_en.png');
      await _finish(tester);
    });

    testWidgets('onay tr', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true);
      await _start(tester, live, 'org.kde.dolphin');
      await tester.tap(find.byTooltip('Tüm kumandalar'));
      await settle(tester);
      await tester.tap(find.text('Sil'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_confirm_tr.png');
      await _finish(tester);
    });

    testWidgets('gizlenmiş şerit tr', (tester) async {
      final live = _Live();
      final container = await live.harness().pump(tester, route: _route, dark: true);
      await container.read(liveRemoteCollapsedProvider.notifier).set(true);
      await _start(tester, live, 'firefox', appId: 'firefox');
      expect(tester.takeException(), isNull);
      await golden('png/live_remote_collapsed_tr.png');
      await _finish(tester);
    });
  });

  group('Ayarlar › Masaüstü › Kumandalar', () {
    testWidgets('liste ve düzenleme ekran görüntüsü', (tester) async {
      await Harness().pump(tester, route: '/settings/remotes');
      expect(find.text('GitHub'), findsOneWidget);
      await golden('png/remotes_light_tr.png');
    });

    testWidgets('düzenleme ekranı en', (tester) async {
      await Harness().pump(tester, route: '/settings/remotes/edit?id=firefox-github', lang: 'en', dark: true);
      expect(find.text('github.com'), findsOneWidget);
      await golden('png/remote_edit_dark_en.png');
    });

    testWidgets('ekle: geçersiz kısayol kaydedilmez, geçerlisi profile yazılır; sil', (tester) async {
      final c = await Harness().pump(tester, route: '/settings');
      await tester.scrollUntilVisible(find.text('Kumandalar'), 100);
      await tester.tap(find.text('Kumandalar'));
      await settle(tester);
      await tester.tap(find.byTooltip('Ekle'));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Pencere sınıfı'), 'kitty');
      await tester.enterText(find.widgetWithText(TextFormField, 'Ad'), 'Temizle');
      await tester.tap(find.byTooltip('Terminal'));
      await tester.enterText(find.widgetWithText(TextFormField, 'Kısayol'), 'ctrl+`');
      await tester.tap(find.text('Kaydet'));
      await settle(tester);
      expect(find.textContaining('Bu kısayol gönderilemez'), findsOneWidget);
      expect(c.read(profileProvider).desktopRemotes.map((r) => r.id), ['firefox-github']);
      // Shortcut that parses but exceeds the schema's 40-character limit: save doesn't throw, the field warns.
      await tester.enterText(find.widgetWithText(TextFormField, 'Kısayol'), 'control + shift + super + alt + printscreen');
      await tester.tap(find.text('Kaydet'));
      await settle(tester);
      expect(find.text('≤ 40'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(c.read(profileProvider).desktopRemotes.map((r) => r.id), ['firefox-github']);
      await tester.enterText(find.widgetWithText(TextFormField, 'Kısayol'), 'ctrl+shift+k');
      await tester.tap(find.text('Kaydet'));
      await _io(tester);
      final r = c.read(profileProvider).desktopRemotes.last;
      expect(r.toJson(), {'id': 'temizle', 'windowClass': 'kitty', 'name': 'Temizle', 'icon': 'terminal', 'action': {'kind': 'combo', 'combo': 'ctrl+shift+k'}, 'confirm': false});
      expect(find.text('Temizle'), findsOneWidget);

      // Sequence: two steps (shortcut + text).
      await tester.tap(find.text('Temizle'));
      await settle(tester);
      await tester.tap(find.text('Dizi'));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextFormField, '1'), 'ctrl+l');
      await tester.tap(find.text('Adım ekle'));
      await settle(tester);
      await tester.tap(find.text('Kısayol').last);
      await settle(tester);
      await tester.tap(find.text('Metin').last);
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextFormField, '2'), 'clear');
      await tester.tap(find.text('Kaydet'));
      await _io(tester);
      expect(c.read(profileProvider).desktopRemotes.last.action.toJson(), {
        'kind': 'sequence',
        'steps': [
          {'combo': 'ctrl+l'},
          {'text': 'clear'},
        ],
      });
      await tester.tap(find.text('Temizle'));
      await settle(tester);
      await tester.scrollUntilVisible(find.text('Sil'), 200, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(find.text('Sil'));
      await settle(tester);
      await tester.tap(find.text('Sil'));
      await _io(tester);
      expect(c.read(profileProvider).desktopRemotes.map((r) => r.id), ['firefox-github']);
      expect(tester.takeException(), isNull);
      debugDisableShadows = true;
    });
  });
}
