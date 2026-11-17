// Database console (PLAN.md §13.2): connections + discovery, the connection form with the superuser warning, schema,
// editor results with the truncated banner, a saved query bar chart, the write mode (lock, preview sheet, countChanged),
// CSV share and the restore tests. Widget tests use 375 px width.
// To update: flutter test test/goldens/databases_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/vault/sensitive_clipboard.dart';
import 'package:tiphys/features/databases/db_data.dart';
import 'package:tiphys/features/vault/vault_state.dart';
import 'package:tiphys/widgets/surfaces.dart' show SectionLabel;

import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/databases/db_restore_data.dart';

import '../helpers/harness.dart';

const _conn = '/db/conn?host=argo&id=shop-db';

class _Native implements SensitiveClipboardNative {
  final copied = <String>[];
  @override
  Future<void> setSensitive(String text, String label) async => copied.add(text);
  @override
  Future<bool> clearIfLabel(String label) async => true;
}

class _Env {
  _Env({this.lock = true}) {
    dir = Directory.systemTemp.createTempSync('tiphys-dbtest');
  }
  final bool lock;
  late final Directory dir;
  int auths = 0;
  final shared = <String>[];
  final sharedNames = <String>[];
  final secure = <bool>[];
  final native = _Native();
  bool shareOk = true;

  Harness get h => Harness(agentFeatures: [...Harness.defaultAgentFeatures, 'databases'], extra: [
        dbWriteLockAvailableProvider.overrideWith((ref) async => lock),
        vaultAuthProvider.overrideWithValue((c) async {
          auths++;
          return true;
        }),
        dbCacheDirProvider.overrideWithValue(() async => dir),
        secureWindowProvider.overrideWithValue((on) async => secure.add(on)),
        sensitiveClipboardProvider.overrideWithValue(SensitiveClipboard(native)),
        dbShareProvider.overrideWithValue((f) async {
          shared.add(base64.encode(f.readAsBytesSync()));
          sharedNames.add(f.uri.pathSegments.last);
          // What share_plus does: it keeps its own copy in the cache.
          Directory('${dir.path}/share_plus').createSync(recursive: true);
          f.copySync('${dir.path}/share_plus/${f.uri.pathSegments.last}');
          return shareOk;
        }),
      ]);
}

void _tall(WidgetTester tester, [double height = 1500]) => tester.view.physicalSize = Size(375 * 2, height * 2);

/// Lets real async work (file IO) finish, then pumps.
Future<void> _load(WidgetTester tester) async {
  // Each round lets real file IO finish, then runs the continuation (the CSV flow awaits real IO several times).
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
  debugDisableShadows = true;
}

Future<void> _tapText(WidgetTester tester, String text, {bool last = false}) async {
  final f = find.text(text);
  final target = last ? f.last : f.first;
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _load(tester);
}

Future<void> _openEditor(WidgetTester tester, {String tab = 'Düzenleyici', String? sql}) async {
  await _tapText(tester, tab);
  if (sql != null) {
    await tester.enterText(find.byType(TextField).first, sql);
    await tester.pump();
  }
}

/// Turns the write mode on in the editor tab.
Future<void> _writeOn(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(SwitchListTile).first);
  await tester.pump();
  await tester.tap(find.byType(SwitchListTile).first);
  await _load(tester);
}

void main() {
  setUp(() {
    FakeAgent.resetDb();
    FakeAgent.calls.clear();
  });

  testWidgets('bağlantılar açık TR: motor/hedef, süper kullanıcı rozeti, SQLite satırı', (tester) async {
    await _Env().h.pump(tester, route: '/db');
    _tall(tester);
    await _load(tester);
    expect(find.text('Shop (PostgreSQL)'), findsOneWidget);
    expect(find.text('PostgreSQL · argo-shop-db · shop'), findsOneWidget);
    expect(find.text('süper kullanıcı'), findsOneWidget);
    expect(find.text('SQLite · /srv/notes/notes.sqlite'), findsOneWidget);
    expect(find.text('Keşfet'), findsWidgets);
    expect(find.textContaining('app_ro'), findsNothing, reason: 'kimlik bilgisi listede görünmez');
    await golden('png/db_connections_light_tr.png');
    await _finish(tester);
  });

  testWidgets('özellik yoksa sistem ekranında Veritabanları satırı yok, varsa var', (tester) async {
    await Harness().pump(tester, route: '/system');
    await _load(tester);
    await tester.scrollUntilVisible(find.text('Yedekler'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Veritabanları'), findsNothing);
    await _finish(tester);
    await _Env().h.pump(tester, route: '/system');
    await _load(tester);
    await tester.scrollUntilVisible(find.text('Veritabanları'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Veritabanları'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('keşif açık TR: konteynerler, Redis desteklenmiyor, var olan bağlantı', (tester) async {
    await _Env().h.pump(tester, route: '/db/discover?host=argo');
    _tall(tester, 900);
    await _load(tester);
    expect(find.text('argo-shop-db'), findsOneWidget);
    expect(find.textContaining('1 bağlantı var'), findsWidgets);
    expect(find.textContaining('desteklenmiyor'), findsOneWidget);
    expect(find.textContaining('POSTGRES_PASSWORD'), findsNothing, reason: 'ortam değişkeni adları da listede gösterilmez');
    await golden('png/db_discover_light_tr.png');
    await _finish(tester);
  });

  testWidgets('keşif → form: süper kullanıcı uyarısı TR; kaydedince şifresiz fromContainerEnv gönderilir', (tester) async {
    await _Env().h.pump(tester, route: '/db/discover?host=argo');
    _tall(tester, 1400);
    await _load(tester);
    await _tapText(tester, 'argo-blog-db');
    expect(find.text('Yeni bağlantı'), findsOneWidget);
    expect(find.text('Ayrı kullanıcı + şifre (önerilen)'), findsOneWidget);
    expect(find.text('Süper kullanıcı uyarısı'), findsNothing);
    await _tapText(tester, 'Konteyner ortamından (süper kullanıcı)');
    expect(find.text('Süper kullanıcı uyarısı'), findsOneWidget);
    expect(find.textContaining('yalnız işlem düzeyindeki korumalar'), findsOneWidget);
    await golden('png/db_superuser_warning_tr.png');
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    final post = FakeAgent.calls.firstWhere((c) => c.$1 == 'POST' && c.$2 == '/v1/db/connections').$3 as Map;
    expect(post['readCredential'], {'fromContainerEnv': true});
    expect(post['engine'], 'postgres');
    expect(post['target'], {'container': 'argo-blog-db', 'network': 'blog_default'});
    expect(post.containsKey('writeCredential'), isFalse);
    expect(FakeAgent.db.connections.last['warnings'], ['superuserCredential']);
    await _finish(tester);
  });

  testWidgets('elle ekle: şifre alanı zorunlu; şifre bağlantı yanıtında/listede yok', (tester) async {
    await _Env().h.pump(tester, route: '/db');
    _tall(tester, 1500);
    await _load(tester);
    await _tapText(tester, 'Elle ekle');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ad'), 'Blog');
    await tester.enterText(find.widgetWithText(TextFormField, 'Konteyner adı'), 'argo-blog-db');
    await tester.enterText(find.widgetWithText(TextFormField, 'Kullanıcı'), 'blog_ro');
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    expect(find.text('Zorunlu'), findsOneWidget, reason: 'şifre boş');
    expect(FakeAgent.calls.where((c) => c.$1 == 'POST'), isEmpty);
    await tester.enterText(find.widgetWithText(TextFormField, 'Şifre'), 'EXAMPLE-NOT-A-REAL-PASSWORD');
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    expect(find.text('Blog'), findsOneWidget);
    expect(find.textContaining('EXAMPLE-NOT-A-REAL-PASSWORD'), findsNothing);
    expect(FakeAgent.db.connections.last['readCredential'], {'mode': 'password', 'user': 'blog_ro', 'hasPassword': true});
    await _finish(tester);
  });

  testWidgets('düzenle: kayıtlı şifre korunur (şifre gönderilmez); hedef değişince passwordRequired metni', (tester) async {
    await _Env().h.pump(tester, route: '/db');
    _tall(tester, 1500);
    await _load(tester);
    await tester.tap(find.byTooltip('Bağlantı menüsü').first);
    await settle(tester);
    await tester.tap(find.text('Düzenle'));
    await _load(tester);
    expect(find.text('Bağlantıyı düzenle'), findsOneWidget);
    expect(find.text('Kayıtlı şifre korunur; değiştirmek için yeni şifre yazın.'), findsWidgets);
    await tester.enterText(find.widgetWithText(TextFormField, 'Konteyner adı'), 'argo-other-db');
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    final patch = FakeAgent.calls.firstWhere((c) => c.$1 == 'PATCH').$3 as Map;
    expect((patch['readCredential'] as Map).containsKey('password'), isFalse);
    expect(find.textContaining('yeni adrese gönderilmez'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('şema koyu EN: şemalar → tablolar, tahmini satır; tablo sayfası sütun/indeks/önizleme', (tester) async {
    await _Env().h.pump(tester, route: _conn, dark: true, lang: 'en');
    _tall(tester, 1100);
    await _load(tester);
    expect(find.text('public'), findsOneWidget);
    expect(find.text('Table · ~12840 rows'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
    await golden('png/db_schema_dark_en.png');
    await _tapText(tester, 'orders');
    expect(find.text('COLUMNS'), findsOneWidget);
    expect(find.text('int4 · PK · NOT NULL'), findsOneWidget);
    expect(find.text('orders_customer_idx'), findsOneWidget);
    await _tapText(tester, 'Show the first 100 rows');
    expect(find.text('customer-1@example.org'), findsOneWidget);
    expect(FakeAgent.calls.any((c) => c.$2 == '/v1/db/connections/shop-db/tables/public/orders/preview'), isTrue);
    await _finish(tester);
  });

  testWidgets('düzenleyici TR: sonuç tablosu, kesik banner\'ı, sayfalama, hücre sayfası', (tester) async {
    await _Env().h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'SELECT * FROM orders');
    await _tapText(tester, 'Çalıştır');
    expect(find.text('60 satır · 14 ms'), findsOneWidget);
    expect(find.textContaining('Sonuç 60 satırda kesildi'), findsOneWidget);
    expect(find.text('Sayfa 1/2'), findsOneWidget);
    expect(find.text('customer-1@example.org'), findsOneWidget);
    expect(find.text('customer-51@example.org'), findsNothing);
    await golden('png/db_editor_results_truncated_tr.png');
    await tester.tap(find.byTooltip('Sonraki sayfa'));
    await settle(tester);
    expect(find.text('Sayfa 2/2'), findsOneWidget);
    expect(find.text('customer-51@example.org'), findsOneWidget);
    expect(find.text('customer-1@example.org'), findsNothing);
    await tester.tap(find.text('customer-51@example.org'));
    await settle(tester);
    expect(find.text('Hücre'), findsOneWidget);
    expect(find.text('Kopyala'), findsOneWidget);
    final q = FakeAgent.calls.firstWhere((c) => c.$2 == '/v1/db/connections/shop-db/query').$3 as Map;
    expect(q['limit'], 500);
    expect(q['timeoutMs'], 15000);
    await _finish(tester);
  });

  testWidgets('düzenleyici: yasak ifade hatası Türkçe; sınır ve zaman aşımı sınırlanır', (tester) async {
    FakeAgent.db.queryError = const AgentError('agent.db.statementNotAllowed', {'keyword': 'copy'}, 400);
    await _Env().h.pump(tester, route: _conn);
    _tall(tester, 1300);
    await _load(tester);
    await _openEditor(tester, sql: 'COPY t TO PROGRAM \'x\'');
    await tester.enterText(find.widgetWithText(TextField, 'Satır sınırı'), '99999');
    await tester.enterText(find.widgetWithText(TextField, 'Zaman aşımı (sn)'), '500');
    await _tapText(tester, 'Çalıştır');
    expect(find.textContaining('Bu ifade türüne izin verilmiyor (copy)'), findsOneWidget);
    final q = FakeAgent.calls.firstWhere((c) => c.$2 == '/v1/db/connections/shop-db/query').$3 as Map;
    expect(q['limit'], 5000);
    expect(q['timeoutMs'], 60000);
    await _finish(tester);
  });

  testWidgets('CSV paylaş: geçici dosyaya akar, paylaşılır, dosya silinir, satır sayısı gösterilir', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'SELECT * FROM orders');
    await _tapText(tester, 'Çalıştır');
    await _tapText(tester, 'CSV paylaş');
    await _load(tester);
    expect(env.shared.single, base64.encode(utf8.encode(FakeAgent.db.csv)));
    expect(env.sharedNames.single, matches(r'^shop-db-20261114-1405\.csv$'));
    expect(env.dir.listSync(), isEmpty, reason: 'paylaşımdan sonra dosya silinir');
    expect(find.text('3 satır dışa aktarıldı.'), findsOneWidget, reason: 'satır sayısı akıştan sayıldı (header yok)');
    final c = FakeAgent.calls.lastWhere((c) => c.$1 == 'POST' && c.$2.endsWith('/export'));
    expect((c.$3 as Map)['sql'], 'SELECT * FROM orders');
    await _finish(tester);
  });

  testWidgets('CSV: iz başlığı varsa 100 000 satır = kesik olabilir uyarısı; hata Türkçe', (tester) async {
    final env = _Env();
    FakeAgent.db.csvHeaders = {'x-tiphys-rows': '100000', 'x-tiphys-truncated': 'true'};
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'SELECT 1');
    await _tapText(tester, 'Çalıştır');
    await _tapText(tester, 'CSV paylaş');
    await _load(tester);
    expect(find.textContaining('satır dışa aktarıldı'), findsOneWidget);
    expect(find.textContaining('dosya kesik olabilir'), findsOneWidget);
    await _finish(tester);
    FakeAgent.resetDb();
    FakeAgent.db.exportError = const AgentError('agent.db.exportRateLimited', {'perMinute': 3}, 429);
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'SELECT 1');
    await _tapText(tester, 'Çalıştır');
    await _tapText(tester, 'CSV paylaş');
    await _load(tester);
    expect(find.textContaining('dakikada en çok 3'), findsOneWidget);
    expect(env.shared, hasLength(1), reason: 'hatada paylaşım açılmaz');
    await _finish(tester);
  });

  testWidgets('kayıtlı sorgu çubuk grafiği EN: grafik türüne göre çizilir', (tester) async {
    await _Env().h.pump(tester, route: _conn, lang: 'en');
    _tall(tester, 1300);
    await _load(tester);
    await _tapText(tester, 'Queries');
    expect(find.text('Daily orders'), findsOneWidget);
    await _tapText(tester, 'Daily orders');
    expect(find.text('Chart: Bar'), findsOneWidget);
    expect(find.text('7 rows · 8 ms'), findsOneWidget);
    await golden('png/db_saved_query_bar_en.png');
    await _finish(tester);
  });

  testWidgets('kayıtlı sorgu: sayı ve çizgi türleri; sütun yoksa tabloya düşer ve nedenini söyler', (tester) async {
    await _Env().h.pump(tester, route: _conn, lang: 'en');
    _tall(tester, 1300);
    await _load(tester);
    await _tapText(tester, 'Queries');
    await _tapText(tester, 'Customers');
    expect(find.text('912'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await _load(tester);
    FakeAgent.db.queries[1]['chart'] = {'type': 'line', 'x': 'gone', 'y': ['revenue']};
    await _tapText(tester, 'Monthly revenue');
    expect(find.textContaining('chart\'s columns are not in the result'), findsOneWidget);
    expect(find.text('2026-01'), findsOneWidget, reason: 'tablo gösterilir');
    await _finish(tester);
  });

  testWidgets('sorgu formu: sütun seçicileri sorgunun döndürdüğü sütunlardan (y yalnız sayısal); kaydet PATCH', (tester) async {
    await _Env().h.pump(tester, route: _conn, lang: 'en');
    _tall(tester, 1500);
    await _load(tester);
    await _tapText(tester, 'Queries');
    await _tapText(tester, 'New query');
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Orders by customer');
    await tester.enterText(find.widgetWithText(TextField, 'SQL (read-only)'), 'SELECT id, customer, total, created_at FROM orders');
    await tester.pump();
    await _tapText(tester, 'Bar');
    // The query ran to learn its columns; numeric ones (id, total) are the y choices, with a suggested config.
    expect(find.widgetWithText(FilterChip, 'total'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'id'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'customer'), findsNothing);
    expect(find.widgetWithText(FilterChip, 'created_at'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'id'));
    await settle(tester);
    await _tapText(tester, 'Save', last: true);
    final post = FakeAgent.calls.firstWhere((c) => c.$1 == 'POST' && c.$2 == '/v1/db/queries').$3 as Map;
    expect(post['connectionId'], 'shop-db');
    expect((post['chart'] as Map)['type'], 'bar');
    expect((post['chart'] as Map)['x'], 'customer');
    expect((post['chart'] as Map)['y'], ['total']);
    expect(find.text('Orders by customer'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('yazma kipi: her açışta uygulama kilidi; kilit yoksa açılmaz; kapalıyken çerçeve/banner yok', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester);
    expect(find.textContaining('YAZMA KİPİ AÇIK'), findsNothing);
    expect(find.text('Önizle'), findsNothing);
    await _writeOn(tester);
    expect(env.auths, 1);
    expect(find.textContaining('YAZMA KİPİ AÇIK'), findsOneWidget);
    expect(find.text('Önizle'), findsOneWidget);
    await _writeOn(tester);
    expect(find.textContaining('YAZMA KİPİ AÇIK'), findsNothing);
    await _writeOn(tester);
    expect(env.auths, 2, reason: 'her açışta yeniden');
    await _finish(tester);

    final noLock = _Env(lock: false);
    await noLock.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester);
    await _writeOn(tester);
    expect(noLock.auths, 0);
    expect(find.textContaining('uygulama kilidi (PIN ya da parmak izi) ayarlayın'), findsOneWidget);
    expect(find.textContaining('YAZMA KİPİ AÇIK'), findsNothing);
    await _finish(tester);
  });

  testWidgets('SQLite bağlantısında yazma kipi yok', (tester) async {
    await _Env().h.pump(tester, route: '/db/conn?host=argo&id=notes-lite');
    _tall(tester, 1300);
    await _load(tester);
    await _openEditor(tester);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('SQLite bağlantılarında yazma kipi yok.'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('yazma önizleme sayfası TR: etkilenen satır, örnek satırlar, uyarılar, geri sayım; onay → commit', (tester) async {
    final env = _Env();
    FakeAgent.db.connections[0]['writeCredential'] = null;
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'UPDATE orders SET status = 1 WHERE id < 4');
    await _writeOn(tester);
    await _tapText(tester, 'Önizle');
    expect(find.text('Yazma önizlemesi'), findsOneWidget);
    expect(find.text('3 satır etkilenecek'), findsOneWidget);
    expect(find.textContaining('Ayrı yazma kimliği tanımlı değil'), findsOneWidget);
    expect(find.text('ÖRNEK SATIRLAR (İLK 3)'), findsOneWidget);
    expect(find.textContaining('Geçerlilik: 1:5'), findsOneWidget);
    expect(find.textContaining('Önizleme geri alındı'), findsOneWidget);
    await golden('png/db_write_preview_tr.png');
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula'));
    await settle(tester);
    expect(find.textContaining('veritabanını kalıcı olarak değiştirecek'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await _load(tester);
    expect(find.text('Uygulandı: 3 satır değişti.'), findsOneWidget);
    expect(FakeAgent.db.writeCalls, ['preview:UPDATE orders SET status = 1 WHERE id < 4', 'commit:tok-1']);
    await tester.tap(find.widgetWithText(TextButton, 'Kapat'));
    await _load(tester);
    expect(find.text('Değişiklik uygulandı.'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('yazma: commit countChanged → açıklama, hiçbir şey uygulanmadı, yeniden önizle yeni belirteç', (tester) async {
    FakeAgent.db.commitActual = 4;
    await _Env().h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'DELETE FROM orders WHERE id < 4');
    await _writeOn(tester);
    await _tapText(tester, 'Önizle');
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula'));
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await _load(tester);
    expect(find.textContaining('3 satır beklenirken ifade şimdi 4 satırı etkiliyor'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Uygula'), findsNothing);
    FakeAgent.db.writeCount = 4;
    await tester.tap(find.text('Yeniden önizle'));
    await _load(tester);
    expect(find.text('4 satır etkilenecek'), findsOneWidget);
    expect(FakeAgent.db.writeCalls.where((c) => c.startsWith('preview')).length, 2);
    await _finish(tester);
  });

  testWidgets('yazma: önizleme belirtecinin süresi dolunca Uygula kapanır, yenile yeni önizleme verir', (tester) async {
    var now = DateTime(2026, 11, 14, 14, 5);
    final h = Harness(agentFeatures: [...Harness.defaultAgentFeatures, 'databases'], clock: () => now, extra: [
      dbWriteLockAvailableProvider.overrideWith((ref) async => true),
      vaultAuthProvider.overrideWithValue((c) async => true),
    ]);
    FakeAgent.db.previewTtl = const Duration(seconds: 30);
    await h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'UPDATE orders SET status = 1');
    await _writeOn(tester);
    await _tapText(tester, 'Önizle');
    expect(find.widgetWithText(FilledButton, 'Uygula'), findsOneWidget);
    expect(find.textContaining('Geçerlilik: 0:30'), findsOneWidget);
    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Önizlemenin süresi doldu.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Uygula'), findsNothing);
    await tester.tap(find.text('Önizlemeyi yenile'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(FakeAgent.db.writeCalls.where((c) => c.startsWith('preview')).length, 2);
    expect(FakeAgent.db.writeCalls.any((c) => c.startsWith('commit')), isFalse, reason: 'süresi dolan belirteç gönderilmedi');
    await _finish(tester);
  });

  testWidgets('salt okunur rol yardımcısı (PG): SQL gösterilir, kopyalanır; yazma kipinde çalıştır editörü doldurur', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1700);
    await _load(tester);
    await _openEditor(tester);
    await _tapText(tester, 'SQL\'i hazırla');
    expect(find.textContaining('CREATE ROLE "tiphys_ro"'), findsOneWidget);
    expect(find.textContaining('yalnız burada görünür'), findsOneWidget);
    await _tapText(tester, 'Yazma kipinde çalıştır');
    expect(env.auths, 1);
    expect(find.textContaining('YAZMA KİPİ AÇIK'), findsOneWidget);
    expect(find.textContaining('IN ROLE pg_read_all_data;'), findsWidgets);
    await _finish(tester);
  });

  testWidgets('salt okunur rol yardımcısı (MariaDB): yalnız kopyala, istemciyle çalıştır notu; yazma kipinde çalıştır yok', (tester) async {
    await _Env().h.pump(tester, route: '/db/conn?host=argo&id=analytics');
    _tall(tester, 1700);
    await _load(tester);
    await _openEditor(tester);
    await _tapText(tester, 'SQL\'i hazırla');
    expect(find.textContaining('mysql/mariadb istemcisiyle çalıştırın'), findsOneWidget);
    expect(find.text('Yazma kipinde çalıştır'), findsNothing);
    expect(find.text('Kopyala'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('MariaDB DDL: önizlenemez hatası Türkçe', (tester) async {
    await _Env().h.pump(tester, route: '/db/conn?host=argo&id=analytics');
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'CREATE TABLE x (a int)');
    await _writeOn(tester);
    await _tapText(tester, 'Önizle');
    expect(find.textContaining('kendiliğinden kaydedilir; önizlenemez'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Uygula'), findsNothing);
    await _finish(tester);
  });

  // ---- restore tests ------------------------------------------------------------------------------------------------

  testWidgets('geri yükleme testleri TR: durum, son çalışma, sonraki çalışma, başarısızlık nedeni', (tester) async {
    await _Env().h.pump(tester, route: '/db/restore?host=argo');
    _tall(tester, 1300);
    await _load(tester);
    expect(find.text('Shop nightly'), findsOneWidget);
    expect(find.textContaining('Geçti'), findsOneWidget);
    expect(find.textContaining('Başarısız'), findsOneWidget);
    expect(find.textContaining('Döküm yüklenirken hata oluştu. (ERROR 1064 (42000) at line 12)'), findsOneWidget);
    expect(find.textContaining('Her gün 03:30'), findsOneWidget);
    expect(find.textContaining('sonraki:'), findsOneWidget);
    expect(find.text('Yalnız elle çalıştırılır'), findsOneWidget);
    await golden('png/db_restore_tests_light_tr.png');
    await _finish(tester);
  });

  testWidgets('geri yükleme testi: şimdi çalıştır → çalışıyor (yoklama) → bitince sonuç; aynı anda tek test', (tester) async {
    await _Env().h.pump(tester, route: '/db/restore?host=argo');
    _tall(tester, 1300);
    await _load(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Şimdi çalıştır').last);
    await settle(tester);
    expect(find.text('Çalışıyor'), findsOneWidget);
    expect(find.textContaining('Geçici konteynerde yükleniyor'), findsOneWidget);
    for (final b in tester.widgetList<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Şimdi çalıştır'))) {
      expect(b.onPressed, isNull, reason: 'çalışırken başka test başlatılamaz');
    }
    for (var i = 0; i < 4; i++) {
      await tester.pump(restorePollInterval);
      await settle(tester);
    }
    expect(find.text('Çalışıyor'), findsNothing);
    expect(FakeAgent.db.runs, 1);
    expect(FakeAgent.db.results['analytics-weekly']!.first['ok'], isTrue);
    expect(find.textContaining('Geçti'), findsNWidgets(2), reason: 'çalıştırılan test de geçti');
    expect(find.textContaining('Başarısız'), findsNothing);
    await _finish(tester);
  });

  testWidgets('sonuç geçmişi EN: neden, beklenti farkı, döküm dosyası ve süre', (tester) async {
    await _Env().h.pump(tester, route: '/db/restore?host=argo', lang: 'en');
    _tall(tester, 1300);
    await _load(tester);
    await _tapText(tester, 'Shop nightly');
    expect(find.text('Results history'), findsOneWidget);
    expect(find.text('The sanity queries did not pass.'), findsOneWidget);
    expect(find.textContaining('#1: expectation not met (got 0, expected > 0)'), findsOneWidget);
    expect(find.textContaining('shop-20261113.sql.gz'), findsWidgets);
    expect(find.textContaining('236 s'), findsWidgets);
    await golden('png/db_restore_results_en.png');
    await _finish(tester);
  });

  testWidgets('bildirimden gelen bağlantı: ilgili test vurgulanır', (tester) async {
    await _Env().h.pump(tester, route: '/db/restore?host=argo&test=Analytics+weekly');
    _tall(tester, 1300);
    await _load(tester);
    expect(find.text('Analytics weekly'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('geri yükleme formu: açık etiketli imaj şart, custom yalnız PG, sanity + zamanlama gövdeye girer', (tester) async {
    await _Env().h.pump(tester, route: '/db/restore?host=argo');
    _tall(tester, 2200);
    await _load(tester);
    await _tapText(tester, 'Test ekle');
    expect(find.text('Yeni geri yükleme testi'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Ad'), 'Blog nightly');
    await tester.enterText(find.widgetWithText(TextFormField, 'İmaj (açık etiketli)'), 'postgres:latest');
    await tester.enterText(find.widgetWithText(TextFormField, 'Döküm deseni'), '~/backups/blog/*.sql.gz');
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    expect(find.textContaining('açık etiketli bir imaj yazın'), findsOneWidget);
    expect(FakeAgent.calls.where((c) => c.$1 == 'POST' && c.$2 == '/v1/db/restore-tests'), isEmpty);
    await tester.enterText(find.widgetWithText(TextFormField, 'İmaj (açık etiketli)'), 'postgres:16');
    await _tapText(tester, 'Sorgu ekle');
    await tester.enterText(find.widgetWithText(TextFormField, 'SQL'), 'SELECT count(*) FROM posts');
    await tester.enterText(find.widgetWithText(TextFormField, 'Değer'), '5');
    await _tapText(tester, 'Otomatik çalıştır');
    expect(find.text('Zamanlama etkin'), findsOneWidget);
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    final post = FakeAgent.calls.firstWhere((c) => c.$1 == 'POST' && c.$2 == '/v1/db/restore-tests').$3 as Map;
    expect(post['id'], 'blog-nightly');
    expect(post['image'], 'postgres:16');
    expect(post['engine'], 'postgres');
    expect(post['format'], 'gz');
    expect(post['sanity'], [{'sql': 'SELECT count(*) FROM posts', 'expect': {'op': '>', 'value': 5}}]);
    expect((post['schedule'] as Map)['kind'], 'daily');
    expect(find.text('Blog nightly'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('geri yükleme testi sil: onay; çalışırken silinemez menüde', (tester) async {
    await _Env().h.pump(tester, route: '/db/restore?host=argo');
    _tall(tester, 1300);
    await _load(tester);
    await tester.tap(find.byTooltip('Bağlantı menüsü').last);
    await settle(tester);
    await tester.tap(find.text('Sil'));
    await settle(tester);
    expect(find.textContaining('«Analytics weekly» testi ve sonuçları silinsin mi?'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await _load(tester);
    expect(find.text('Analytics weekly'), findsNothing);
    expect(FakeAgent.db.restoreTests.length, 1);
    await _finish(tester);
  });

  // --- §13 review fixes ----------------------------------------------------------------------------------------------

  testWidgets('CSV: paylaşım bitmezse share_plus kopyası kalır; bağlantı ekranından çıkınca db-export ve share_plus silinir', (tester) async {
    final env = _Env()..shareOk = false;
    // A leftover of an export killed half way.
    Directory('${env.dir.path}/db-export').createSync(recursive: true);
    File('${env.dir.path}/db-export/old.csv').writeAsStringSync('id\n1\n');
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'SELECT * FROM orders');
    await _tapText(tester, 'Çalıştır');
    await _tapText(tester, 'CSV paylaş');
    await _load(tester);
    expect(env.shared, hasLength(1));
    expect(Directory('${env.dir.path}/share_plus').listSync(), hasLength(1), reason: 'paylaşım onaylanmadı: kopya şimdilik kalır');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(env.dir.listSync(), isEmpty, reason: 'ekrandan çıkınca bütün CSV kopyaları silinir');
    await _finish(tester);
  });

  test('clearCsvCopies yalnız db-export ve share_plus klasörlerini siler', () async {
    final dir = Directory.systemTemp.createTempSync('tiphys-cache');
    for (final d in ['db-export', 'share_plus', 'other']) {
      File('${dir.path}/$d/x.csv').createSync(recursive: true);
    }
    await clearCsvCopies(dir);
    expect(dir.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last), ['other']);
    await clearCsvCopies(Directory('${dir.path}/missing'));
    dir.deleteSync(recursive: true);
  });

  testWidgets('CSV: sonucu üreten SQL dışa aktarılır, düzenleyicide sonra yazılan değil', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'SELECT * FROM orders');
    await _tapText(tester, 'Çalıştır');
    await tester.enterText(find.byType(TextField).first, 'SELECT * FROM customers');
    await tester.pump();
    await _tapText(tester, 'CSV paylaş');
    await _load(tester);
    expect(FakeAgent.db.exports.last, 'SELECT * FROM orders');
    await _finish(tester);
  });

  testWidgets('sonuçlar ve hücre sayfası FLAG_SECURE altında; hücre kopyası hassas panoya, seçilebilir metin yok', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'SELECT * FROM orders');
    expect(env.secure, isEmpty);
    await _tapText(tester, 'Çalıştır');
    expect(env.secure, [true]);
    await tester.tap(find.byType(InkWell).at(find.byType(InkWell).evaluate().length ~/ 2));
    await settle(tester);
    expect(find.text('Hücre'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Kopyala'));
    await settle(tester);
    expect(env.native.copied, hasLength(1));
    await tester.tap(find.text('Kapat').last);
    await settle(tester);
    expect(env.secure, [true], reason: 'tablo hâlâ ekranda');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(env.secure, [true, false]);
    await _finish(tester);
  });

  testWidgets('bağlantı formu FLAG_SECURE altında; argümansız /db/form listeye düşer', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: '/db/form');
    await _load(tester);
    expect(find.text('Veritabanları'), findsOneWidget, reason: 'extra yoksa çökmez, liste açılır');
    await _finish(tester);
    await env.h.pump(tester, route: '/db/discover?host=argo');
    _tall(tester, 1400);
    await _load(tester);
    await _tapText(tester, 'argo-blog-db');
    expect(env.secure.last, isTrue);
    await _finish(tester);
  });

  testWidgets('yazma: commit yanıtı gelmezse "Sonuç bilinmiyor", yeniden önizleme yok, okuma sorgusuyla kontrol', (tester) async {
    final env = _Env();
    FakeAgent.db.commitError = const AgentError('net.timeout');
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1700);
    await _load(tester);
    await _openEditor(tester, sql: 'UPDATE orders SET status = 1 WHERE id < 4');
    await tester.enterText(find.widgetWithText(TextField, 'Zaman aşımı (sn)'), '40');
    await _writeOn(tester);
    await _tapText(tester, 'Önizle');
    final preview = FakeAgent.calls.lastWhere((c) => c.$2.endsWith('/write/preview')).$3 as Map;
    expect(preview['timeoutMs'], 40000, reason: 'önizleme düzenleyicinin zaman aşımıyla');
    expect(tester.widget<BottomSheet>(find.byType(BottomSheet)).enableDrag, isFalse);
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula'));
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await _load(tester);
    expect(find.text('Sonuç bilinmiyor'), findsOneWidget);
    expect(find.textContaining('uygulanmış olabilir'), findsOneWidget);
    expect(find.text('Yeniden önizle'), findsNothing);
    expect(find.text('Önizlemeyi yenile'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Uygula'), findsNothing);
    await tester.enterText(find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField)), 'SELECT count(*) FROM orders WHERE status = 1');
    await tester.pump();
    await _tapText(tester, 'Satır sayısını kontrol et');
    final check = FakeAgent.calls.lastWhere((c) => c.$2.endsWith('/query')).$3 as Map;
    expect(check['sql'], 'SELECT count(*) FROM orders WHERE status = 1');
    expect(find.textContaining('60 satır'), findsWidgets);
    expect(FakeAgent.db.writeCalls.where((c) => c.startsWith('commit')).length, 1, reason: 'ikinci commit yok');
    await golden('png/db_commit_unknown_tr.png');
    await _finish(tester);
  });

  testWidgets('yazma: commit sonrası sayfa dışına dokunarak kapatılsa da uygulandı sayılır', (tester) async {
    await _Env().h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'UPDATE orders SET status = 1 WHERE id < 4');
    await _writeOn(tester);
    await _tapText(tester, 'Önizle');
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula'));
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await _load(tester);
    expect(find.text('Uygulandı: 3 satır değişti.'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await _load(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Değişiklik uygulandı.'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('yazma: onay düğmesine iki kez dokunmak tek onay penceresi açar', (tester) async {
    await _Env().h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester, sql: 'UPDATE orders SET status = 1 WHERE id < 4');
    await _writeOn(tester);
    await _tapText(tester, 'Önizle');
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula'));
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula'), warnIfMissed: false);
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('yazma kipi uygulama arka plana gidince kapanır; yeniden açmak kilidi yine sorar', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1500);
    await _load(tester);
    await _openEditor(tester);
    await _writeOn(tester);
    expect(find.textContaining('YAZMA KİPİ AÇIK'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(find.textContaining('YAZMA KİPİ AÇIK'), findsNothing);
    expect(find.text('Önizle'), findsNothing);
    await _writeOn(tester);
    expect(env.auths, 2);
    expect(find.textContaining('YAZMA KİPİ AÇIK'), findsOneWidget);
    await _finish(tester);
  });

  void superuserConn() {
    FakeAgent.db.connections[0]['readCredential'] = {'mode': 'fromContainerEnv'};
    FakeAgent.db.connections[0]['warnings'] = ['superuserCredential'];
  }

  testWidgets('süper kullanıcı okumaları kapalı TR: açıklama + iki eylem; "Riski kabul et" güçlü onayla allowSuperuserReads', (tester) async {
    superuserConn();
    FakeAgent.db.queryError = const AgentError('agent.db.superuserReadsDisabled', {}, 403);
    await _Env().h.pump(tester, route: _conn);
    _tall(tester, 1300);
    await _load(tester);
    expect(find.textContaining('okuma sorguları kapalı'), findsOneWidget);
    expect(find.text('Salt okunur rol kullan'), findsOneWidget);
    expect(find.text('Riski kabul et'), findsOneWidget);
    expect(find.text('argo (PC)'), findsOneWidget, reason: 'host adı başlıkta');
    await golden('png/db_superuser_reads_off_tr.png');
    await _openEditor(tester, sql: 'SELECT 1');
    await _tapText(tester, 'Çalıştır');
    expect(find.text('Riski kabul et'), findsNWidgets(2), reason: 'düzenleyicideki hata da aynı eylemleri sunar');
    await _tapText(tester, 'Riski kabul et');
    expect(find.textContaining('süper kullanıcı girişiyle okuma sorgularına izin verilsin mi'), findsOneWidget);
    final allow = find.widgetWithText(FilledButton, 'Süper kullanıcı okumalarına izin ver');
    expect(tester.widget<FilledButton>(allow).onPressed, isNull, reason: '"anlıyorum" işaretlenmeden olmaz');
    await tester.tap(find.text('Riski anlıyorum'));
    await settle(tester);
    await tester.tap(allow);
    await _load(tester);
    final patch = FakeAgent.calls.lastWhere((c) => c.$1 == 'PATCH').$3 as Map;
    expect(patch, {'allowSuperuserReads': true});
    expect(find.text('Süper kullanıcı okumalarına izin verildi (risk kabul edildi)'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('"Salt okunur rol kullan": rol SQL\'i açılır, rol bağlantı formunda okuma rolü olur', (tester) async {
    superuserConn();
    final env = _Env();
    await env.h.pump(tester, route: _conn);
    _tall(tester, 1700);
    await _load(tester);
    await _tapText(tester, 'Salt okunur rol kullan');
    expect(find.textContaining('CREATE ROLE "tiphys_ro"'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(env.secure.last, isTrue, reason: 'rol SQL\'inde parola var');
    await _tapText(tester, 'Okuma rolü olarak ayarla');
    expect(find.widgetWithText(TextField, 'tiphys_ro'), findsOneWidget);
    await tester.tap(find.text('Kaydet').first);
    await _load(tester);
    final patch = FakeAgent.calls.lastWhere((c) => c.$1 == 'PATCH').$3 as Map;
    expect(patch['readRole'], 'tiphys_ro');
    expect(patch.containsKey('allowSuperuserReads'), isFalse);
    expect(find.text('Okumalar tiphys_ro rolüyle çalışır'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('geri yükleme testleri tek host için de host adını gösterir; belirsiz ipucu tüm hostları adlarıyla listeler', (tester) async {
    await _Env().h.pump(tester, route: '/db/restore?host=argo');
    _tall(tester, 1300);
    await _load(tester);
    expect(find.byWidgetPredicate((w) => w is SectionLabel && w.text == 'argo (PC)'), findsOneWidget);
    await _finish(tester);
  });
}
