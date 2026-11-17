// Incident room I-2: deploys tab (with config changes), rollback preview, disk cleanup preview with option toggles.
// To update: flutter test test/goldens/incidents_i2_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/features/system/events.dart' show ChipRow;

import '../helpers/harness.dart';

Harness _harness() => Harness(agentFeatures: [...Harness.defaultAgentFeatures, 'incidents']);
void _tall(WidgetTester tester, [double height = 1500]) => tester.view.physicalSize = Size(390 * 2, height * 2);

Future<void> _load(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
  debugDisableShadows = true;
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(find.widgetWithText(ChoiceChip, label), 80, scrollable: find.descendant(of: find.byType(ChipRow), matching: find.byType(Scrollable)));
  await tester.ensureVisible(find.widgetWithText(ChoiceChip, label));
  await tester.pump();
  await tester.tap(find.widgetWithText(ChoiceChip, label));
  await settle(tester);
}

const _open = '/incidents/inc-aaaaaaaaaaaa?host=argo';
const _disk = '/incidents/inc-bbbbbbbbbbbb?host=argo';

void main() {
  setUp(() {
    FakeAgent.resetIncidents();
    FakeAgent.calls.clear();
  });

  testWidgets('Dağıtımlar sekmesi TR: bağlam + geçmiş birleşik, ayar değişiklikleri anahtar adlarıyla', (tester) async {
    await _harness().pump(tester, route: _open);
    _tall(tester);
    await _load(tester);
    await _tab(tester, 'Dağıtımlar');
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$2 == '/v1/incidents/deploys').single.$3, {'stack': 'shop', 'service': 'web', 'limit': '50'});
    expect(find.text('registry.example.org/web:1.4.2'), findsOneWidget, reason: 'iki kaynakta da var, tek satır');
    expect(find.text('Geri alınabilir'), findsOneWidget);
    expect(find.text('Önceki imaj yok'), findsOneWidget);
    expect(find.text('İlk görüldü'), findsOneWidget);
    expect(find.textContaining('Olaydan 20 dk önce'), findsOneWidget);
    expect(find.text('9f8e7d6c5b4a ← 1a2b3c4d5e6f'), findsOneWidget);
    expect(find.text('shop/.env kaydedildi'), findsOneWidget);
    expect(find.text('DB_PASSWORD'), findsOneWidget);
    expect(find.text('shop/api.env yedekten geri yüklendi'), findsOneWidget);
    await golden('png/incident_deploys_tr.png');
    await _finish(tester);
  });

  testWidgets('Dağıtımlar: kanıt çipi sekmeye götürür; boş durum', (tester) async {
    final inc = FakeAgent.incidents['argo']!.first;
    inc['stack'] = null;
    inc['service'] = null;
    (inc['context'] as Map)['deploys'] = [];
    (inc['context'] as Map)['configChanges'] = [];
    await _harness().pump(tester, route: _open);
    _tall(tester);
    await _load(tester);
    await _tab(tester, 'Dağıtımlar');
    expect(find.textContaining('dağıtım kaydı yok'), findsOneWidget);
    expect(find.textContaining('kaydedilen ayar dosyası yok'), findsOneWidget);
    expect(FakeAgent.calls.where((c) => c.$2 == '/v1/incidents/deploys'), isEmpty, reason: 'yığın/servis yok → istek yok');
    await _finish(tester);
  });

  testWidgets('geri alma önizlemesi EN: imajlar, tarihler, göç uyarısı; onayla çalıştır', (tester) async {
    FakeAgent.incident.rollback = true;
    await _harness().pump(tester, route: _open, lang: 'en');
    _tall(tester);
    await _load(tester);
    await tester.tap(find.text('Roll back web to the previous image'));
    await _load(tester);
    expect(find.text('9f8e7d6c5b4a'), findsOneWidget);
    expect(find.text('1a2b3c4d5e6f'), findsOneWidget);
    expect(find.text('Running now'), findsOneWidget);
    expect(find.text('Will run instead'), findsOneWidget);
    expect(find.textContaining('Database migrations are not rolled back'), findsOneWidget);
    expect(find.text('registry.example.org/web:1.4.2'), findsOneWidget);
    await golden('png/incident_rollback_en.png');
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$2.endsWith('/execute')).single.$3, {'previewToken': 'tpv_1', 'confirm': true});
    await _finish(tester);
  });

  testWidgets('disk temizliği önizlemesi TR: seçenek başına alan, kullanılamayanlar nedenle', (tester) async {
    FakeAgent.incident.cleanup = true;
    await _harness().pump(tester, route: _disk);
    _tall(tester, 1700);
    await _load(tester);
    await tester.tap(find.text('/ üzerinde yer aç'));
    await _load(tester);
    expect(find.text('root gerekir; ajan yapamaz'), findsNWidgets(2));
    expect(find.textContaining('yaklaşık 1,2 GB açar'), findsOneWidget);
    expect(find.text('Tahmini toplam: 1,9 GB'), findsOneWidget);
    final off = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).where((s) => s.onChanged == null);
    expect(off, hasLength(2), reason: 'kullanıcı ve sistem journal kapalı');
    await golden('png/incident_cleanup_tr.png');
    await _finish(tester);
  });

  testWidgets('disk temizliği: seçenek kapatınca yeni önizleme (options), yürütme aynı seçimle; hiçbiri seçili değilse çalışmaz', (tester) async {
    FakeAgent.incident.cleanup = true;
    await _harness().pump(tester, route: _disk, lang: 'en');
    _tall(tester, 1700);
    await _load(tester);
    await tester.tap(find.text('Free disk space on /'));
    await _load(tester);
    await tester.tap(find.text('Build cache'));
    await _load(tester);
    final previews = FakeAgent.calls.where((c) => c.$2.endsWith('/preview')).toList();
    expect(previews.last.$3, {'options': unorderedEquals(['images', 'containers'])});
    expect(find.text('Estimated total: 720 MB'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await _load(tester);
    final exec = FakeAgent.calls.where((c) => c.$2.endsWith('/execute')).single.$3 as Map;
    expect(exec['options'], unorderedEquals(['images', 'containers']));
    expect(exec['confirm'], true);
    await _finish(tester);
  });

  testWidgets('disk temizliği: tüm seçenekler kapalıysa Çalıştır kapalı', (tester) async {
    FakeAgent.incident.cleanup = true;
    await _harness().pump(tester, route: _disk, lang: 'en');
    _tall(tester, 1700);
    await _load(tester);
    await tester.tap(find.text('Free disk space on /'));
    await _load(tester);
    for (final n in ['Build cache', 'Dangling images', 'Stopped containers']) {
      await tester.tap(find.text(n));
      await _load(tester);
    }
    expect(find.text('Choose at least one option.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Run')).onPressed, isNull);
    await _finish(tester);
  });

  testWidgets('375 px genişlikte taşma yok (dağıtımlar, geri alma, temizlik)', (tester) async {
    FakeAgent.incident.rollback = true;
    FakeAgent.incident.cleanup = true;
    await _harness().pump(tester, route: _open);
    tester.view.physicalSize = const Size(375 * 2, 1700 * 2);
    await _load(tester);
    await _tab(tester, 'Dağıtımlar');
    await _load(tester);
    await tester.tap(find.text('web servisini önceki imaja geri al'));
    await _load(tester);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });
}
