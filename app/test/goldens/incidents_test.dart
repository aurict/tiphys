// Incident room: list, incident screen, action preview sheet + confirmation, resolved incident, home card.
// To update: flutter test test/goldens/incidents_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/features/incidents/incident_screen.dart';
import 'package:tiphys/features/incidents/incidents_screen.dart';
import 'package:tiphys/features/system/events.dart' show ChipRow;

import '../helpers/harness.dart';

final _features = [...Harness.defaultAgentFeatures, 'incidents'];
Harness _harness() => Harness(agentFeatures: _features);

/// A tall viewport so the whole (lazily built) screen exists.
void _tall(WidgetTester tester, [double height = 1500]) => tester.view.physicalSize = Size(390 * 2, height * 2);

/// Selects an evidence tab (the chip row scrolls horizontally and builds lazily).
Future<void> _tab(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(find.widgetWithText(ChoiceChip, label), 80, scrollable: find.descendant(of: find.byType(ChipRow), matching: find.byType(Scrollable)));
  await tester.ensureVisible(find.widgetWithText(ChoiceChip, label));
  await tester.pump();
  await tester.tap(find.widgetWithText(ChoiceChip, label));
  await settle(tester);
}

Future<void> _load(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
}

const _open = '/incidents/inc-aaaaaaaaaaaa?host=argo';

void main() {
  setUp(() {
    FakeAgent.resetIncidents();
    FakeAgent.calls.clear();
  });

  testWidgets('olay listesi (açık) açık tema TR', (tester) async {
    await _harness().pump(tester, route: '/incidents');
    await _load(tester);
    expect(find.text('Konteyner çöktü: web'), findsOneWidget);
    expect(find.text('Site kapalı: blog.example.org'), findsOneWidget);
    expect(find.text('Disk dolu: /'), findsNothing, reason: 'onaylanmış sekmede');
    expect(find.text('Açık 2'), findsOneWidget);
    await golden('png/incidents_list_light_tr.png');
    await _finish(tester);
  });

  testWidgets('olay listesi koyu tema EN, çözülenler sekmesi', (tester) async {
    await _harness().pump(tester, route: '/incidents', dark: true, lang: 'en');
    await _load(tester);
    await tester.tap(find.text('Resolved 2'));
    await settle(tester);
    expect(find.text('Container unhealthy: api'), findsOneWidget);
    await golden('png/incidents_list_dark_en.png');
    await _finish(tester);
  });

  testWidgets('olay listesi: sekme, host ve tür çipleri; satıra dokununca olay ekranı', (tester) async {
    await _harness().pump(tester, route: '/incidents');
    await _load(tester);
    await tester.tap(find.text('Onaylandı 1'));
    await settle(tester);
    expect(find.text('Disk dolu: /'), findsOneWidget);
    await tester.tap(find.text('Açık 2'));
    await tester.tap(find.text('atlas'));
    await settle(tester);
    expect(find.text('Konteyner çöktü: web'), findsNothing);
    await tester.tap(find.text('Tüm hostlar'));
    await tester.tap(find.text('Site'));
    await settle(tester);
    expect(find.text('Konteyner çöktü: web'), findsNothing);
    expect(find.text('Site kapalı: blog.example.org'), findsOneWidget);
    await tester.tap(find.text('Tüm türler'));
    await settle(tester);
    await tester.tap(find.text('Konteyner çöktü: web'));
    await _load(tester);
    expect(find.byType(IncidentScreen), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('olay listesi: özellik açık değilse ve bir host hata verirse', (tester) async {
    await Harness().pump(tester, route: '/incidents');
    await _load(tester);
    expect(find.textContaining('olay odası özelliği açık'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('olay ekranı: ipuçları ve eylemler TR', (tester) async {
    await _harness().pump(tester, route: _open);
    _tall(tester);
    await _load(tester);
    expect(find.text('Neden tahmini'), findsWidgets);
    expect(find.text('kurallar'), findsOneWidget);
    expect(find.textContaining('137'), findsWidgets);
    expect(find.text('web konteynerini yeniden başlat'), findsOneWidget);
    expect(find.text('Yapay zekâ analizi yakında'), findsNothing, reason: 'analiz kendiliğinden çağrılmaz');
    expect(FakeAgent.calls.where((c) => c.$2.endsWith('/analyze')), isEmpty);
    await golden('png/incident_screen_tr.png');
    await _finish(tester);
  });

  testWidgets('olay ekranı: kanıt sekmeleri düz metin gösterir; günlükte arama', (tester) async {
    await _harness().pump(tester, route: _open);
    _tall(tester);
    await _load(tester);
    expect(find.textContaining('<b>not markdown</b>', findRichText: true), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'memory');
    await settle(tester);
    expect(find.text('1/6 satır'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'zzz');
    await settle(tester);
    expect(find.text('Eşleşen satır yok.'), findsOneWidget);
    for (final (tab, text) in [('Konteyner', '137'), ('Git', 'web: raise worker count to 8'), ('Olaylar', 'Container çöktü'), ('Benzer', 'Raised memory limit'), ('Zaman çizelgesi', 'Looking at the memory limit.')]) {
      await _tab(tester, tab);
      expect(find.textContaining(text, findRichText: true), findsWidgets, reason: tab);
    }
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('olay ekranı: onayla, not ekle, çöz (isteğe bağlı not), yeniden aç', (tester) async {
    await _harness().pump(tester, route: _open);
    _tall(tester);
    await _load(tester);
    await tester.tap(find.text('Onayla'));
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$1 == 'POST' && c.$2.endsWith('/ack')), hasLength(1));
    expect(find.text('Onayla'), findsNothing, reason: 'artık onaylandı');
    await tester.tap(find.text('Not').first);
    await settle(tester);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'Bellek sınırı artırılacak');
    await tester.pump();
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    expect(FakeAgent.calls.firstWhere((c) => c.$2.endsWith('/notes')).$3, {'text': 'Bellek sınırı artırılacak'});
    await tester.tap(find.text('Çöz').first);
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Çöz'));
    await _load(tester);
    expect(FakeAgent.calls.firstWhere((c) => c.$2.endsWith('/resolve')).$3, isNull);
    expect(find.text('Yeniden aç'), findsOneWidget);
    await tester.tap(find.text('Yeniden aç'));
    await _load(tester);
    expect(find.text('Çöz'), findsWidgets);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('eylem önizleme alt sayfası ve onay EN', (tester) async {
    await _harness().pump(tester, route: _open, lang: 'en');
    _tall(tester);
    await _load(tester);
    await tester.tap(find.text('Recreate service web'));
    await _load(tester);
    expect(find.text('Valid for 1:58'), findsOneWidget);
    expect(find.text('\$ docker compose -f /home/user/stack/shop/compose.yaml up -d --no-deps web', findRichText: true), findsOneWidget);
    expect(find.text('Medium risk'), findsWidgets);
    await golden('png/incident_action_sheet_en.png');
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await settle(tester);
    expect(find.textContaining('Run "Recreate service web" on argo (PC)?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Run'));
    await _load(tester);
    expect(find.textContaining('Done.'), findsOneWidget);
    final exec = FakeAgent.calls.where((c) => c.$2.endsWith('/execute')).single;
    expect(exec.$3, {'previewToken': 'tpv_1', 'confirm': true});
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('eylem: iptal edilirse çalışmaz; süre dolunca yenilenir; başka eylem çalışırken kapalı', (tester) async {
    await _harness().pump(tester, route: _open, lang: 'en');
    _tall(tester);
    await _load(tester);
    await tester.tap(find.text('Restart container web'));
    await _load(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await settle(tester);
    expect(FakeAgent.calls.where((c) => c.$2.endsWith('/execute')), isEmpty);
    // The token is refused (spent or expired on the agent): an error and a refresh button, then a new token works.
    FakeAgent.incident.issued = 'tpv_other';
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Run'));
    await _load(tester);
    expect(find.textContaining('no longer valid'), findsOneWidget);
    await tester.tap(find.text('Refresh preview'));
    await _load(tester);
    expect(find.widgetWithText(FilledButton, 'Run'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('eylem: başka eylem çalışıyorsa satırlar kapalı', (tester) async {
    FakeAgent.incident.running = 'c-aaaaaaaaaaaa';
    await _harness().pump(tester, route: _open, lang: 'en');
    _tall(tester);
    await _load(tester);
    expect(find.text('Running…'), findsOneWidget);
    await tester.tap(find.text('Recreate service web'));
    await settle(tester);
    expect(find.text('Review action'), findsNothing);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('eylem: komut hatası stderr ile düz metin gösterilir', (tester) async {
    FakeAgent.incident.executeResult = {'ok': false, 'code': 1, 'stderr': 'Error: <script>alert(1)</script>'};
    await _harness().pump(tester, route: _open, lang: 'en');
    _tall(tester);
    await _load(tester);
    await tester.tap(find.text('Restart container web'));
    await _load(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Run'));
    await _load(tester);
    expect(find.text('Failed (exit code 1)'), findsOneWidget);
    expect(find.textContaining('<script>', findRichText: true), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('çözülmüş olay ve zaman çizelgesi TR', (tester) async {
    await _harness().pump(tester, route: '/incidents/inc-eeeeeeeeeeee?host=argo');
    _tall(tester);
    await _load(tester);
    expect(find.text('Yeniden aç'), findsOneWidget);
    expect(find.text('Çözen: cihaz phone'), findsOneWidget);
    await _tab(tester, 'Zaman çizelgesi');
    expect(find.text('Eylem başlatıldı: Konteyner yeniden başlatma'), findsOneWidget);
    await golden('png/incident_resolved_tr.png');
    await _finish(tester);
  });

  testWidgets('bildirim bağlantısı: host adı ile doğru hostta açılır; bulunamazsa hata', (tester) async {
    await _harness().pump(tester, route: '/incidents/inc-cccccccccccc?host=atlas');
    await _load(tester);
    expect(find.text('Site kapalı: blog.example.org'), findsWidgets);
    await _finish(tester);
    // No host hint: every agent host is searched.
    await _harness().pump(tester, route: '/incidents/inc-dddddddddddd');
    await _load(tester);
    expect(find.text('Konteyner sağlıksız: api'), findsWidgets);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('olay bulunamadı: hata metni', (tester) async {
    await _harness().pump(tester, route: '/incidents/inc-ffffffffffff?host=argo');
    await _load(tester);
    expect(find.textContaining('Olay bulunamadı'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('375 px genişlikte taşma yok', (tester) async {
    await _harness().pump(tester, route: _open);
    _tall(tester);
    tester.view.physicalSize = const Size(375 * 2, 1700 * 2);
    await _load(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('web konteynerini yeniden başlat'));
    await _load(tester);
    expect(tester.takeException(), isNull);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('ana ekran: Açık olaylar kartı', (tester) async {
    await _harness().pump(tester);
    await _load(tester);
    expect(find.text('2 açık olay'), findsOneWidget);
    expect(find.textContaining('Site kapalı: blog.example.org'), findsOneWidget);
    await golden('png/incidents_home_card_tr.png');
    await tester.tap(find.text('2 açık olay'));
    await _load(tester);
    expect(find.byType(IncidentsScreen), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('ana ekran: özellik yoksa kart görünmez', (tester) async {
    await Harness().pump(tester);
    await _load(tester);
    expect(find.text('Açık olaylar'), findsNothing);
    await _finish(tester);
    debugDisableShadows = true;
  });

  // --- §13 review fixes ----------------------------------------------------------------------------------------------

  testWidgets('bildirim bağlantısı: olay birden çok hostta varsa host seçtirilir, ilk host tahmin edilmez', (tester) async {
    FakeAgent.incidents['atlas']!.add(Map<String, dynamic>.of(FakeAgent.incidents['argo']!.firstWhere((i) => i['id'] == 'inc-aaaaaaaaaaaa')));
    await _harness().pump(tester, route: '/incidents/inc-aaaaaaaaaaaa?host=bilinmeyen');
    _tall(tester);
    await _load(tester);
    expect(find.textContaining('hangi hosta ait olduğu belli değil'), findsOneWidget);
    expect(find.text('Neden tahmini'), findsNothing);
    await tester.tap(find.text('atlas'));
    await _load(tester);
    expect(find.text('Neden tahmini'), findsWidgets);
    expect(find.textContaining('atlas · web'), findsOneWidget, reason: 'seçilen host başlıkta');
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('bildirim bağlantısı: olay yalnız bir hostta varsa o hostta açılır', (tester) async {
    await _harness().pump(tester, route: '/incidents/inc-cccccccccccc?host=bilinmeyen');
    _tall(tester);
    await _load(tester);
    expect(find.textContaining('hangi hosta ait olduğu belli değil'), findsNothing);
    expect(find.textContaining('atlas · blog.example.org'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('eylem sayfası: sürüklenmez, çift dokunuş tek onay; çalıştıktan sonra dışarı dokunarak kapatınca olay yenilenir', (tester) async {
    await _harness().pump(tester, route: _open, lang: 'en');
    _tall(tester);
    await _load(tester);
    await tester.tap(find.text('Recreate service web'));
    await _load(tester);
    expect(tester.widget<BottomSheet>(find.byType(BottomSheet)).enableDrag, isFalse);
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await tester.tap(find.widgetWithText(FilledButton, 'Run'), warnIfMissed: false);
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Run'));
    await _load(tester);
    expect(find.textContaining('Done.'), findsOneWidget);
    int reads() => FakeAgent.calls.where((c) => c.$1 == 'GET' && c.$2 == '/v1/incidents/inc-aaaaaaaaaaaa').length;
    final before = reads();
    await tester.tapAt(const Offset(20, 20));
    await _load(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(reads(), greaterThan(before), reason: 'sonuç bildirildi, olay yeniden okundu');
    await _finish(tester);
    debugDisableShadows = true;
  });
}
