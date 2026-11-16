// Dozzle: merged stream, container actions and "Claude'a sor".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/integrations/dozzle_client.dart';
import 'package:tiphys/features/monitoring/dozzle_screen.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';

import '../helpers/harness.dart';

Future<void> _cleanup(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
}

Future<void> _openList(WidgetTester tester, {bool dark = false}) async {
  await Harness().pump(tester, route: '/monitor/dozzle', dark: dark);
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _openLogs(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

void main() {
  test('işlem ayarı Dozzle sayfasına gömülü ayarlardan okunur', () {
    const on = '<script type="application/json" id="config__json">\n {"base":"","enableActions":true}</script>';
    expect(DozzleClient.parseActionsEnabled(on), isTrue);
    expect(DozzleClient.parseActionsEnabled(on.replaceFirst('true', 'false')), isFalse);
    expect(DozzleClient.parseActionsEnabled('<html></html>'), isFalse);
    expect(DozzleClient.parseActionsEnabled('<script id="config__json">bozuk</script>'), isFalse);
  });

  test("Claude'a sor mesajı: container, satır ve öncesindeki satırlar", () {
    final l = lookupAppLocalizations(const Locale('tr'));
    final cs = [
      DozzleContainer({'id': 'a', 'name': 'web-1', 'host': 'h', 'image': 'img/web@sha256:x'}),
      DozzleContainer({'id': 'b', 'name': 'db-1', 'host': 'h', 'image': 'postgres:17'}),
    ];
    DozzleLine line(int src, int ts, String m) => DozzleLine(src, DozzleLog({'ts': ts, 'm': m}));
    final lines = [line(0, 1000, 'istek geldi'), line(1, 2000, 'bağlantı açıldı'), line(1, 3000, 'FATAL: limit')];
    final p = dozzleClaudePrompt(l, cs, lines, 2);
    expect(p, contains('"db-1" container\'ının (postgres:17)'));
    expect(p.indexOf('[db-1] FATAL: limit'), lessThan(p.indexOf('Öncesindeki loglar')));
    expect(p, contains('[web-1] istek geldi'));
    // No "before" section for the first line
    expect(dozzleClaudePrompt(l, cs.sublist(0, 1), [line(0, 1, 'tek')], 0), isNot(contains('Öncesindeki')));
  });

  test('geçmiş birleştirme: aynı milisaniyedeki satırlar sunucudaki sırasını korur', () {
    // 40-line stack trace at a single timestamp (List.sort is unstable above 32)
    final trace = [for (var i = 0; i < 40; i++) DozzleLog({'ts': 5000, 'id': i, 'm': 'at satır $i'})];
    final other = [DozzleLog({'ts': 4000, 'm': 'önce'}), DozzleLog({'ts': 5000, 'm': 'aynı an, ikinci container'})];
    final merged = mergeDozzleHistory([trace, other]);
    expect(merged.first.log.text, 'önce');
    expect([for (final x in merged.skip(1).take(40)) x.log.text], [for (var i = 0; i < 40; i++) 'at satır $i']);
    expect(merged.last.log.text, 'aynı an, ikinci container');
  });

  testWidgets('birkaç container seçilip tek akışta, zaman sırasıyla ve etiketli izlenir', (tester) async {
    await _openList(tester, dark: true);
    await tester.tap(find.byTooltip('Birkaçını birlikte izle'));
    await settle(tester);
    // The project chip selects the aurict project's containers (web-1, db-1, migrate-1)
    await tester.tap(find.widgetWithText(ActionChip, 'aurict'));
    await settle(tester);
    expect(find.text('3 seçili'), findsOneWidget);
    await tester.tap(find.text('migrate-1')); // deselect one
    await settle(tester);
    await tester.tap(find.text("2 container'ı birlikte izle"));
    await _openLogs(tester);
    expect(find.text('2 container'), findsOneWidget);
    expect(find.textContaining('FATAL: connection limit exceeded', findRichText: true), findsOneWidget);
    expect(find.textContaining('web-1 satır 1', findRichText: true), findsOneWidget);
    await golden('png/dozzle_merged_dark_tr.png');
    await _cleanup(tester);
  });

  testWidgets("log satırına uzun basınca Claude'a sor: yeni oturum, mesaj hazır", (tester) async {
    await _openList(tester);
    await tester.tap(find.text('db-1'));
    await _openLogs(tester);
    await tester.longPress(find.textContaining('FATAL: connection limit exceeded', findRichText: true));
    await settle(tester);
    await tester.tap(find.text("Claude'a sor"));
    await settle(tester);
    final field = tester.widget<TextField>(find.byWidgetPredicate((w) => w is TextField && (w.controller?.text.contains('FATAL') ?? false)));
    expect(field.controller!.text, contains('"db-1" container\'ının (img/db-1)'));
    expect(field.controller!.text, contains('db-1 satır 3'));
    await golden('png/dozzle_ask_claude_light_tr.png');
    await _cleanup(tester);
  });

  testWidgets("log satırına uzun basınca Obsidian'a kaydet: hızlı not satırla dolu açılır", (tester) async {
    await _openList(tester);
    await tester.tap(find.text('db-1'));
    await _openLogs(tester);
    await tester.longPress(find.textContaining('FATAL: connection limit exceeded', findRichText: true));
    await settle(tester);
    await tester.tap(find.text("Obsidian'a kaydet"));
    await settle(tester);
    expect(find.text('Hızlı not'), findsOneWidget);
    final field = tester.widget<TextField>(find.byWidgetPredicate((w) => w is TextField && (w.controller?.text.contains('FATAL') ?? false)));
    expect(field.controller!.text, contains('[db-1] FATAL: connection limit exceeded'));
    expect(find.widgetWithText(TextField, 'Dozzle · db-1'), findsOneWidget);
    await _cleanup(tester);
    debugDisableShadows = true;
  });

  testWidgets('container işlemi: Dozzle\'da kapalıysa açıklama, açıksa onayla çalışır', (tester) async {
    FakeDozzle.performed.clear();
    FakeDozzle.actions = false;
    await _openList(tester);
    await tester.tap(find.text('web-1'));
    await _openLogs(tester);
    await tester.tap(find.byTooltip('Daha fazla'));
    await settle(tester);
    expect(find.text("Dozzle'da kapalı"), findsNWidgets(2)); // restart + stop
    await tester.tap(find.text('Yeniden başlat'));
    await settle(tester);
    expect(find.text('Container işlemleri kapalı'), findsOneWidget);
    expect(FakeDozzle.performed, isEmpty);
    await _cleanup(tester);

    FakeDozzle.actions = true;
    await _openList(tester);
    await tester.tap(find.text('web-1'));
    await _openLogs(tester);
    await tester.tap(find.byTooltip('Daha fazla'));
    await settle(tester);
    await tester.tap(find.text('Yeniden başlat'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Yeniden başlat')); // onay
    await settle(tester);
    expect(FakeDozzle.performed, ['web-1:restart']);
    FakeDozzle.actions = false;
    await _cleanup(tester);
    debugDisableShadows = true; // no screenshot taken: restore the setting Harness changed
  });
}
