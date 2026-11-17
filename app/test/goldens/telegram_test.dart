// Telegram newsletters (the Telegram agent is the example server atlas) and the PC's research section (argo), 375 px wide, fake agents.
// To update: flutter test test/goldens/telegram_test.dart --update-goldens
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/telegram/telegram_html.dart';

import '../helpers/harness.dart';
import '../helpers/telegram_fixtures.dart';

Harness _harness() => Harness(
      agent: (h) async => FakeTelegramAgent(h.id),
      agentFeatures: [...Harness.defaultAgentFeatures, 'telegram', 'research'],
    );

Future<void> _load(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _open(WidgetTester tester, String route, {bool dark = false, String lang = 'tr', double height = 844}) async {
  await _harness().pump(tester, route: route, dark: dark, lang: lang);
  tester.view.physicalSize = Size(375 * 2, height * 2);
  await _load(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
  debugDisableShadows = true; // no screenshot taken in interaction tests: restore what Harness changed
}

/// The vertical scrollable of the top page (not text fields or sheets).
Finder _page() => find.descendant(of: find.byType(CustomScrollView).last, matching: find.byType(Scrollable)).first;

/// Scrolls the page until [f] is built, then onto the screen (scrollUntilVisible alone stops in the cache extent).
Future<void> _reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: _page());
  await tester.ensureVisible(f);
  await settle(tester);
}

/// TR or EN text depending on the variant.
String _t(String lang, String tr, String en) => lang == 'tr' ? tr : en;

/// Holds approve calls until [gate] completes (leaving the screen while the call runs).
class _SlowApproveAgent extends FakeTelegramAgent {
  _SlowApproveAgent(super.hostId);
  static Completer<void> gate = Completer<void>();
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    if (path.endsWith('/approve')) await gate.future;
    return super.request(method, path, body: body, query: query, timeout: timeout, headers: headers);
  }
}

const _variants = [(false, 'tr'), (true, 'en')];

void main() {
  setUp(FakeTelegramAgent.reset);

  testWidgets('onay sürerken ekrandan çıkmak hata vermez', (tester) async {
    _SlowApproveAgent.gate = Completer<void>();
    final h = Harness(agent: (h) async => _SlowApproveAgent(h.id), agentFeatures: [...Harness.defaultAgentFeatures, 'telegram', 'research']);
    final container = await h.pump(tester, route: '/telegram/issues/i_weekly_1110?host=atlas');
    await _load(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Gönder'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Gönder'));
    await settle(tester);
    container.router.go('/');
    await settle(tester);
    _SlowApproveAgent.gate.complete();
    await _load(tester);
    expect(tester.takeException(), isNull);
    expect(FakeTelegramAgent.calls.where((c) => c.$2 == 'POST').map((c) => c.$3), ['/v1/telegram/issues/i_weekly_1110/approve']);
    await _finish(tester);
  });

  for (final (dark, lang) in _variants) {
    final v = '${dark ? 'dark' : 'light'}_$lang';

    testWidgets('telegram ana sayfa $v: bot, 2 kişi, bekleyen davet, 2 bülten', (tester) async {
      await _open(tester, '/system/telegram?host=atlas', dark: dark, lang: lang);
      expect(find.text('@tiphysbot'), findsOneWidget);
      expect(find.text('Ayşe Yılmaz'), findsOneWidget);
      expect(find.text('Mehmet'), findsOneWidget);
      await golden('png/telegram_home_$v.png');
      await _reveal(tester, find.text(_t(lang, 'Yeni bülten', 'New newsletter')));
      await settle(tester);
      expect(find.text('Günlük teknoloji ve yapay zekâ'), findsWidgets);
      await golden('png/telegram_home_feeds_$v.png');
      await _finish(tester);
    });

    testWidgets('telegram bot kurulmamış $v', (tester) async {
      FakeTelegramAgent.status = sampleTgStatus(bot: false);
      await _open(tester, '/system/telegram?host=atlas', dark: dark, lang: lang);
      expect(find.text(_t(lang, 'Botu kur', 'Set up the bot')), findsOneWidget);
      await golden('png/telegram_setup_$v.png');
      await _finish(tester);
    });

    testWidgets('telegram davet paylaşım sayfası $v', (tester) async {
      await _open(tester, '/system/telegram?host=atlas', dark: dark, lang: lang);
      await tester.tap(find.text(_t(lang, 'Kişi ekle', 'Add person')));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Babam');
      await tester.tap(find.text(_t(lang, 'Davet bağlantısı oluştur', 'Create invite link')));
      await _load(tester);
      expect(find.text('https://t.me/tiphysbot?start=k3Jd9QpX2mZ7'), findsOneWidget);
      await golden('png/telegram_invite_$v.png');
      await _finish(tester);
    });

    testWidgets('telegram kişi ayrıntısı $v', (tester) async {
      await _open(tester, '/system/telegram?host=atlas', dark: dark, lang: lang);
      await tester.tap(find.text('Ayşe Yılmaz'));
      await _load(tester);
      expect(find.text(_t(lang, 'Bülten alsın', 'Receive newsletters')), findsOneWidget);
      await golden('png/telegram_recipient_$v.png');
      await _finish(tester);
    });

    testWidgets('telegram bülten düzenleyici (günlük şablon) $v', (tester) async {
      await _open(tester, '/system/telegram?host=atlas', dark: dark, lang: lang);
      await _reveal(tester, find.text(_t(lang, 'Yeni bülten', 'New newsletter')));
      await tester.tap(find.text(_t(lang, 'Yeni bülten', 'New newsletter')));
      await _load(tester);
      await tester.tap(find.text('Günlük teknoloji ve yapay zekâ').last);
      await _load(tester);
      expect(find.text('Günlük teknoloji ve yapay zekâ'), findsOneWidget); // name field
      await golden('png/telegram_feed_editor_$v.png');
      await _finish(tester);
    });

    testWidgets('telegram sayı önizlemesi (Telegram benzeri, 6 madde) $v', (tester) async {
      await _open(tester, '/telegram/issues/i_daily_1114?host=atlas', dark: dark, lang: lang, height: 1500);
      expect(find.byType(TelegramMessage), findsOneWidget);
      await golden('png/telegram_issue_$v.png');
      await _finish(tester);
    });

    testWidgets('telegram onay bekleyen sayı $v', (tester) async {
      await _open(tester, '/telegram/issues/i_weekly_1110?host=atlas', dark: dark, lang: lang);
      expect(find.text(_t(lang, 'Gönder', 'Send')), findsOneWidget);
      expect(find.text(_t(lang, 'Vazgeç', 'Cancel')), findsOneWidget);
      await golden('png/telegram_approval_$v.png');
      await _finish(tester);
    });

    testWidgets('PC araştırma bölümü + atlas bağlama sonucu $v', (tester) async {
      await _open(tester, '/system/research?host=argo', dark: dark, lang: lang);
      await tester.tap(find.text(_t(lang, 'Telegram ajanına bağla', 'Connect to a Telegram agent')));
      await _load(tester);
      await tester.tap(find.text('atlas'));
      await _load(tester);
      await tester.tap(find.widgetWithText(TextButton, _t(lang, 'Telegram ajanına bağla', 'Connect to a Telegram agent')));
      await _load(tester);
      expect(find.text(_t(lang, 'atlas bağlandı · ulaşılıyor · Wake-on-LAN', 'atlas connected · reachable · Wake-on-LAN')), findsOneWidget);
      expect(find.textContaining('tps_'), findsNothing);
      await golden('png/research_connect_$v.png');
      await _finish(tester);
    });
  }

  group('etkileşim', () {

    testWidgets('bağlama akışı: PC\'de belirteç, atlas\'a research, sonra durum; belirteç ekranda yok', (tester) async {
      await _open(tester, '/system/research?host=argo');
      await tester.tap(find.text('Telegram ajanına bağla'));
      await _load(tester);
      await tester.tap(find.text('atlas'));
      await _load(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Telegram ajanına bağla'));
      await _load(tester);
      final seq = [for (final c in FakeTelegramAgent.calls) if (c.$2 != 'GET' || c.$3 != '/v1/service-tokens' && c.$3 != '/v1/research/jobs') '${c.$1} ${c.$2} ${c.$3}'];
      expect(seq, ['atlas GET /v1/config', 'argo POST /v1/service-tokens', 'atlas PATCH /v1/config', 'atlas GET /v1/telegram/status']);
      final post = FakeTelegramAgent.calls.firstWhere((c) => c.$2 == 'POST');
      expect(post.$4, {'name': 'atlas', 'scopes': ['research']});
      final patch = FakeTelegramAgent.calls.firstWhere((c) => c.$2 == 'PATCH');
      expect(patch.$4, {'research': {'url': 'https://argo.example.ts.net:7443', 'token': 'tps_fake_never_shown', 'wakeHostId': 'argo'}});
      expect(find.textContaining('tps_'), findsNothing);
      // Test the connection again: status of the chosen host.
      FakeTelegramAgent.calls.clear();
      await tester.tap(find.text('Bağlantıyı test et'));
      await _load(tester);
      expect(FakeTelegramAgent.calls.map((c) => '${c.$1} ${c.$3}'), contains('atlas /v1/telegram/status'));
      expect(find.text('atlas: ulaşılıyor'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('bağlama akışı: atlas ayarı başarısızsa PC\'deki yeni belirteç geri alınır', (tester) async {
      FakeTelegramAgent.patchConfigError = const AgentError('agent.config.passwordRequired', {}, 400);
      await _open(tester, '/system/research?host=argo');
      await tester.tap(find.text('Telegram ajanına bağla'));
      await _load(tester);
      await tester.tap(find.text('atlas'));
      await _load(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Telegram ajanına bağla'));
      await _load(tester);
      expect(FakeTelegramAgent.calls.where((c) => c.$2 == 'DELETE').map((c) => '${c.$1} ${c.$3}'), ['argo /v1/service-tokens/st_atlas-2b7e']);
      expect(find.textContaining('Bağlanamadı'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('bot kurulumu: belirteç yalnız PUT ile gider, alan temizlenir', (tester) async {
      FakeTelegramAgent.status = sampleTgStatus(bot: false);
      await _open(tester, '/system/telegram?host=atlas');
      await tester.enterText(find.byType(TextFormField), '123456:ABCdefGhIJKlmnoPQRstuVWxyz12345678');
      await tester.tap(find.text('Kaydet ve doğrula'));
      await _load(tester);
      final put = FakeTelegramAgent.calls.singleWhere((c) => c.$2 == 'PUT');
      expect(put.$3, '/v1/telegram/bot');
      expect(put.$4, {'token': '123456:ABCdefGhIJKlmnoPQRstuVWxyz12345678'});
      expect(find.text('@tiphysbot'), findsOneWidget);
      expect(find.textContaining('ABCdef'), findsNothing);
      await _finish(tester);
    });

    testWidgets('davet: etiket ve seçili bültenler gönderilir', (tester) async {
      await _open(tester, '/system/telegram?host=atlas');
      await tester.tap(find.text('Kişi ekle'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Babam');
      // Weekly off: only the daily feed.
      await tester.tap(find.widgetWithText(FilterChip, 'Haftalık teknoloji ve yapay zekâ özeti'));
      await settle(tester);
      await tester.tap(find.text('Davet bağlantısı oluştur'));
      await _load(tester);
      final post = FakeTelegramAgent.calls.singleWhere((c) => c.$2 == 'POST');
      expect(post.$4, {'label': 'Babam', 'feedIds': ['f_daily']});
      await _finish(tester);
    });

    testWidgets('kişi: duraklat / abonelik kapat PATCH gönderir', (tester) async {
      await _open(tester, '/system/telegram?host=atlas');
      await tester.tap(find.text('Ayşe Yılmaz'));
      await _load(tester);
      await tester.tap(find.text('Bülten alsın'));
      await _load(tester);
      final patches = FakeTelegramAgent.calls.where((c) => c.$2 == 'PATCH').toList();
      expect(patches.single.$4, {'status': 'paused'});
      await _finish(tester);
    });

    testWidgets('şablondan bülten: POST girdisi ve seçilen alıcılara abonelik', (tester) async {
      await _open(tester, '/system/telegram?host=atlas');
      await _reveal(tester, find.text('Yeni bülten'));
      await tester.tap(find.text('Yeni bülten'));
      await _load(tester);
      await tester.tap(find.text('Haftalık teknoloji ve yapay zekâ özeti').last);
      await _load(tester);
      await _reveal(tester, find.text('Mehmet'));
      await tester.tap(find.text('Mehmet'));
      await settle(tester);
      await tester.tap(find.text('Kaydet').first);
      await _load(tester);
      final post = FakeTelegramAgent.calls.singleWhere((c) => c.$2 == 'POST');
      expect(post.$3, '/v1/telegram/feeds');
      final body = post.$4 as Map;
      expect(body['when'], {'kind': 'weekly', 'time': '09:00', 'days': [1]});
      expect((body['windowHours'], body['minItems'], body['maxItems']), (168, 10, 12));
      expect(body['approval'], {'mode': 'firstN', 'n': 3});
      expect(body.containsKey('id'), isFalse);
      final patch = FakeTelegramAgent.calls.singleWhere((c) => c.$2 == 'PATCH');
      expect(patch.$3, '/v1/telegram/recipients/r_mehmet');
      expect(patch.$4, {'subscriptions': ['f_daily', 'f_new']});
      await _finish(tester);
    });

    testWidgets('onay: Gönder → onay sorusu → approve', (tester) async {
      await _open(tester, '/telegram/issues/i_weekly_1110?host=atlas');
      await tester.tap(find.widgetWithText(FilledButton, 'Gönder'));
      await settle(tester);
      expect(find.text('Bu sayı şimdi 1 kişiye gönderilsin mi?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Gönder'));
      await _load(tester);
      expect(FakeTelegramAgent.calls.where((c) => c.$2 == 'POST').map((c) => c.$3), ['/v1/telegram/issues/i_weekly_1110/approve']);
      await _finish(tester);
    });

    testWidgets('bildirim bağlantısı: host olmadan sayı bulunur', (tester) async {
      await _open(tester, '/telegram/issues/i_daily_1114');
      expect(find.byType(TelegramMessage), findsOneWidget);
      await _finish(tester);
    });
  });
}
