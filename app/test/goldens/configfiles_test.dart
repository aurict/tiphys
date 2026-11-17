// Config files and secrets: files list, file screen (masked, staged edits, revealed), preview sheet with the restart
// option, conflict, backups. Every secret value in these screens is a fake placeholder.
// To update: flutter test test/goldens/configfiles_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/vault/sensitive_clipboard.dart';
import 'package:tiphys/features/configfiles/config_file_screen.dart';
import 'package:tiphys/features/configfiles/configfiles_screen.dart';
import 'package:tiphys/features/vault/vault_state.dart';
import 'package:tiphys/widgets/surfaces.dart' show upper;

import '../helpers/harness.dart';

const _fileA = 'cf-aaaaaaaaaaaaaaaaaaaaaaaa';
const _file = '/configfiles/file?host=argo&id=$_fileA';

class _Native implements SensitiveClipboardNative {
  final copied = <String>[];
  @override
  Future<void> setSensitive(String text, String label) async => copied.add(text);
  @override
  Future<bool> clearIfLabel(String label) async => true;
}

class _Env {
  _Env({this.lock = true});
  final bool lock;
  int auths = 0;
  final secure = <bool>[];
  final native = _Native();

  Harness get h => Harness(agentFeatures: [...Harness.defaultAgentFeatures, 'configfiles', 'incidents'], extra: [
        revealLockAvailableProvider.overrideWith((ref) async => lock),
        vaultAuthProvider.overrideWithValue((c) async {
          auths++;
          return true;
        }),
        secureWindowProvider.overrideWithValue((on) async => secure.add(on)),
        sensitiveClipboardProvider.overrideWithValue(SensitiveClipboard(native)),
      ]);
}

void _tall(WidgetTester tester, [double height = 1700]) => tester.view.physicalSize = Size(390 * 2, height * 2);

Future<void> _load(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
  debugDisableShadows = true;
}

Future<void> _menu(WidgetTester tester, String key, String action) async {
  await tester.tap(find.text(key).first);
  await settle(tester);
  await tester.tap(find.text(action));
  await settle(tester);
}

Future<void> _dialogField(WidgetTester tester, int index, String text) async {
  await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)).at(index), text);
  await tester.pump();
}

/// The destructive confirmation dialog's confirm button.
Future<void> _confirmDialog(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
  await _load(tester);
}

Future<void> _toggleRestart(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(SwitchListTile));
  await tester.pump();
  await tester.tap(find.byType(SwitchListTile));
  await _load(tester);
}

Future<void> _openPreview(WidgetTester tester) async {
  await tester.tap(find.text('Kaydet').first);
  await _load(tester);
}

void main() {
  setUp(() {
    FakeAgent.resetConfig();
    FakeAgent.resetIncidents();
    FakeAgent.calls.clear();
  });

  testWidgets('dosya listesi açık TR: yığınlar, atlanan dosyalar daraltılmış', (tester) async {
    await _Env().h.pump(tester, route: '/configfiles');
    _tall(tester);
    await _load(tester);
    expect(find.text('shop/.env'), findsOneWidget);
    expect(find.text('herkes okuyabilir'), findsOneWidget);
    expect(find.text('Atlanan dosyalar (3)'), findsOneWidget);
    expect(find.text('shop/notes.txt'), findsNothing, reason: 'daraltılmış');
    await golden('png/configfiles_list_light_tr.png');
    await tester.tap(find.text('Atlanan dosyalar (3)'));
    await settle(tester);
    expect(find.textContaining('.env, *.env ya da .env.*'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('dosya listesi: özellik yoksa açıklama; sistem ekranında satır yalnız özellik varsa', (tester) async {
    await Harness().pump(tester, route: '/configfiles');
    await _load(tester);
    expect(find.textContaining('configfiles özelliği'), findsOneWidget);
    await _finish(tester);
    await _Env().h.pump(tester, route: '/system');
    await _load(tester);
    await tester.scrollUntilVisible(find.text('Ayarlar ve sırlar'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Ayarlar ve sırlar'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('dosya ekranı koyu EN: maskeli sırlar, sır olmayan değerler, yaş çipi, çift satır', (tester) async {
    await _Env().h.pump(tester, route: _file, dark: true, lang: 'en');
    _tall(tester);
    await _load(tester);
    expect(find.text('DB_PASSWORD'), findsOneWidget);
    expect(find.text('••••${fakeSecretValue.length}'), findsOneWidget);
    expect(find.text('https://shop.example.org'), findsOneWidget);
    expect(find.textContaining(fakeSecretValue), findsNothing);
    expect(find.text('12 d'), findsOneWidget);
    expect(find.text('120 d · rotate'), findsOneWidget, reason: 'maxAgeDays aşıldı');
    expect(find.text('overridden'), findsOneWidget);
    await golden('png/configfile_masked_dark_en.png');
    await _finish(tester);
  });

  testWidgets('dosya ekranı: uyarılar ve kapanmamış tırnak dosyayı salt okunur yapar', (tester) async {
    final st = FakeAgent.config;
    st.files['argo']![0] = FakeConfigFile(_fileA, 'shop/.env', 'shop', [FakeEntry('A', 'x')], worldReadable: true, issues: [
      {'line': 7, 'reason': 'unterminatedQuote'},
      {'line': 9, 'reason': 'syntax'},
    ]);
    await _Env().h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    expect(find.textContaining('PC\'deki her kullanıcı'), findsOneWidget);
    expect(find.textContaining('7. satırda açılan tırnak'), findsOneWidget);
    expect(find.textContaining('9. satır okunamadı'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Anahtar ekle')).onPressed, isNull);
    await tester.tap(find.text('A'));
    await settle(tester);
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Değeri değiştir')).enabled, isFalse);
    await _finish(tester);
  });

  testWidgets('hazır değişiklikler: düzenle, ekle, sil, yeniden adlandır → Kaydet → önizleme TR → onay → PUT', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    await _menu(tester, 'DB_HOST', 'Değeri değiştir');
    expect(find.widgetWithText(TextField, 'db'), findsOneWidget, reason: 'sır olmayan değer önceden dolu');
    await _dialogField(tester, 0, 'db2');
    await tester.tap(find.text('Tamam'));
    await settle(tester);
    await _menu(tester, 'DB_PASSWORD', 'Değeri değiştir');
    expect(find.text('Şimdiki değer gösterilmez. Yazdığınız onun yerine geçer.'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Tamam')).onPressed, isNull, reason: 'boş sır kabul edilmez');
    await _dialogField(tester, 0, 'EXAMPLE-NEW-SECRET-9999');
    expect(tester.widget<EditableText>(find.byType(EditableText).first).obscureText, isTrue, reason: 'yazılan sır gizli');
    expect(env.secure.last, isTrue, reason: 'değer yazılırken FLAG_SECURE');
    await tester.tap(find.text('Tamam'));
    await settle(tester);
    expect(env.secure.last, isFalse);
    await tester.tap(find.widgetWithText(FilledButton, 'Anahtar ekle'));
    await settle(tester);
    await _dialogField(tester, 0, 'DB_HOST');
    expect(find.text('Bu anahtar dosyada zaten var.'), findsOneWidget);
    await _dialogField(tester, 0, 'NEW_FLAG');
    await _dialogField(tester, 1, 'on');
    await tester.tap(find.text('Tamam'));
    await settle(tester);
    await _menu(tester, 'DB_PORT', 'Anahtarı sil');
    await _menu(tester, 'APP_URL', 'Anahtarı yeniden adlandır');
    await _dialogField(tester, 0, 'SITE_URL');
    await tester.tap(find.text('Tamam'));
    await settle(tester);
    expect(find.textContaining('5 değişiklik hazır'), findsOneWidget);
    expect(find.text('EXAMPLE-NEW-SECRET-9999'), findsNothing, reason: 'hazır sır listede de maskeli');
    await _openPreview(tester);
    expect(find.text('Değişiklikleri önizle'), findsOneWidget);
    expect(find.text('- DB_HOST=db'), findsOneWidget);
    expect(find.text('+ DB_HOST=db2'), findsOneWidget);
    expect(find.textContaining('+ DB_PASSWORD=••••23'), findsOneWidget);
    expect(find.textContaining('EXAMPLE-NEW-SECRET'), findsNothing);
    expect(find.text('shop: web, worker'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged, isNotNull, reason: 'yeniden oluşturma açık');
    await golden('png/configfile_preview_tr.png');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await settle(tester);
    expect(find.textContaining('önce yedeklenir'), findsOneWidget);
    await _confirmDialog(tester);
    final put = FakeAgent.calls.where((c) => c.$1 == 'PUT' && c.$2 == '/v1/config-files/$_fileA').single;
    expect((put.$3 as Map)['restart'], 'none');
    expect((put.$3 as Map)['confirm'], true);
    expect(find.textContaining('Kaydedildi.'), findsOneWidget);
    expect(find.textContaining('Yedek: b1'), findsOneWidget);
    final preview = FakeAgent.calls.firstWhere((c) => c.$2.endsWith('/preview')).$3 as Map;
    expect(preview['baseHash'], 'h1');
    expect((preview['ops'] as List).map((o) => o['op']), ['unset', 'rename', 'set', 'set', 'set']);
    await tester.tap(find.text('Kapat'));
    await _load(tester);
    expect(find.text('NEW_FLAG'), findsOneWidget);
    expect(find.text('Önizlemek için Kaydet\'e dokunun.'), findsNothing);
    expect(find.text('DB_PORT'), findsNothing);
    await _finish(tester);
  });

  testWidgets('önizleme: yeniden oluştur açılır → plan görünür → PUT restart affected, uzun zaman aşımı', (tester) async {
    await _Env().h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    await _menu(tester, 'DB_HOST', 'Değeri değiştir');
    await _dialogField(tester, 0, 'db2');
    await tester.tap(find.text('Tamam'));
    await settle(tester);
    await _openPreview(tester);
    expect(find.text(upper('Çalışacak komutlar', 'tr')), findsNothing);
    await _toggleRestart(tester);
    expect(find.text(upper('Çalışacak komutlar', 'tr')), findsOneWidget);
    expect(find.textContaining('docker compose -f /home/user/stack/shop/compose.yaml up -d --no-deps web worker', findRichText: true), findsOneWidget);
    expect((FakeAgent.calls.where((c) => c.$2.endsWith('/preview')).last.$3 as Map)['restart'], 'affected');
    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await settle(tester);
    expect(find.textContaining('kısa süre yeniden başlarlar'), findsOneWidget);
    await _confirmDialog(tester);
    expect((FakeAgent.calls.where((c) => c.$1 == 'PUT').single.$3 as Map)['restart'], 'affected');
    expect(find.text(upper('Yeniden oluşturulan servisler', 'tr')), findsOneWidget);
    expect(find.text('running/healthy'), findsNWidgets(2));
    await _finish(tester);
  });

  testWidgets('önizleme: etkilenen servis yoksa yeniden oluşturma kapalı (nedeniyle)', (tester) async {
    FakeAgent.config.affected = [];
    await _Env().h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    await _menu(tester, 'DB_HOST', 'Değeri değiştir');
    await _dialogField(tester, 0, 'db2');
    await tester.tap(find.text('Tamam'));
    await settle(tester);
    await _openPreview(tester);
    expect(find.text('Bu anahtarları kullanan servis yok.'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged, isNull);
    expect(find.textContaining('yeniden oluşturulacak bir şey yok'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('yeniden oluşturma başarısız: servis durumu, hata çıktısı ve Yedeğe dön → geri yükleme önizlemesi', (tester) async {
    FakeAgent.config.recreateFails = true;
    await _Env().h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    await _menu(tester, 'DB_HOST', 'Değeri değiştir');
    await _dialogField(tester, 0, 'db2');
    await tester.tap(find.text('Tamam'));
    await settle(tester);
    await _openPreview(tester);
    await _toggleRestart(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await settle(tester);
    await _confirmDialog(tester);
    expect(find.textContaining('sağlıklı çalışmıyorlar'), findsOneWidget);
    expect(find.text('exited'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Yedeğe dön'));
    await _load(tester);
    expect(find.text('Geri yüklemeyi önizle'), findsOneWidget);
    expect(find.textContaining('+ DB_HOST=db'), findsOneWidget);
    final restore = FakeAgent.calls.where((c) => c.$2.endsWith('/restore')).first.$3 as Map;
    expect(restore['backupId'], 'b1');
    await _finish(tester);
  });

  testWidgets('çakışma: dosya değişmişse 409 → yeniden yükle; hazır değişiklikler korunur', (tester) async {
    await _Env().h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    await _menu(tester, 'DB_HOST', 'Değeri değiştir');
    await _dialogField(tester, 0, 'db2');
    await tester.tap(find.text('Tamam'));
    await settle(tester);
    FakeAgent.config.files['argo']![0].version = 5; // changed on the PC meanwhile
    await _openPreview(tester);
    expect(find.textContaining('Dosya siz açtıktan sonra değişti'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Yeniden yükle'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Yeniden yükle'));
    await _load(tester);
    expect(find.text('Dosya yeniden yüklendi.'), findsOneWidget);
    expect(find.textContaining('1 değişiklik hazır'), findsOneWidget);
    await _openPreview(tester);
    expect(find.text('Değişiklikleri önizle'), findsOneWidget);
    expect((FakeAgent.calls.where((c) => c.$2.endsWith('/preview')).last.$3 as Map)['baseHash'], 'h5');
    await _finish(tester);
  });

  testWidgets('Göster: kilit sorulur, FLAG_SECURE açılır, değer görünür, 30 sn sonra maskelenir (golden TR)', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    await tester.tap(find.byTooltip('Göster').first);
    await _load(tester);
    expect(env.auths, 1);
    expect(FakeAgent.config.revealCalls, [['DB_PASSWORD']]);
    expect(find.text(fakeSecretValue), findsOneWidget);
    expect(env.secure, [true]);
    expect(find.textContaining('30 sn sonra yeniden gizlenir'), findsOneWidget);
    await golden('png/configfile_revealed_tr.png');
    await tester.pump(const Duration(seconds: 31));
    expect(find.text(fakeSecretValue), findsNothing);
    expect(find.text('••••${fakeSecretValue.length}'), findsOneWidget);
    expect(env.secure, [true, false]);
    // Every reveal asks for the lock again.
    await tester.tap(find.byTooltip('Göster').first);
    await _load(tester);
    expect(env.auths, 2);
    await tester.tap(find.byTooltip('Kopyala'));
    await settle(tester);
    expect(env.native.copied, [fakeSecretValue]);
    await tester.tap(find.byTooltip('Gizle').first);
    await settle(tester);
    expect(find.text(fakeSecretValue), findsNothing);
    await _finish(tester);
  });

  testWidgets('Göster: ekrandan çıkınca değer bellekten silinir ve FLAG_SECURE kapanır', (tester) async {
    final env = _Env();
    final c = await env.h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    await tester.tap(find.byTooltip('Göster').first);
    await _load(tester);
    expect(find.text(fakeSecretValue), findsOneWidget);
    c.router.go('/configfiles');
    await _load(tester);
    expect(find.text(fakeSecretValue), findsNothing);
    expect(env.secure.last, isFalse);
    await _finish(tester);
  });

  testWidgets('Göster: uygulama kilidi yoksa istek gönderilmez', (tester) async {
    final env = _Env(lock: false);
    await env.h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    await tester.tap(find.byTooltip('Göster').first);
    await _load(tester);
    expect(env.auths, 0);
    expect(FakeAgent.config.revealCalls, isEmpty);
    expect(find.textContaining('uygulama kilidi'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('Göster: hız sınırı hata metni; çoklu seçimle tek istek', (tester) async {
    final env = _Env();
    await env.h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    FakeAgent.config.revealError = const AgentError('agent.configfiles.rateLimited', {}, 429);
    await tester.tap(find.byTooltip('Göster').first);
    await _load(tester);
    expect(find.textContaining('Dakikada çok fazla gösterme'), findsOneWidget);
    FakeAgent.config.revealError = null;
    await tester.tap(find.text('Seç'));
    await settle(tester);
    await tester.tap(find.text('DB_PASSWORD'));
    await tester.tap(find.text('API_TOKEN'));
    await settle(tester);
    expect(find.text('2/10 seçili'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Göster'));
    await _load(tester);
    expect(FakeAgent.config.revealCalls.last, ['DB_PASSWORD', 'API_TOKEN']);
    expect(find.text(fakeSecretValue), findsOneWidget);
    expect(find.text('EXAMPLE-NOT-A-REAL-TOKEN-0002'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('sır ayarları: işaretle ve 90 gün öner → PUT /v1/secrets/meta yalnız değişen alanlarla', (tester) async {
    await _Env().h.pump(tester, route: _file);
    _tall(tester);
    await _load(tester);
    await _menu(tester, 'DB_HOST', 'Sır ayarları');
    await tester.tap(find.text('Sır'));
    await tester.tap(find.text('90 gün öner'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await _load(tester);
    expect(FakeAgent.config.metaCalls.single, {
      'updates': [
        {'fileId': _fileA, 'key': 'DB_HOST', 'secret': true, 'maxAgeDays': 90},
      ],
    });
    expect(find.byIcon(Icons.lock), findsNothing);
    await _finish(tester);
  });

  testWidgets('yedekler EN: liste, geri yükleme önizlemesi ve onay', (tester) async {
    await _Env().h.pump(tester, route: '/configfiles/backups?host=argo&id=$_fileA', lang: 'en');
    _tall(tester);
    await _load(tester);
    expect(find.text('Restore'), findsNWidgets(2));
    await golden('png/configfile_backups_en.png');
    await tester.tap(find.text('Restore').first);
    await _load(tester);
    expect(find.text('Review restore'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await settle(tester);
    await _confirmDialog(tester);
    final restore = FakeAgent.calls.where((c) => c.$2.endsWith('/restore')).last.$3 as Map;
    expect(restore['confirm'], true);
    expect(restore['backupId'], 'b-old2');
    expect(find.textContaining('Restored.'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('375 px genişlikte taşma yok (liste, dosya, önizleme)', (tester) async {
    await _Env().h.pump(tester, route: '/configfiles');
    tester.view.physicalSize = const Size(375 * 2, 1700 * 2);
    await _load(tester);
    expect(tester.takeException(), isNull);
    final c = ProviderScope.containerOf(tester.element(find.byType(ConfigFilesScreen)));
    c.router.push(_file);
    await _load(tester);
    expect(find.byType(ConfigFileScreen), findsOneWidget);
    await _menu(tester, 'DB_HOST', 'Değeri değiştir');
    await _dialogField(tester, 0, 'db2');
    await tester.tap(find.text('Tamam'));
    await settle(tester);
    await _openPreview(tester);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });
}
