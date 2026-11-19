// agy (Antigravity CLI) sessions: list + previous conversations, new-session sheet, chat (streaming upsert, tool
// update merge, permission answers, busy 409, cancel, ended), "continue on the PC" for agy and Claude. Turkish
// goldens: agy list, agy chat with a permission card, continue-on-PC sheet. Run with TZ=Europe/Berlin.
// To update: TZ=Europe/Berlin flutter test test/goldens/agy_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:tiphys/core/agent/agent_client.dart';

import '../helpers/harness.dart';

Harness _h({bool agy = true}) => Harness(agentFeatures: [...Harness.defaultAgentFeatures, if (agy) 'agy']);

FakeAgyState get _st => FakeAgent.agy;

const _chatPath = '/agy/$agySessionId';
const _chat = '$_chatPath?host=argo';

Future<void> _load(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
  debugDisableShadows = true;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await tester.pump();
  await tester.tap(f.first);
  await _load(tester);
}

Future<void> _tapText(WidgetTester tester, String text) => _tap(tester, find.text(text));

Future<void> _menu(WidgetTester tester, String item) async {
  await _tap(tester, find.byTooltip('Daha fazla'));
  await _tapText(tester, item);
}

Finder _rich(String s) => find.textContaining(s, findRichText: true);

List<(String, String, Object?)> _sent(String method, String path) => [
  for (final c in FakeAgent.calls)
    if (c.$1 == method && c.$2 == path) c,
];

String _route(ProviderContainer c) => c.router.routerDelegate.currentConfiguration.last.matchedLocation;

/// Captures what the app puts on the clipboard.
List<String> _clipboard(WidgetTester tester) {
  final out = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') out.add((call.arguments as Map)['text'] as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return out;
}

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.agy = FakeAgyState();
  });

  group('liste', () {
    testWidgets('TR: açık oturum, önceki konuşmalar ("açık" rozeti), klasör seçici; Claude sekmesinde giriş', (tester) async {
      await _h().pump(tester, route: '/agy');
      await _load(tester);
      expect(find.text('AÇIK OTURUMLAR'), findsOneWidget);
      expect(find.text('Desktop/tiphys · bitti'), findsOneWidget);
      expect(find.text('ÖNCEKİ KONUŞMALAR'), findsOneWidget);
      expect(find.text('Docker mimarisi'), findsOneWidget);
      expect(find.text('Durum raporu'), findsNWidgets(2), reason: 'açık oturum + konuşma listesi');
      expect(find.text('açık'), findsOneWidget, reason: 'liveId olan konuşma');
      expect(_sent('GET', '/v1/agy/conversations').single.$3, {'cwd': isA<String>()});
      await golden('png/agy_list_light_tr.png');
      await _finish(tester);
    });

    testWidgets('açık konuşmaya dokunmak canlı oturumu açar; önceki konuşma "Devam et" sayfası açar ve kaldığı yerden başlatır', (tester) async {
      final c = await _h().pump(tester, route: '/agy');
      await _load(tester);
      await _tapText(tester, 'açık');
      expect(_route(c), _chatPath);
      c.router.pop();
      await _load(tester);
      await _tapText(tester, 'Docker mimarisi');
      expect(find.text('Devam et'), findsWidgets);
      await _tap(tester, find.byIcon(LucideIcons.arrowUp));
      final post = _sent('POST', '/v1/agy/sessions').single.$3 as Map;
      expect(post['resume'], 's-old-0002');
      expect(post['cwd'], agyCwd);
      expect(post.containsKey('modeId'), isFalse);
      expect(_route(c), '/agy/agy-bbbbbbbbbbbb');
      await _finish(tester);
    });

    testWidgets('klasör seçici önceki konuşmaları o klasör için yeniden ister', (tester) async {
      await _h().pump(tester, route: '/agy');
      await _load(tester);
      await _tapText(tester, '~/Desktop/website');
      await _tapText(tester, 'Seç');
      final asked = [for (final c in _sent('GET', '/v1/agy/conversations')) (c.$3 as Map)['cwd']];
      expect(asked.length, 2);
      expect(asked.last, '~');
      await _finish(tester);
    });

    testWidgets('özellik kapalıysa: Claude sekmesinde giriş yok, /agy açıklama gösterir; açıksa giriş /agy açar', (tester) async {
      await _h(agy: false).pump(tester, route: '/claude');
      await _load(tester);
      expect(find.text('Antigravity CLI oturumları'), findsNothing);
      await _finish(tester);

      await _h(agy: false).pump(tester, route: '/agy');
      await _load(tester);
      expect(find.textContaining('agy özelliğini aç'), findsOneWidget);
      await _finish(tester);

      final c = await _h().pump(tester, route: '/claude');
      await _load(tester);
      await _tapText(tester, 'Antigravity CLI oturumları');
      expect(_route(c), '/agy');
      expect(find.text('ÖNCEKİ KONUŞMALAR'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('liste hataları: hız sınırı ve ajan hatası metinleri', (tester) async {
      FakeAgent.agy.errors['GET /v1/agy/conversations'] = const AgentError('agent.agy.rateLimited', {}, 429);
      await _h().pump(tester, route: '/agy');
      await _load(tester);
      expect(find.text('Çok sık istendi; biraz bekleyip tekrar dene.'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('yeni oturum', () {
    testWidgets('kip açıklaması, ilk mesaj ve kip gövdeye girer; sohbet açılır', (tester) async {
      final c = await _h().pump(tester, route: '/agy');
      await _load(tester);
      await _tap(tester, find.byTooltip('Yeni agy oturumu'));
      expect(find.text('Varsayılan'), findsOneWidget);
      expect(find.text('agy her işlemden önce sana sorar.'), findsOneWidget);
      await _tapText(tester, 'Plan');
      expect(find.text('Yalnızca plan hazırlar; dosyalara dokunmaz.'), findsOneWidget);
      await _tapText(tester, 'Otomatik');
      expect(find.text('İşlemlerin çoğunu sormadan yapar. Dikkatli kullan.'), findsOneWidget);
      await _tapText(tester, 'Düzenlemeleri kabul et');
      expect(find.textContaining('komutlar için yine sorar'), findsOneWidget);
      await _tapText(tester, 'Plan');
      await tester.enterText(find.byType(TextField), 'Testleri çalıştır');
      await _tapText(tester, 'Başlat');
      final post = _sent('POST', '/v1/agy/sessions').single.$3 as Map;
      expect(post['prompt'], 'Testleri çalıştır');
      expect(post['modeId'], 'plan');
      expect(_route(c), '/agy/agy-bbbbbbbbbbbb');
      await _finish(tester);
    });

    testWidgets('varsayılan kip gövdeye girmez; ilk mesaj boşsa prompt yok; klasör seçilebilir', (tester) async {
      await _h().pump(tester, route: '/agy');
      await _load(tester);
      await _tap(tester, find.byTooltip('Yeni agy oturumu'));
      await _tap(tester, find.descendant(of: find.byType(BottomSheet), matching: find.text('~/Desktop/website')));
      await _tapText(tester, 'Seç');
      await _tapText(tester, 'Başlat');
      expect(_sent('POST', '/v1/agy/sessions').single.$3, {'cwd': '~'});
      await _finish(tester);
    });

    testWidgets('hata: çok fazla oturum; bilinmeyen kip', (tester) async {
      await _h().pump(tester, route: '/agy');
      await _load(tester);
      await _tap(tester, find.byTooltip('Yeni agy oturumu'));
      FakeAgent.agy.errors['POST /v1/agy/sessions'] = const AgentError('agent.agy.tooManySessions', {}, 409);
      await _tapText(tester, 'Başlat');
      expect(find.text('Çok fazla açık agy oturumu var; birini kapat.'), findsOneWidget);
      FakeAgent.agy.errors['POST /v1/agy/sessions'] = const AgentError('agent.agy.unknownMode', {}, 400);
      await _tapText(tester, 'Başlat');
      expect(find.text('agy bu kipi tanımıyor.'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('sohbet', () {
    testWidgets('TR: önceki konuşma soluk, düşünce, markdown, plan, araç, izin kartı (golden)', (tester) async {
      _st.waitingScenario();
      await _h().pump(tester, route: _chat);
      await _load(tester);
      expect(find.text('önceki konuşma'), findsOneWidget);
      expect(find.text('Düşünme'), findsOneWidget);
      expect(_rich('çalıştırıyorum'), findsOneWidget);
      expect(find.text('Plan'), findsOneWidget);
      expect(find.text('npm test'), findsWidgets);
      expect(find.text('npm test -- --run'), findsWidgets);
      expect(find.text('agy izin istiyor'), findsOneWidget);
      expect(find.text('İzin ver'), findsOneWidget);
      expect(find.text('Reddet'), findsOneWidget);
      expect(find.text('Kip: Varsayılan'), findsOneWidget);
      expect(find.text('Gemini 4 Neon'), findsOneWidget);
      expect(find.text('%38'), findsOneWidget);
      expect(find.text('seni bekliyor'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse, reason: 'beklerken giriş kapalı');
      expect(find.text('agy senden izin bekliyor…'), findsOneWidget);
      // Opacity of the replayed pair.
      expect(find.ancestor(of: find.text('Önceki soru'), matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1)), findsOneWidget);
      await golden('png/agy_chat_light_tr.png');
      await _finish(tester);
    });

    testWidgets('izin ver: seçenek kimliği gider, kart yanıtı gösterir, giriş çalışırken kapalı', (tester) async {
      _st.waitingScenario();
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await _tapText(tester, 'İzin ver');
      expect(_st.log, ['POST permissions/a1b2c3d4e5f6 allow']);
      expect(find.text('Yanıt: İzin ver'), findsOneWidget);
      expect(find.text('Reddet'), findsNothing);
      expect(find.text('agy çalışıyor; bitmesini bekle…'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await _finish(tester);
    });

    testWidgets('reddet', (tester) async {
      _st.waitingScenario();
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await _tapText(tester, 'Reddet');
      expect(_st.log, ['POST permissions/a1b2c3d4e5f6 deny']);
      expect(find.text('Yanıt: Reddet'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('izin isteği artık yoksa 404 metni; kart düğmeleri kalır', (tester) async {
      _st.waitingScenario();
      await _h().pump(tester, route: _chat);
      await _load(tester);
      _st.errors['POST /v1/agy/sessions/$agySessionId/permissions/a1b2c3d4e5f6'] = const AgentError('agent.agy.permissionNotFound', {}, 404);
      await _tapText(tester, 'İzin ver');
      expect(find.text('Bu izin isteği artık geçerli değil.'), findsOneWidget);
      expect(find.text('Reddet'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('akış: aynı eid güncellenir (çoğalmaz), sonraki istek after = en yüksek seq; toolUpdate aracı günceller', (tester) async {
      _st.reset();
      _st.emit({'kind': 'user', 'text': 'Selam'});
      final msg = _st.emit({'kind': 'agent', 'text': 'Merhaba'});
      _st.emit({
        'kind': 'tool',
        'toolCallId': 't1',
        'title': 'ls',
        'toolKind': 'execute',
        'status': 'in_progress',
        'paths': <String>[],
        'command': 'ls -la',
      });
      _st.setStatus('running');
      await _h().pump(tester, route: _chat);
      await _load(tester);
      expect(_rich('Merhaba'), findsOneWidget);
      expect(find.byIcon(LucideIcons.check), findsNothing);
      expect(find.text('agy çalışıyor…'), findsOneWidget);

      _st.appendText(msg['eid'] as int, ' dünya');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(_rich('Merhaba dünya'), findsOneWidget);
      expect(_rich('Merhaba'), findsOneWidget, reason: 'aynı mesaj, ikinci kopya yok');

      _st.emit({'kind': 'toolUpdate', 'toolCallId': 't1', 'status': 'completed'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('ls'), findsOneWidget, reason: 'toolUpdate ayrı kart açmaz');
      expect(find.byIcon(LucideIcons.check), findsOneWidget);

      final polls = [for (final c in _sent('GET', '/v1/agy/sessions/$agySessionId')) c.$3 as Map];
      expect(polls.first['after'], '0');
      expect(int.parse(polls.last['after'] as String), greaterThan(3));
      expect(polls.last['wait'], '20000');
      await _finish(tester);
    });

    testWidgets('gönder: mesaj gider, durum çalışıyora döner, iptal düğmesi çıkar; iptal "iptal edildi" gösterir', (tester) async {
      _st.reset();
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await tester.enterText(find.byType(TextField), 'merhaba');
      await tester.pump();
      await _tap(tester, find.byIcon(LucideIcons.arrowUp));
      expect(_st.log, ['POST messages merhaba']);
      expect(find.text('merhaba'), findsOneWidget, reason: 'kullanıcı mesajı olay akışından');
      expect(find.text('agy çalışıyor…'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await _tap(tester, find.byTooltip('İptal et'));
      expect(_st.log.last, 'POST cancel');
      expect(find.text('iptal edildi'), findsOneWidget);
      expect(find.byTooltip('İptal et'), findsNothing);
      await _finish(tester);
    });

    testWidgets('409 agent.agy.busy: metin kutuda kalır, hata gösterilir', (tester) async {
      _st.reset();
      _st.forceBusy = true;
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await tester.enterText(find.byType(TextField), 'yine de gönder');
      await tester.pump();
      await _tap(tester, find.byIcon(LucideIcons.arrowUp));
      expect(find.text('agy şu an çalışıyor ya da izin bekliyor; bitince tekrar dene.'), findsOneWidget);
      expect(find.text('yine de gönder'), findsOneWidget);
      expect(_st.log, isEmpty);
      await _finish(tester);
    });

    testWidgets('kapanmış oturum: giriş yok, açıklama ve "Konuşmayı yeniden aç"; hata olayı metne çevrilir', (tester) async {
      _st.reset();
      _st.emit({'kind': 'user', 'text': 'Selam'});
      _st.emit({'kind': 'error', 'text': 'agent.agy.promptFailed'});
      _st.emit({'kind': 'error', 'text': 'agy exited'});
      _st.setStatus('ended');
      await _h().pump(tester, route: _chat);
      await _load(tester);
      expect(find.text('Oturum kapandı.'), findsOneWidget);
      expect(find.text('Mesaj agy’ye iletilemedi.'), findsOneWidget);
      expect(find.text('agy exited'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await _tapText(tester, 'Konuşmayı yeniden aç');
      await _tap(tester, find.byIcon(LucideIcons.arrowUp));
      final post = _sent('POST', '/v1/agy/sessions').single.$3 as Map;
      expect(post['resume'], agyConversationId);
      await _finish(tester);
    });

    testWidgets('hata durumu ve oturum yok (404)', (tester) async {
      _st.reset();
      _st.setStatus('error');
      await _h().pump(tester, route: _chat);
      await _load(tester);
      expect(find.text('Oturum hata verdi.'), findsOneWidget);
      await _finish(tester);

      await _h().pump(tester, route: '/agy/agy-cccccccccccc?host=argo');
      await _load(tester);
      expect(find.text('Bu agy oturumu artık yok. Önceki konuşmalardan yeniden aç.'), findsWidgets);
      await _finish(tester);
    });

    testWidgets('kip ve model rozetleri seçici açar ve değişikliği gönderir', (tester) async {
      _st.reset();
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await _tapText(tester, 'Kip: Varsayılan');
      expect(find.text('Kip seç'), findsOneWidget);
      expect(find.text('Yalnızca plan hazırlar; dosyalara dokunmaz.'), findsOneWidget);
      await _tapText(tester, 'Plan');
      expect(_st.log.last, 'POST mode plan');
      expect(find.text('Kip: Plan'), findsNWidgets(2), reason: 'rozet + akıştaki kip değişikliği satırı');
      await _tapText(tester, 'Gemini 4 Neon');
      await _tapText(tester, 'Gemini 3.8 Flash');
      expect(_st.log.last, 'POST model gemini-3.8-flash');
      expect(find.text('Gemini 3.8 Flash'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('uzun bekleme yalnızca ekran görünürken sürer: ekran kapanınca istek durur', (tester) async {
      _st.reset();
      await _h().pump(tester, route: _chat);
      await _load(tester);
      final before = _sent('GET', '/v1/agy/sessions/$agySessionId').length;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 2));
      expect(_sent('GET', '/v1/agy/sessions/$agySessionId').length, before, reason: 'kapanan ekran yeni istek açmaz');
      debugDisableShadows = true;
    });
  });

  group('PC’de devam et', () {
    testWidgets('agy, boştayken: doğrudan komut sayfası (golden), Kopyala panoya yazar', (tester) async {
      _st.reset();
      final clip = _clipboard(tester);
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await _menu(tester, 'PC’de devam et');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text("cd '$agyCwd' && agy --conversation $agyConversationId"), findsOneWidget);
      expect(find.text('PC’de bir terminalde yapıştırın.'), findsOneWidget);
      await golden('png/agy_continue_pc_light_tr.png');
      await _tapText(tester, 'Kopyala');
      expect(clip, ["cd '$agyCwd' && agy --conversation $agyConversationId"]);
      expect(find.text('Kopyalandı'), findsOneWidget);
      expect(_st.log, isEmpty, reason: 'durdurmaya gerek yok');
      await _finish(tester);
    });

    testWidgets('agy, izin beklerken: önce durdurulur (cancel sonra close), sonra komut', (tester) async {
      _st.waitingScenario();
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await _menu(tester, 'PC’de devam et');
      expect(find.textContaining('iki program aynı konuşmaya yazarsa konuşma ikiye ayrılır'), findsOneWidget);
      expect(_st.log, isEmpty);
      await _tapText(tester, 'Durdur ve komutu göster');
      expect(_st.log, ['POST cancel', 'DELETE']);
      expect(find.text("cd '$agyCwd' && agy --conversation $agyConversationId"), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('agy: vazgeçilirse hiçbir şey durdurulmaz; komut yoksa açıklama', (tester) async {
      _st.waitingScenario();
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await _menu(tester, 'PC’de devam et');
      await _tapText(tester, 'Vazgeç');
      expect(_st.log, isEmpty);
      expect(find.text('PC’de bir terminalde yapıştırın.'), findsNothing);
      await _finish(tester);

      _st.reset();
      _st.session = {..._st.session, 'resumeCommand': null, 'conversationId': ''};
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await _menu(tester, 'PC’de devam et');
      expect(find.text('Bu oturum için henüz bir komut yok.'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('agy: durdurma başarısız olursa hata gösterilir, komut verilmez', (tester) async {
      _st.waitingScenario();
      _st.errors['DELETE /v1/agy/sessions/$agySessionId'] = const AgentError('agent.agy.timeout', {}, 504);
      await _h().pump(tester, route: _chat);
      await _load(tester);
      await _menu(tester, 'PC’de devam et');
      await _tapText(tester, 'Durdur ve komutu göster');
      expect(find.text('agy zamanında yanıt vermedi.'), findsOneWidget);
      expect(find.text('PC’de bir terminalde yapıştırın.'), findsNothing);
      await _finish(tester);
    });

    testWidgets('Claude, çalışan oturum: kesilir ve kapatılır, sonra komut', (tester) async {
      await _h().pump(tester, route: '/claude/session/a1');
      await _load(tester);
      await _menu(tester, 'PC’de devam et');
      expect(find.textContaining('iki program aynı konuşmaya yazarsa'), findsOneWidget);
      await _tapText(tester, 'Durdur ve komutu göster');
      final order = [
        for (final c in FakeAgent.calls)
          if (c.$2.startsWith('/v1/claude/sessions/a1/') || (c.$1 == 'DELETE')) '${c.$1} ${c.$2}',
      ];
      expect(order, ['POST /v1/claude/sessions/a1/interrupt', 'DELETE /v1/claude/sessions/a1']);
      expect(find.text("cd '/home/user/Desktop/website' && claude --resume s1"), findsOneWidget);
      expect(find.text('PC’de bir terminalde yapıştırın.'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('Claude, bitmiş oturum (md1): komut yok → açıklama; geçmiş kaydı: sdk kimliği + klasörden komut kurulur', (tester) async {
      await _h().pump(tester, route: '/claude/session/md1');
      await _load(tester);
      await _menu(tester, 'PC’de devam et');
      expect(find.text('Bu oturum için henüz bir komut yok.'), findsOneWidget);
      await _finish(tester);

      final clip = _clipboard(tester);
      const id = '7e08e218-0000-4000-8000-000000000001';
      await _h().pump(tester, route: '/claude/history/$id?cwd=${Uri.encodeComponent('/home/user/projects/web')}');
      await _load(tester);
      await _menu(tester, 'PC’de devam et');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text("cd '/home/user/projects/web' && claude --resume $id"), findsOneWidget);
      await _tapText(tester, 'Kopyala');
      expect(clip.single, "cd '/home/user/projects/web' && claude --resume $id");
      await _finish(tester);
    });

    testWidgets('EN: metinler İngilizce', (tester) async {
      _st.reset();
      await _h().pump(tester, route: _chat, lang: 'en');
      await _load(tester);
      expect(find.text('Mode: Default'), findsOneWidget);
      await _tap(tester, find.byTooltip('More'));
      await _tapText(tester, 'Continue on the PC');
      expect(find.text('Paste it in a terminal on the PC.'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      await _finish(tester);
    });
  });
}
