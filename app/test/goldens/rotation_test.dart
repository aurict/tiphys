// Config and secrets: the "Yenilenmesi gerekenler" rotation list (overdue first), setting/clearing a key's limit, and
// opening the file focused on the key. To update: flutter test test/goldens/rotation_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/harness.dart';

Harness _harness() => Harness(agentFeatures: [...Harness.defaultAgentFeatures, 'configfiles']);

Future<void> _load(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
  debugDisableShadows = true;
}

void main() {
  setUp(() {
    FakeAgent.resetConfig();
    FakeAgent.calls.clear();
  });

  testWidgets('yenilenmesi gerekenler TR: gecikenler önce, sonra sınıra yakın; limitsizler daraltılmış', (tester) async {
    final f = FakeAgent.config.files['argo']!.first;
    f.entries.firstWhere((e) => e.key == 'SESSION_SECRET').maxAgeDays = 30; // 40 d old → overdue
    await _harness().pump(tester, route: '/configfiles');
    tester.view.physicalSize = const Size(390 * 2, 1500 * 2);
    await _load(tester);
    expect(find.text('Yenilenmesi gerekenler'.toUpperCase().replaceAll('I', 'İ')), findsOneWidget);
    final keys = ['API_TOKEN', 'SESSION_SECRET', 'DB_PASSWORD'];
    final tops = [for (final k in keys) tester.getTopLeft(find.text(k).first).dy];
    expect(tops, orderedEquals([...tops]..sort()), reason: 'API_TOKEN (30 g gecikti), SESSION_SECRET (10 g), DB_PASSWORD (78 g kaldı)');
    expect(find.text('30 g gecikti'), findsOneWidget);
    expect(find.text('10 g gecikti'), findsOneWidget);
    expect(find.text('78 g kaldı'), findsOneWidget);
    expect(find.text('120 / 90 g'), findsOneWidget);
    expect(find.text('Hatırlatması olmayanlar (2)'), findsOneWidget);
    expect(find.text('STRIPE_KEY'), findsNothing, reason: 'daraltılmış');
    await golden('png/rotation_list_tr.png');
    await _finish(tester);
  });

  testWidgets('limitsizler açılır; kimse limitli değilse açıklama (375 px)', (tester) async {
    for (final fl in FakeAgent.config.files.values.expand((e) => e)) {
      for (final e in fl.entries) {
        e.maxAgeDays = null;
      }
    }
    await _harness().pump(tester, route: '/configfiles', lang: 'en');
    tester.view.physicalSize = const Size(375 * 2, 1500 * 2);
    await _load(tester);
    expect(find.textContaining('No secret has a rotation reminder yet'), findsOneWidget);
    await tester.tap(find.text('No reminder yet (5)'));
    await settle(tester);
    expect(find.text('STRIPE_KEY'), findsOneWidget);
    expect(find.text('120 d old'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('zamanlayıcı düğmesi: 90 gün öner → PUT /v1/secrets/meta; kaldır → null', (tester) async {
    await _harness().pump(tester, route: '/configfiles');
    tester.view.physicalSize = const Size(375 * 2, 1500 * 2);
    await _load(tester);
    await tester.tap(find.byTooltip('Yenileme hatırlatmasını ayarla').first);
    await settle(tester);
    expect(find.text('Yenileme hatırlatıcısı'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '45');
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    expect(FakeAgent.config.metaCalls.last, {
      'updates': [
        {'fileId': 'cf-aaaaaaaaaaaaaaaaaaaaaaaa', 'key': 'API_TOKEN', 'maxAgeDays': 45},
      ],
    });
    // Clear it again.
    await tester.tap(find.byTooltip('Yenileme hatırlatmasını ayarla').first);
    await settle(tester);
    await tester.tap(find.text('Hatırlatma yok'));
    await tester.pump();
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    final upd = ((FakeAgent.config.metaCalls.last as Map)['updates'] as List).single as Map;
    expect(upd.containsKey('maxAgeDays'), isTrue);
    expect(upd['maxAgeDays'], isNull);
    await _finish(tester);
  });

  testWidgets('limitsiz anahtara 90 gün önerilir', (tester) async {
    await _harness().pump(tester, route: '/configfiles');
    tester.view.physicalSize = const Size(375 * 2, 1500 * 2);
    await _load(tester);
    await tester.tap(find.text('Hatırlatması olmayanlar (3)'));
    await settle(tester);
    await tester.tap(find.byTooltip('Yenileme hatırlatmasını ayarla').last);
    await settle(tester);
    await tester.tap(find.text('90 gün öner'));
    await tester.pump();
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    expect(((FakeAgent.config.metaCalls.last as Map)['updates'] as List).single, containsPair('maxAgeDays', 90));
    await _finish(tester);
  });

  testWidgets('satıra dokununca dosya o anahtara odaklı açılır (vurgulu, görünür)', (tester) async {
    await _harness().pump(tester, route: '/configfiles');
    tester.view.physicalSize = const Size(375 * 2, 700 * 2);
    await _load(tester);
    await tester.tap(find.text('API_TOKEN').first);
    await _load(tester);
    expect(find.text('.env'), findsWidgets);
    final tile = find.ancestor(of: find.text('API_TOKEN'), matching: find.byType(Container)).first;
    expect(tester.getRect(tile).bottom, lessThanOrEqualTo(700));
    final box = tester.widget<Container>(find.ancestor(of: find.text('API_TOKEN'), matching: find.byType(Container)).first);
    expect(box.color ?? (box.decoration as BoxDecoration?)?.color, isNotNull, reason: 'vurgu rengi');
    await _finish(tester);
  });
}
