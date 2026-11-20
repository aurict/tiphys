// "Send to Claude" (PLAN.md §16 F4): multi-select on the host screen, the send sheet (modes, bypass confirmation, targets),
// the security session in the chat (sudo dialog, panel with timers and backups, re-audit card) and the targets editor.
// To update: TZ=Europe/Berlin flutter test test/goldens/security_fix_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/claude/security_session.dart';
import 'package:tiphys/features/security/security_fix_sheet.dart' show FixSendSheet;

import '../helpers/fix_fixtures.dart';
import '../helpers/harness.dart';

final _chips = find.descendant(of: find.byType(FixSendSheet), matching: find.byType(ChoiceChip));

void _tall(WidgetTester tester, [double height = 1900]) => tester.view.physicalSize = Size(390 * 2, height * 2);

Future<void> _load(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
  debugDisableShadows = true;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await tester.pump();
  await tester.tap(f.first);
  await _load(tester);
}

/// Host screen of orion → selection mode → two findings and one change ticked → "Send to Claude".
Future<void> _openSheet(WidgetTester tester, {bool dark = false}) async {
  await fixHarness().pump(tester, route: '/security/orion?host=argo', dark: dark);
  _tall(tester, 1900);
  await _load(tester);
  await tester.tap(find.byTooltip('Seç'));
  await _load(tester);
  await _tap(tester, find.text('SSH parola ile girişe açık'));
  await _tap(tester, find.text('tcp/2222').first);
  await _tap(tester, find.textContaining('alice SHA256:EXAMPLE'));
  await _tap(tester, find.text("Claude'a ilet"));
}

void main() {
  setUp(() {
    FakeAgent.resetSecurity();
    FakeAgent.calls.clear();
    FixAgent.reset();
  });

  testWidgets('seçim kipi: onay kutuları, sayaç, brief isteği; gönderme sayfası (açık, TR)', (tester) async {
    await fixHarness().pump(tester, route: '/security/orion?host=argo');
    _tall(tester, 1900);
    await _load(tester);
    await tester.tap(find.byTooltip('Seç'));
    await _load(tester);
    expect(find.byType(Checkbox), findsWidgets);
    expect(find.text('0 seçili'), findsOneWidget);
    await _tap(tester, find.text('SSH parola ile girişe açık'));
    expect(find.text('1 seçili'), findsOneWidget);
    await golden('png/security_fix_select_light_tr.png');
    await _tap(tester, find.text('Tümünü seç'));
    expect(find.text('8 seçili'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('gönderme sayfası: brief istekte seçilen öğeler, öğe hatası, hedef durumu, önizleme', (tester) async {
    await _openSheet(tester);
    _tall(tester, 2100);
    await _load(tester);
    final body = FixAgent.fix.sent['brief'] as Map;
    expect((body['items'] as List).length, 3);
    expect((body['items'] as List)[1], {'type': 'change', 'host': 'orion', 'id': 'ports|tcp/2222'});
    expect(body['language'], 'tr');
    expect(find.text('Seçilenler (3)'), findsOneWidget);
    expect(find.text('Düzelt'), findsWidgets);
    expect(find.textContaining('Öğe artık yok'), findsOneWidget, reason: 'öğe başına hata');
    expect(find.text('Hedef tanımlı'), findsOneWidget);
    expect(find.text('Hedef ayarla'), findsOneWidget, reason: 'atlas için hedef yok');
    await golden('png/security_fix_sheet_light_tr.png');
    await tester.tap(find.textContaining('Claude\'a giden özet'));
    await _load(tester);
    expect(find.textContaining('TIPHYS BRIEF', findRichText: true), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('gönderme sayfası (koyu, EN) ve oturum başlatma: varsayılan kip default, not, origin', (tester) async {
    await fixHarness().pump(tester, route: '/security/orion?host=argo', dark: true, lang: 'en');
    _tall(tester, 2100);
    await _load(tester);
    await tester.tap(find.byTooltip('Select'));
    await _load(tester);
    await _tap(tester, find.text('SSH allows password login'));
    await _tap(tester, find.text('Send to Claude'));
    await golden('png/security_fix_sheet_dark_en.png');
    await tester.enterText(find.byType(TextField).last, '8080 is expected');
    await _tap(tester, find.text('Start session'));
    final s = FixAgent.fix.sent['session'] as Map;
    expect(s['kind'], 'security');
    expect(s['permissionMode'], 'default');
    expect(s['prompt'], '8080 is expected');
    expect((s['security'] as Map)['hosts'], ['orion', 'atlas']);
    expect(((s['security'] as Map)['origin'] as Map)['agentHostId'], 'argo');
    await _finish(tester);
  });

  testWidgets('investigate: yalnız plan kipi ve açıklama', (tester) async {
    FixAgent.fix.investigate = true;
    await _openSheet(tester);
    _tall(tester, 2100);
    await _load(tester);
    expect(_chips, findsOneWidget);
    expect(find.textContaining('saldırının izi'), findsOneWidget);
    expect(find.text('İncele'), findsWidgets);
    await _tap(tester, find.text('Oturumu başlat'));
    final s = FixAgent.fix.sent['session'] as Map;
    expect(s['permissionMode'], 'plan');
    expect((s['security'] as Map)['investigate'], true);
    await _finish(tester);
  });

  testWidgets('bypass: kırmızı uyarı, ikinci onay; vazgeçilirse oturum açılmaz', (tester) async {
    await _openSheet(tester);
    _tall(tester, 2300);
    await _load(tester);
    expect(_chips, findsNWidgets(4));
    await _tap(tester, find.descendant(of: find.byType(FixSendSheet), matching: find.widgetWithText(ChoiceChip, 'İzin sorma')));
    expect(find.textContaining('ağa erişen komutlar dahil'), findsWidgets);
    await golden('png/security_fix_bypass_light_tr.png');
    await _tap(tester, find.text('Oturumu başlat'));
    expect(find.text('Sormadan başlat'), findsOneWidget, reason: 'ikinci onay');
    expect(FixAgent.fix.sent.containsKey('session'), isFalse);
    await tester.tap(find.text('Vazgeç'));
    await _load(tester);
    expect(FixAgent.fix.sent.containsKey('session'), isFalse);
    await _tap(tester, find.text('Oturumu başlat'));
    await tester.tap(find.text('Sormadan başlat'));
    await _load(tester);
    expect((FixAgent.fix.sent['session'] as Map)['permissionMode'], 'bypassPermissions');
    await _finish(tester);
  });

  testWidgets('başlatma hatası: SSH adresi reddedildi (ProxyJump) → makine adıyla açıklama', (tester) async {
    FixAgent.fix.startError = const AgentError('agent.claude.securitySshConfig', {'host': 'orion', 'reason': 'ProxyJump'}, 400);
    await _openSheet(tester);
    _tall(tester, 2100);
    await _load(tester);
    await _tap(tester, find.text('Oturumu başlat'));
    expect(find.textContaining('“orion” makinesinin SSH adresi kullanılamıyor: ProxyJump'), findsOneWidget);
    expect(find.textContaining('olmadan doğrudan'), findsOneWidget);
    expect(find.textContaining('her adım'), findsOneWidget, reason: 'kip açıklaması: root adımları sorar');
    await _finish(tester);
  });

  testWidgets('hedef yok: başlat kapalı ve ipucu; özellik kapalıysa uyarı', (tester) async {
    FixAgent.fix.targets = [];
    await _openSheet(tester);
    _tall(tester, 2100);
    await _load(tester);
    expect(find.textContaining('düzeltme hedefi olan makinelerde'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Oturumu başlat')).onPressed, isNull);
    await _finish(tester);
  });

  testWidgets('brief 429: hız sınırı metni', (tester) async {
    FixAgent.fix.briefError = const AgentError('agent.security.briefRateLimited', {'limit': 10, 'windowSeconds': 600}, 429);
    await _openSheet(tester);
    _tall(tester, 1200);
    await _load(tester);
    expect(find.textContaining('en çok 10'), findsOneWidget);
    expect(find.text('Oturumu başlat'), findsNothing);
    await _finish(tester);
  });

  testWidgets('sohbet: sudo isteği parola penceresini açar; gönderilen parola istekte, sonra alan yok', (tester) async {
    await fixHarness().pump(tester, route: '/claude/session/sec1');
    _tall(tester, 1100);
    await _load(tester);
    expect(find.byType(SudoDialog), findsOneWidget);
    expect(find.text('orion için sudo parolası'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'hunter2');
    await tester.tap(find.text('Gönder'));
    await _load(tester);
    expect(FixAgent.fix.sent['sudo'], {'requestId': 'r1', 'password': 'hunter2'});
    expect(find.byType(SudoDialog), findsNothing);
    expect(find.text('hunter2'), findsNothing);
    await _finish(tester);
  });

  testWidgets('sohbet: sudo "sonra" → kart kalır; yanlış parola ipucu ve investigate uyarısı', (tester) async {
    FixAgent.fix.sudoAttempt = 2;
    FixAgent.fix.investigate = true;
    await fixHarness().pump(tester, route: '/claude/session/sec1');
    _tall(tester, 1100);
    await _load(tester);
    expect(find.textContaining('2. deneme'), findsOneWidget);
    expect(find.textContaining('ele geçirilmiş olabilir'), findsOneWidget);
    await golden('png/security_fix_sudo_light_tr.png');
    await tester.tap(find.text('Sonra'));
    await _load(tester);
    expect(find.text('Parolayı gir'), findsOneWidget);
    expect(find.text('İnceleme'), findsWidgets, reason: 'rozet');
    await _tap(tester, find.text('Parolayı gir'));
    expect(find.byType(SudoDialog), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('sohbet: okunur araç kartları, güvenlik rozeti ve panel (zamanlayıcı, yedekler, geri al)', (tester) async {
    FixAgent.fix.sudoPending = false;
    await fixHarness().pump(tester, route: '/claude/session/sec1');
    _tall(tester, 900);
    await _load(tester);
    expect(find.text('Güvenlik düzeltmesi'), findsWidgets);
    expect(find.text('Komut çalıştır'), findsOneWidget);
    expect(find.text('orion · sudo sshd -T | grep passwordauthentication'), findsOneWidget);
    expect(find.text('Dosya yaz'), findsOneWidget);
    await golden('png/security_fix_chat_light_tr.png');
    await tester.tap(find.byTooltip('Güvenlik oturumu'));
    await _load(tester);
    _tall(tester, 1500);
    await _load(tester);
    expect(find.text('Geri alma zamanlayıcıları'), findsOneWidget);
    expect(find.text('3:30'), findsOneWidget, reason: '14:05 → 14:08:30');
    expect(find.text('Değişen dosyalar (2)'), findsOneWidget);
    expect(find.text('Yedekler (2)'), findsOneWidget);
    expect(find.text('sudo parolası hatırlanıyor'), findsOneWidget);
    await golden('png/security_fix_panel_light_tr.png');
    await _tap(tester, find.widgetWithText(OutlinedButton, 'Geri al'));
    await tester.tap(find.widgetWithText(TextButton, 'Geri al'));
    await _load(tester);
    expect(FakeAgent.calls.any((c) => c.$1 == 'POST' && c.$2 == '/v1/claude/sessions/sec1/security/rollback' && (c.$3 as Map)['host'] == 'orion'), isTrue);
    await _finish(tester);
  });

  testWidgets('sohbet: root izin kartı — tehlike satırı, içerik önizlemesi; sudo iptali penceresini kapatır', (tester) async {
    FixAgent.fix.sudoPending = false;
    FixAgent.fix.rootPermission = true;
    await fixHarness().pump(tester, route: '/claude/session/sec1');
    _tall(tester, 1100);
    await _load(tester);
    expect(find.text('Root olarak çalışır'), findsOneWidget);
    expect(find.textContaining('yeni içeriğin önizlemesidir'), findsOneWidget);
    expect(find.text('+ PasswordAuthentication no'), findsWidgets);
    await golden('png/security_fix_root_permission_light_tr.png');
    await _finish(tester);
  });

  testWidgets('sohbet: oturum bitince "Yeniden denetle" → denetim isteği, ardından makineyi aç', (tester) async {
    FixAgent.fix.sudoPending = false;
    FixAgent.fix.sessionDone = true;
    await fixHarness().pump(tester, route: '/claude/session/sec1');
    _tall(tester, 1100);
    await _load(tester);
    expect(find.text('Sonucu doğrula'), findsOneWidget);
    await golden('png/security_fix_audit_light_tr.png');
    await _tap(tester, find.text('Yeniden denetle'));
    expect(FakeAgent.calls.any((c) => c.$1 == 'POST' && c.$2 == '/v1/security/hosts/orion/check'), isTrue);
    expect(find.text('orion makinesini aç'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('hedef düzenleyici: geçersiz SSH adresi kaydı engeller; geçerli olan PUT edilir', (tester) async {
    await fixHarness().pump(tester, route: '/claude/security-targets?host=argo');
    _tall(tester, 1100);
    await _load(tester);
    expect(find.text('orion'), findsWidgets);
    await golden('png/security_fix_targets_light_tr.png');
    await _tap(tester, find.text('Hedef ekle'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Makine kimliği'), 'atlas');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ad'), 'atlas');
    await tester.enterText(find.widgetWithText(TextFormField, 'SSH adresi'), 'bad host');
    await _tap(tester, find.text('Kaydet').last);
    expect(find.textContaining('kullanıcı@makine biçimini'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'SSH adresi'), 'tiphys@atlas.example.org');
    await tester.enterText(find.widgetWithText(TextFormField, 'Port (isteğe bağlı)'), '2222');
    await _tap(tester, find.text('Kaydet').last);
    await _tap(tester, find.text('Kaydet').first);
    final put = FixAgent.fix.sent['targets'] as Map;
    expect((put['targets'] as List).last, {'host': 'atlas', 'name': 'atlas', 'ssh': 'tiphys@atlas.example.org', 'port': 2222});
    expect(put['sudoCacheMinutes'], 15);
    await _finish(tester);
  });

  testWidgets('ayarlar: özellik anahtarı ve hedefler satırı', (tester) async {
    await fixHarness().pump(tester, route: '/settings/hosts/agent?id=argo');
    _tall(tester, 1900);
    await _load(tester);
    expect(find.text('Güvenlik düzeltmeleri (Claude, SSH ile)'), findsOneWidget);
    expect(find.text('Düzeltme hedefleri'), findsOneWidget);
    await _finish(tester);
  });
}
