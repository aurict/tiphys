// Terminal: pinch to change font size and full-screen (landscape) view.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/features/terminal/sessions.dart';
import 'package:tiphys/features/terminal/terminal_screen.dart';
import 'package:tiphys/state/providers.dart';
import 'package:xterm/xterm.dart';

import '../helpers/harness.dart';

void main() {
  test('yakınlaştırma oranından yazı boyutu: yarım punto adım, 8–32 sınırı', () {
    expect(pinchFontSize(13, 100, 150), 19.5);
    expect(pinchFontSize(13, 100, 104), 13.5);
    expect(pinchFontSize(13, 100, 10), 8);
    expect(pinchFontSize(13, 100, 1000), 32);
  });

  testWidgets('iki parmakla açınca yazı büyür ve profile kaydedilir', (tester) async {
    final container = await Harness().pump(tester, route: '/terminal');
    final host = container.read(profileProvider).hosts.firstWhere((h) => h.ssh != null);
    container.read(terminalSessionsProvider.notifier).open(host);
    await settle(tester);
    final before = container.read(profileProvider).terminal.fontSize;
    final c = tester.getCenter(find.byType(TerminalView));
    final a = await tester.startGesture(c - const Offset(40, 0));
    final b = await tester.startGesture(c + const Offset(40, 0), pointer: 7);
    await tester.pump();
    await a.moveTo(c - const Offset(60, 0));
    await b.moveTo(c + const Offset(60, 0));
    await tester.pump();
    // The current size is shown while zooming (80 → 120 px: ×1.5)
    expect(find.text('${(before * 1.5 * 2).round() / 2} punto'.replaceAll('.0 ', ' ')), findsOneWidget);
    await a.up();
    await b.up();
    // The profile is written to disk: real time + frame pumping so real file operations complete in order
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(container.read(profileProvider).terminal.fontSize, (before * 1.5 * 2).round() / 2);
    expect(find.textContaining('punto'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    debugDisableShadows = true; // no screenshot taken: revert the setting the Harness changed
  });

  testWidgets('tam ekran: sekmedeki görünüm terminali çizmez, çıkınca geri gelir', (tester) async {
    final container = await Harness().pump(tester, route: '/terminal', dark: true);
    final host = container.read(profileProvider).hosts.firstWhere((h) => h.ssh != null);
    final s = container.read(terminalSessionsProvider.notifier).open(host);
    await settle(tester);
    await tester.tap(find.byTooltip('Tam ekran (yataya döner)'));
    await settle(tester);
    expect(container.read(fullscreenTerminalProvider), s.id);
    expect(find.byType(TerminalFullscreenScreen), findsOneWidget);
    expect(find.byType(TerminalView, skipOffstage: false), findsOneWidget); // only the one in full screen
    tester.view.physicalSize = const Size(844 * 2, 390 * 2); // yatay
    await settle(tester);
    await golden('png/terminal_fullscreen_landscape_dark_tr.png');
    await tester.tap(find.byTooltip('Tam ekrandan çık'));
    await settle(tester);
    expect(container.read(fullscreenTerminalProvider), isNull);
    expect(find.byType(TerminalView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });
}
