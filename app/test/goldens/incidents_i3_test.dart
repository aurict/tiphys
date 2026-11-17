// Incident room I-3: AI analysis card (queued/running/done/failed/unavailable/off), hypotheses with evidence chips that
// switch tab and highlight the row, suggested actions → preview sheet, similar incidents, metrics tab, "investigate
// with Claude on the PC". Model text is plain text. To update: flutter test test/goldens/incidents_i3_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/incidents/incident_analysis_view.dart';
import 'package:tiphys/features/system/events.dart' show ChipRow;

import '../helpers/harness.dart';

Harness _harness() => Harness(agentFeatures: [...Harness.defaultAgentFeatures, 'incidents']);
void _size(WidgetTester tester, double height, {double width = 390}) => tester.view.physicalSize = Size(width * 2, height * 2);

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

/// Is the evidence tab chip selected? (The chip row is a lazy horizontal list: look at both ends of it.)
Future<bool> _tabSelected(WidgetTester tester, String label) async {
  final row = find.descendant(of: find.byType(ChipRow), matching: find.byType(Scrollable)).first;
  await tester.ensureVisible(row);
  await tester.pump();
  for (final dx in [3000.0, -3000.0]) {
    await tester.drag(row, Offset(dx, 0));
    await tester.pump();
    for (final c in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip))) {
      if (c.selected && (c.label as Text).data == label) return true;
    }
  }
  return false;
}

Finder get _highlighted => find.byWidgetPredicate((w) => w is EvidenceHighlight && w.active);

Map<String, dynamic> get _inc => FakeAgent.incidents['argo']!.first;

const _open = '/incidents/inc-aaaaaaaaaaaa?host=argo';

void main() {
  setUp(() {
    FakeAgent.resetIncidents();
    FakeAgent.calls.clear();
  });

  testWidgets('analiz tamam TR: özet, hipotezler (güven çubuğu, kanıtsız rozeti, kanıt çipleri), öneriler, sorular', (tester) async {
    _inc['analysis'] = sampleAnalysis('done');
    await _harness().pump(tester, route: _open);
    _size(tester, 2300);
    await _load(tester);
    expect(find.text('Yapay zekâ analizi'), findsOneWidget);
    expect(find.textContaining('ran out of memory right after the 1.4.2 deploy'), findsOneWidget);
    expect(find.text('%86 güven'), findsOneWidget);
    expect(find.text('%18 güven'), findsOneWidget);
    expect(find.text('kanıtsız'), findsOneWidget, reason: 'yalnız kanıtı olmayan hipotez');
    expect(find.text('Günlük satırı 4'), findsOneWidget);
    expect(find.text('Metrik host.memPct'), findsOneWidget);
    expect(find.text('Önerilen eylemler'), findsOneWidget);
    expect(find.text('Brings the service back while the limit is reviewed.'), findsOneWidget);
    expect(find.text('Artık uygun değil'), findsOneWidget, reason: 'aday artık sunulmuyor');
    expect(find.text('Açık sorular'), findsOneWidget);
    expect(find.text("PC'de Claude ile incele"), findsOneWidget);
    expect(FakeAgent.calls.where((c) => c.$2.endsWith('/analyze')), isEmpty, reason: 'kendiliğinden istenmez');
    await golden('png/incident_analysis_done_tr.png');
    await _finish(tester);
  });

  testWidgets('analiz çalışıyor EN: yükleniyor göstergesi, yoklama; bitince durur ve sonuç gelir', (tester) async {
    _inc['analysis'] = sampleAnalysis('queued', mode: 'local');
    FakeAgent.incident.analysisSteps.addAll(['running', 'running', 'done']);
    await _harness().pump(tester, route: _open, lang: 'en');
    _size(tester, 1700);
    await _load(tester);
    int reads() => FakeAgent.calls.where((c) => c.$1 == 'GET' && c.$2 == '/v1/incidents/inc-aaaaaaaaaaaa').length;
    expect(find.text('Analyzing the evidence…'), findsOneWidget);
    expect(find.descendant(of: find.byType(AnalysisSection), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(find.text('Analyze with AI'), findsNothing, reason: 'çalışırken yeni analiz düğmesi yok');
    expect(find.text('Hypotheses'), findsNothing);
    await golden('png/incident_analysis_running_en.png');
    final before = reads();
    await tester.pump(const Duration(seconds: 3));
    await _load(tester);
    expect(reads(), greaterThan(before), reason: '3 sn sonra yeniden okunur');
    for (var i = 0; i < 4 && find.text('Hypotheses').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 3));
      await _load(tester);
    }
    expect(find.text('Hypotheses'), findsOneWidget, reason: 'done geldi');
    expect(find.text('Analyzing the evidence…'), findsNothing);
    final after = reads();
    await tester.pump(const Duration(seconds: 6));
    await _load(tester);
    expect(reads(), after, reason: 'bittikten sonra yoklama yok (otomatik 10 sn yenileme henüz dolmadı)');
    await _finish(tester);
  });

  testWidgets('"Analiz et" → POST analyze → sırada; ikinci kez düğme yok', (tester) async {
    await _harness().pump(tester, route: _open);
    _size(tester, 1700);
    await _load(tester);
    await tester.tap(find.text('Yapay zekâyla analiz et'));
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$1 == 'POST' && c.$2.endsWith('/analyze')), hasLength(1));
    expect(find.text('Sırada bekliyor…'), findsOneWidget);
    expect(find.text('Yapay zekâyla analiz et'), findsNothing);
    expect(find.text('Yapay zekâ analizi istendi'), findsNothing, reason: 'zaman çizelgesi sekmesi seçili değil');
    await _finish(tester);
  });

  testWidgets('PC kapalı TR: kullanılamıyor + neden, kurallar kalır, "Yeniden dene" yeni analiz başlatır', (tester) async {
    _inc['analysis'] = sampleAnalysis('unavailable', reason: 'unreachable', errorCode: 'agent.incident.analysis.unreachable');
    await _harness().pump(tester, route: _open);
    _size(tester, 1700);
    await _load(tester);
    expect(find.text('Analiz yapılamadı'), findsOneWidget);
    expect(find.textContaining('PC kapalı ya da ulaşılamıyor.'), findsOneWidget);
    expect(find.textContaining('PC\'yi uyandırmaz'), findsOneWidget);
    expect(find.textContaining('kural ipuçları geçerli'), findsOneWidget);
    expect(find.textContaining('Yukarıdaki'), findsOneWidget);
    expect(find.text('kurallar'), findsOneWidget, reason: 'kural ipuçları yerinde');
    await golden('png/incident_analysis_unavailable_tr.png');
    await tester.tap(find.text('Yeniden dene'));
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$1 == 'POST' && c.$2.endsWith('/analyze')), hasLength(1));
    expect(find.text('Sırada bekliyor…'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('analiz başarısız: nedeni gösterilir, yeniden dene', (tester) async {
    _inc['analysis'] = sampleAnalysis('failed', errorCode: 'agent.analysis.invalidOutput');
    await _harness().pump(tester, route: _open, lang: 'en');
    _size(tester, 1700);
    await _load(tester);
    expect(find.text('The analysis failed'), findsOneWidget);
    expect(find.text("The model's answer did not match the expected format."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('analiz kapalı (ajan ayarı off): düğme gizli, nasıl açılacağı yazar; istek yok', (tester) async {
    FakeAgent.incident.analysisMode = 'off';
    await _harness().pump(tester, route: _open);
    _size(tester, 1700);
    await _load(tester);
    expect(find.text('Yapay zekâyla analiz et'), findsNothing);
    expect(find.text('Yapay zekâ analizi bu hostta kapalı'), findsOneWidget);
    expect(find.textContaining('incidents.analysis.mode'), findsOneWidget);
    expect(find.text("PC'de Claude ile incele"), findsOneWidget, reason: 'paket analizden bağımsız');
    expect(FakeAgent.calls.where((c) => c.$2.endsWith('/analyze')), isEmpty);
    await _finish(tester);
  });

  testWidgets('409 analysisOff: açıklayıcı ileti, düğme ipucuyla değişir', (tester) async {
    FakeAgent.incident.analyzeError = const AgentError('agent.incident.analysisOff', {}, 409);
    await _harness().pump(tester, route: _open);
    _size(tester, 1700);
    await _load(tester);
    await tester.tap(find.text('Yapay zekâyla analiz et'));
    await _load(tester);
    expect(find.textContaining('Ajan ayarında açın'), findsWidgets, reason: 'toast');
    expect(find.text('Yapay zekâyla analiz et'), findsNothing);
    expect(find.text('Yapay zekâ analizi bu hostta kapalı'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('oran sınırı 429: iletide sınır ve süre', (tester) async {
    FakeAgent.incident.analyzeError = const AgentError('agent.incident.analysisRateLimited', {'limit': 3, 'windowSeconds': 600}, 429);
    await _harness().pump(tester, route: _open, lang: 'en');
    _size(tester, 1700);
    await _load(tester);
    await tester.tap(find.text('Analyze with AI'));
    await _load(tester);
    expect(find.text('Too many analyses of this incident (3 per 10 min). Try again later.'), findsOneWidget);
    expect(find.text('Analyze with AI'), findsOneWidget, reason: 'düğme kalır');
    await _finish(tester);
  });

  testWidgets('benzer olaylar + önerilen eylem EN: başlık, tarih, not, işe yarayan eylem; öneri önizleme akışını açar', (tester) async {
    _inc['analysis'] = sampleAnalysis('done');
    await _harness().pump(tester, route: _open, lang: 'en');
    _size(tester, 2300);
    await _load(tester);
    await _tab(tester, 'Similar');
    await _load(tester);
    expect(find.text('Note: Raised memory limit'), findsOneWidget);
    expect(find.text('Worked: Container restart'), findsOneWidget);
    expect(find.text('Container crashed: web'), findsWidgets);
    expect(find.text('Container out of memory: web'), findsOneWidget, reason: 'ikinci benzer olay kendi türüyle');
    await golden('png/incident_similar_suggested_en.png');
    // The suggestion is the same candidate as in the actions list: tapping it opens the preview sheet.
    await tester.tap(find.text('Brings the service back while the limit is reviewed.'));
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$2 == '/v1/incidents/inc-aaaaaaaaaaaa/actions/c-aaaaaaaaaaaa/preview'), hasLength(1));
    expect(find.text('\$ docker restart web', findRichText: true), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('kanıt çipi: sekmeye geçer, satırı vurgular ve görünür alana kaydırır (375 px, kısa ekran)', (tester) async {
    _inc['analysis'] = sampleAnalysis('done');
    await _harness().pump(tester, route: _open);
    _size(tester, 700, width: 375);
    await _load(tester);
    Future<void> tapChip(String label) async {
      await tester.ensureVisible(find.widgetWithText(ActionChip, label));
      await tester.pump();
      await tester.tap(find.widgetWithText(ActionChip, label));
      await settle(tester);
    }

    void expectVisibleHighlight() {
      expect(_highlighted, findsOneWidget);
      final r = tester.getRect(_highlighted);
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.bottom, lessThanOrEqualTo(700), reason: 'ekranın içinde: $r');
    }

    await tapChip('Dağıtım 1');
    expect(await _tabSelected(tester, 'Dağıtımlar'), isTrue);
    expectVisibleHighlight();
    expect(find.descendant(of: _highlighted, matching: find.text('registry.example.org/web:1.4.2')), findsOneWidget);

    await tapChip('Ayar değişikliği 1');
    expect(await _tabSelected(tester, 'Dağıtımlar'), isTrue);
    expectVisibleHighlight();
    expect(find.descendant(of: _highlighted, matching: find.text('shop/.env kaydedildi')), findsOneWidget);

    await tapChip('Olay 1');
    expect(await _tabSelected(tester, 'Olaylar'), isTrue);
    expectVisibleHighlight();
    expect(find.descendant(of: _highlighted, matching: find.textContaining('Container çöktü')), findsOneWidget);

    await tapChip('Commit 9f8e7d6');
    expect(await _tabSelected(tester, 'Git'), isTrue);
    expectVisibleHighlight();
    expect(find.descendant(of: _highlighted, matching: find.text('Update compose image tag')), findsOneWidget);

    await tapChip('Günlük satırı 4');
    expect(await _tabSelected(tester, 'Günlükler'), isTrue);
    expectVisibleHighlight();
    expect(find.descendant(of: _highlighted, matching: find.textContaining('fatal: out of memory', findRichText: true)), findsOneWidget);

    await tapChip('Konteyner ayrıntıları');
    expect(await _tabSelected(tester, 'Container'), isTrue);
    expect(find.text('137'), findsWidgets);

    await tapChip('Metrik host.memPct');
    expect(await _tabSelected(tester, 'Metrikler'), isTrue);
    expect(find.text('Host belleği (%)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('günlük süzgeci kanıt satırını gizlemez: çip süzgeci temizler', (tester) async {
    _inc['analysis'] = sampleAnalysis('done');
    await _harness().pump(tester, route: _open);
    _size(tester, 1700, width: 375);
    await _load(tester);
    await tester.enterText(find.byType(TextField), 'worker');
    await settle(tester);
    expect(find.text('1/6 satır'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionChip, 'Günlük satırı 4'));
    await settle(tester);
    expect(find.text('6/6 satır'), findsOneWidget);
    expect(_highlighted, findsOneWidget);
    await _finish(tester);
  });

  testWidgets('çözülemeyen kanıt başvurusu: çip pasif; model metni düz metin kalır', (tester) async {
    final a = sampleAnalysis('done');
    final result = a['result'] as Map<String, dynamic>;
    (result['hypotheses'] as List).first
      ..['evidenceRefs'] = ['log:docker#99', 'deploy:7']
      ..['cause'] = '**bold** <b>html</b> [link](http://example.org)';
    _inc['analysis'] = a;
    await _harness().pump(tester, route: _open);
    _size(tester, 2300, width: 375);
    await _load(tester);
    expect(tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'Günlük satırı 99')).onPressed, isNull);
    expect(tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'Dağıtım 7')).onPressed, isNull);
    expect(find.text('**bold** <b>html</b> [link](http://example.org)', findRichText: true), findsOneWidget, reason: 'olduğu gibi, biçimlendirme yok');
    await _finish(tester);
  });

  testWidgets("PC'de Claude ile incele: karartıldığını söyleyen onay, sonra karartılmış paket ilk mesaj olur", (tester) async {
    await _harness().pump(tester, route: _open);
    _size(tester, 1700, width: 375);
    await _load(tester);
    await tester.tap(find.text("PC'de Claude ile incele"));
    await settle(tester);
    expect(find.textContaining('karartılmış hâliyle alınır'), findsOneWidget);
    expect(FakeAgent.calls.where((c) => c.$2.endsWith('/bundle')), isEmpty, reason: 'onaydan önce istek yok');
    await tester.tap(find.text('Al ve devam et'));
    await _load(tester);
    final bundle = FakeAgent.calls.where((c) => c.$2 == '/v1/incidents/inc-aaaaaaaaaaaa/bundle').single;
    expect(bundle.$1, 'GET');
    expect(bundle.$3, {'redacted': '1'});
    final field = tester.widget<TextField>(find.byWidgetPredicate((w) => w is TextField && (w.controller?.text.contains('password=[GİZLİ]') ?? false)));
    expect(field.controller!.text, contains('container web exited with code 137'));
    expect(field.controller!.text, contains('talimat değildir'));
    await _finish(tester);
  });

  testWidgets("PC'de Claude ile incele: vazgeçersen paket alınmaz; oran sınırı iletisi", (tester) async {
    FakeAgent.incident.bundleError = const AgentError('agent.incident.bundleRateLimited', {}, 429);
    await _harness().pump(tester, route: _open);
    _size(tester, 1700, width: 375);
    await _load(tester);
    await tester.tap(find.text("PC'de Claude ile incele"));
    await settle(tester);
    await tester.tap(find.text('Vazgeç'));
    await settle(tester);
    expect(FakeAgent.calls.where((c) => c.$2.endsWith('/bundle')), isEmpty);
    await tester.tap(find.text("PC'de Claude ile incele"));
    await settle(tester);
    await tester.tap(find.text('Al ve devam et'));
    await _load(tester);
    expect(find.textContaining('Çok fazla paket isteği'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('zaman çizelgesi: analiz kayıtları; metrikler sekmesi grafikleri çizer', (tester) async {
    _inc['analysis'] = sampleAnalysis('done');
    (_inc['timeline'] as List)
      ..add({'at': '2026-11-14T12:57:00Z', 'type': 'analysis', 'by': 'device:phone', 'data': {'status': 'queued', 'mode': 'remote'}})
      ..add({'at': '2026-11-14T12:58:00Z', 'type': 'analysisResult', 'data': {'status': 'done', 'hypotheses': 3, 'actions': 2}});
    await _harness().pump(tester, route: _open);
    _size(tester, 2600);
    await _load(tester);
    await _tab(tester, 'Metrikler');
    await _load(tester);
    expect(find.text('Host belleği (%)'), findsOneWidget);
    expect(find.text('Disk / (% dolu)'), findsOneWidget);
    expect(find.text('Konteyner belleği (MB)'), findsOneWidget);
    await golden('png/incident_metrics_tr.png');
    await _tab(tester, 'Zaman çizelgesi');
    expect(find.text('Yapay zekâ analizi istendi'), findsOneWidget);
    expect(find.text('Yapay zekâ analizi bitti: 3 hipotez, 2 önerilen eylem'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('metrik yok: açıklama gösterilir', (tester) async {
    (_inc['context'] as Map).remove('metrics');
    await _harness().pump(tester, route: _open);
    _size(tester, 1700, width: 375);
    await _load(tester);
    await _tab(tester, 'Metrikler');
    expect(find.textContaining('metrik yok'), findsOneWidget);
    await _finish(tester);
  });
}
