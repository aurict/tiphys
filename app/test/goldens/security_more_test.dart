// Security center S-2…S-5: section entries, vulnerabilities, secrets, scanner settings, traps, outside view, attacks,
// black box, lost phone and the lockdown. Machine names are examples (argo PC, atlas server, orion SSH host).
// To update: TZ=Europe/Berlin flutter test test/goldens/security_more_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/vault/sensitive_clipboard.dart';
import 'package:tiphys/features/configfiles/config_file_screen.dart' show revealLockAvailableProvider;
import 'package:tiphys/features/security/security_more_data.dart';
import 'package:tiphys/features/vault/vault_state.dart' show secureWindowProvider, sensitiveClipboardProvider, vaultAuthProvider;

import '../helpers/harness.dart';

class _Native implements SensitiveClipboardNative {
  final copied = <String>[];
  @override
  Future<void> setSensitive(String text, String label) async => copied.add(text);
  @override
  Future<bool> clearIfLabel(String label) async => true;
}

class _Env {
  _Env({this.lock = true, this.authOk = true});
  final bool lock, authOk;
  int auths = 0;
  final secure = <bool>[];
  final native = _Native();
  final lockdownCalls = <(String, String)>[];
  Object? lockdownError;
  List<LockdownResult> lockdownResults = [
    LockdownResult({'id': 'orion', 'name': 'orion', 'ok': true, 'status': 200}),
    LockdownResult({'id': 'atlas', 'name': 'atlas', 'ok': false, 'status': null}),
  ];

  Harness get h => Harness(agentFeatures: [...Harness.defaultAgentFeatures, 'security', 'telegram'], extra: [
        revealLockAvailableProvider.overrideWith((ref) async => lock),
        vaultAuthProvider.overrideWithValue((c) async {
          auths++;
          return authOk;
        }),
        secureWindowProvider.overrideWithValue((on) async => secure.add(on)),
        sensitiveClipboardProvider.overrideWithValue(SensitiveClipboard(native)),
        lockdownCallProvider.overrideWithValue((url, code) async {
          lockdownCalls.add((url, code));
          if (lockdownError != null) throw lockdownError!;
          return lockdownResults;
        }),
      ]);
}

void _tall(WidgetTester tester, [double height = 1900, double width = 390]) => tester.view.physicalSize = Size(width * 2, height * 2);

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

Future<void> _tapText(WidgetTester tester, String text) => _tap(tester, find.text(text));

/// A button in the open dialog.
Future<void> _dialogButton(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(label)));
  await _load(tester);
}

Future<void> _dialogField(WidgetTester tester, int index, String text) async {
  await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)).at(index), text);
  await tester.pump();
}

/// Requests sent to the fake agent: (method, path, body).
List<(String, String, Object?)> _sent(String method, String path) => [for (final c in FakeAgent.calls) if (c.$1 == method && c.$2 == path) c];

void main() {
  setUp(() {
    FakeAgent.resetSecurity();
    FakeAgent.resetIncidents();
    FakeAgent.calls.clear();
  });

  group('ana sayfa', () {
    testWidgets('bölüm girişleri listelenir ve açılır', (tester) async {
      await _Env().h.pump(tester, route: '/security');
      _tall(tester, 1500);
      await _load(tester);
      for (final t in ['Açıklar', 'Sırlar', 'Tuzaklar', 'Dış görünüm', 'Saldırılar', 'Kara kutu', 'Telefon kaybı']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('orion'), findsWidgets, reason: 'makine listesi de duruyor');
      await _tapText(tester, 'Açıklar');
      expect(find.text('registry.example.org/web:1.4'), findsWidgets);
      await _finish(tester);
    });
  });

  group('açıklar', () {
    testWidgets('liste TR: durumlar, sayılar, nerede çalıştığı, bilgi notu', (tester) async {
      await _Env().h.pump(tester, route: '/security/vulns?host=atlas');
      _tall(tester, 2300);
      await _load(tester);
      expect(find.text('registry.example.org/web:1.4'), findsOneWidget);
      expect(find.text('Tarandı'), findsNWidgets(2));
      expect(find.text('Giriş gerekli'), findsOneWidget);
      expect(find.text('Bekliyor'), findsOneWidget);
      expect(find.text('Başarısız'), findsOneWidget);
      expect(find.text('2 Kritik'), findsOneWidget);
      expect(find.text('3 Yüksek'), findsOneWidget);
      expect(find.text('3 düzeltilebilir'), findsOneWidget);
      expect(find.textContaining('ghcr.io giriş istiyor'), findsOneWidget, reason: 'ghcr belirteci açıklaması');
      expect(find.textContaining('Geceyi bekliyor'), findsOneWidget);
      expect(find.textContaining('gecede en fazla 2 tane'), findsOneWidget, reason: 'gece ve gecelik sınır açıklaması');
      expect(find.textContaining('atlas: example-web, example-worker'), findsWidgets);
      expect(find.textContaining('orion: example-api'), findsOneWidget);
      expect(find.text('Kritik/yüksek yok'), findsOneWidget);
      await golden('png/security_vulns_light_tr.png');
      await _finish(tester);
    });

    testWidgets('"Şimdi tara": POST {} ve 202 bildirimi; meşgul ve hız sınırı hata metinleri', (tester) async {
      await _Env().h.pump(tester, route: '/security/vulns?host=atlas');
      _tall(tester, 2300);
      await _load(tester);
      await _tapText(tester, 'Şimdi tara');
      expect(_sent('POST', '/v1/security/vulns/scan').single.$3, <String, dynamic>{});
      expect(find.text('Tarama başlatıldı'), findsOneWidget);

      FakeAgent.securityMore.errors['POST /v1/security/vulns/scan'] = const AgentError('agent.security.scanBusy', {}, 409);
      await _tapText(tester, 'Şimdi tara');
      expect(find.text('Bir tarama zaten sürüyor.'), findsOneWidget);
      FakeAgent.securityMore.errors['POST /v1/security/vulns/scan'] = const AgentError('agent.security.rateLimited', {}, 429);
      await _tapText(tester, 'Şimdi tara');
      expect(find.textContaining('Çok sık'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('tarayıcı kapalıysa açıklama; ajan ipucu olmadan her ajan bir blok', (tester) async {
      await _Env().h.pump(tester, route: '/security/vulns?host=argo');
      await _load(tester);
      expect(find.textContaining('Trivy’yi aç'), findsOneWidget);
      expect(find.text('Şimdi tara'), findsNothing);
      await _finish(tester);

      await _Env().h.pump(tester, route: '/security/vulns');
      _tall(tester, 2500);
      await _load(tester);
      expect(find.text('ARGO (PC)'), findsOneWidget);
      expect(find.text('ATLAS'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('ayrıntı TR: tablo, yalnız düzeltilebilir süzgeci, kısaltıldı notu; imaj taraması', (tester) async {
      await _Env().h.pump(tester, route: securityVulnRoute('a' * 64, agentId: 'atlas'));
      _tall(tester, 2600);
      await _load(tester);
      expect(find.text('CVE-2026-1001'), findsOneWidget);
      expect(find.text('1.2.3-1 → 1.2.4-1'), findsOneWidget);
      expect(find.text('3.0.1 · düzeltme yok'), findsOneWidget);
      expect(find.textContaining('Liste kısaltıldı'), findsOneWidget);
      expect(find.text('CVE-2026-2003'), findsOneWidget);
      await golden('png/security_vuln_detail_light_tr.png');

      await _tapText(tester, 'Yalnız düzeltilebilenler');
      expect(find.text('CVE-2026-1002'), findsNothing, reason: 'düzeltmesi olmayan gizlenir');
      expect(find.text('CVE-2026-2003'), findsNothing);
      expect(find.text('CVE-2026-1001'), findsOneWidget);

      await _tapText(tester, 'Şimdi tara');
      final scan = _sent('POST', '/v1/security/vulns/scan').single;
      expect(scan.$3, {'imageId': 'sha256:${'a' * 64}'});
      await _finish(tester);
    });

    testWidgets('ayrıntı: giriş gerekli açıklaması; bulunamayan imaj; bağlantı ajan ipucu olmadan da açılır', (tester) async {
      await _Env().h.pump(tester, route: securityVulnRoute('b' * 64));
      await _load(tester);
      expect(find.textContaining('özel bir kayıt defterinde (ghcr.io)'), findsOneWidget);
      expect(find.textContaining('paketleri okuyabilen'), findsOneWidget);
      await _finish(tester);

      await _Env().h.pump(tester, route: securityVulnRoute('f' * 64, agentId: 'atlas'));
      await _load(tester);
      expect(find.text('Bu imaj (artık) bilinmiyor.'), findsOneWidget);
      expect(find.text('Tekrar dene'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('sırlar', () {
    testWidgets('TR: son tarama kaynak hataları, bulgular (değer yok), depolar; yoksayma', (tester) async {
      await _Env().h.pump(tester, route: '/security/secrets?host=atlas');
      _tall(tester, 2400);
      await _load(tester);
      expect(find.textContaining('Son tarama 9 sa önce'), findsOneWidget);
      expect(find.textContaining('Günlükler (Loki): Loki kapsayıcısı ya da adresi kullanılamıyor'), findsOneWidget);
      expect(find.text('aws-access-token'), findsOneWidget);
      expect(find.text('config/old.env:12'), findsOneWidget);
      expect(find.text('commit deadbeef'), findsOneWidget);
      expect(find.text('container=example-api'), findsOneWidget);
      expect(find.text('private-key'), findsNothing, reason: 'yoksayılan varsayılan olarak gizli');
      expect(find.text('Yoksayılanları göster (1)'), findsOneWidget);
      expect(find.text('example-org/legacy'), findsOneWidget);
      expect(find.text('klonlanamadı', skipOffstage: false), findsNothing, reason: 'tek satırda başka metinle');
      expect(find.textContaining('klonlanamadı'), findsOneWidget);
      await golden('png/security_secrets_light_tr.png');

      await _tap(tester, find.text('Yoksay').first);
      final call = _sent('POST', '/v1/security/secrets/${'a' * 24}/dismiss').single;
      expect(call.$3, {'dismissed': true});
      expect(find.text('aws-access-token'), findsNothing);

      await _tapText(tester, 'Yoksayılanları göster (2)');
      expect(find.text('private-key'), findsOneWidget);
      await _tap(tester, find.text('Yoksaymayı geri al').first);
      expect(_sent('POST', '/v1/security/secrets/${'a' * 24}/dismiss').last.$3, {'dismissed': false});
      await _finish(tester);
    });

    testWidgets('gruplar: klasör başına tek kart (kapalı), grup yoksayma onaylı; tek bulgu düz kart', (tester) async {
      Map<String, dynamic> f(int i, String dir, {String rule = 'aws-access-token'}) => {
            'id': i.toRadixString(16).padLeft(24, '0'),
            'source': 'github',
            'rule': rule,
            'where': 'example-org/site',
            'file': '$dir/file$i.env',
            'line': i,
            'commit': 'deadbeefcafe',
            'stream': null,
            'at': null,
            'firstSeenAt': '2026-11-12T10:00:00Z',
            'dismissed': false,
          };
      FakeAgent.securityMore.secrets = {
        'lastRun': null,
        'running': false,
        'repos': <Map>[],
        'findings': [
          for (var i = 1; i <= 3; i++) f(i, 'fixtures/keys'),
          f(11, 'fixtures/keys/sub'),
          f(10, 'src'),
          for (var i = 20; i <= 21; i++) {...f(i, ''), 'source': 'loki', 'where': 'atlas', 'file': null, 'stream': 'container=example-api'},
        ],
      };
      await _Env().h.pump(tester, route: '/security/secrets?host=atlas');
      _tall(tester, 2400);
      await _load(tester);
      expect(find.text('3 bulgu'), findsOneWidget);
      expect(find.text('2 bulgu'), findsOneWidget);
      expect(find.text('fixtures/keys/'), findsOneWidget);
      expect(find.text('file1.env:1'), findsNothing, reason: 'varsayılan kapalı');
      expect(find.text('src/file10.env:10'), findsOneWidget, reason: 'tek bulgu düz kart');
      await _tap(tester, find.text('fixtures/keys/'));
      expect(find.text('fixtures/keys/file1.env:1'), findsOneWidget);

      await _tap(tester, find.text('Bu gruptakileri kapat').first);
      expect(find.textContaining('3 bulgusu yoksayılsın mı'), findsOneWidget);
      await _tapText(tester, 'Vazgeç');
      expect(_sent('POST', '/v1/security/secrets/dismiss-group'), isEmpty);

      await _tap(tester, find.text('Bu gruptakileri kapat').first);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Bu gruptakileri kapat')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_sent('POST', '/v1/security/secrets/dismiss-group').single.$3, {'source': 'github', 'where': 'example-org/site', 'rule': 'aws-access-token', 'pathPrefix': 'fixtures/keys/', 'dismissed': true});
      await _load(tester);
      expect(find.text('3 bulgu güncellendi'), findsOneWidget);
      expect(find.text('fixtures/keys/sub/file11.env:11'), findsOneWidget, reason: 'alt klasördeki bulgu etkilenmez');
      expect(find.text('3 bulgu'), findsNothing, reason: 'grup yoksayılanlara taşındı');

      await _tap(tester, find.text('Bu gruptakileri kapat').first);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Bu gruptakileri kapat')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_sent('POST', '/v1/security/secrets/dismiss-group').last.$3, {'source': 'loki', 'where': 'atlas', 'rule': 'aws-access-token', 'stream': 'container=example-api', 'dismissed': true});
      await _finish(tester);
    });

    testWidgets('"Şimdi tara": 202; meşgulse 409 metni; bulgu yoksa boş durum', (tester) async {
      await _Env().h.pump(tester, route: '/security/secrets?host=atlas');
      _tall(tester, 2400);
      await _load(tester);
      await _tapText(tester, 'Şimdi tara');
      expect(_sent('POST', '/v1/security/secrets/scan').single.$3, <String, dynamic>{});
      expect(find.text('Tarama başlatıldı'), findsOneWidget);
      FakeAgent.securityMore.errors['POST /v1/security/secrets/scan'] = const AgentError('agent.security.scanBusy', {}, 409);
      await _tapText(tester, 'Şimdi tara');
      expect(find.text('Bir tarama zaten sürüyor.'), findsOneWidget);
      await _finish(tester);

      FakeAgent.securityMore.secrets = {'lastRun': null, 'running': false, 'repos': <Map>[], 'findings': <Map>[]};
      await _Env().h.pump(tester, route: '/security/secrets?host=atlas');
      await _load(tester);
      expect(find.textContaining('Henüz taranmadı'), findsWidgets);
      await _finish(tester);
    });
  });

  group('tarayıcı ayarları', () {
    testWidgets('anahtarlar PATCH eder; belirteçler gösterilmez', (tester) async {
      await _Env().h.pump(tester, route: '/security/scanners?host=atlas');
      _tall(tester, 3200);
      await _load(tester);
      expect(find.text('ghcr.io'), findsOneWidget);
      expect(find.textContaining('example-user · belirteç kayıtlı'), findsOneWidget);
      expect(find.text('example-org'), findsOneWidget);
      expect(find.textContaining('tps_'), findsNothing);
      expect(find.textContaining('ghp_'), findsNothing);
      await tester.tap(find.byType(Switch).at(2));
      await _load(tester);
      expect(_sent('PATCH', '/v1/security/scanners').single.$3, {'javaDb': true});
      await _finish(tester);
    });

    testWidgets('kayıt defteri girişi: jeton boş bırakılınca gönderilmez (korunur); yeni girişte zorunlu', (tester) async {
      await _Env().h.pump(tester, route: '/security/scanners?host=atlas');
      _tall(tester, 3200);
      await _load(tester);
      await _tapText(tester, 'ghcr.io');
      await _dialogButton(tester, 'Kaydet');
      final kept = _sent('PATCH', '/v1/security/scanners').single.$3 as Map;
      expect((kept['registryAuth'] as List).single, {'registry': 'ghcr.io', 'username': 'example-user'}, reason: 'jeton boşsa gönderilmez: ajan eskisini korur');
      await _tapText(tester, 'ghcr.io');
      await _dialogField(tester, 2, 'ghp_exampletoken0123456789');
      await _dialogButton(tester, 'Kaydet');
      final body = _sent('PATCH', '/v1/security/scanners').last.$3 as Map;
      expect((body['registryAuth'] as List).single, {'registry': 'ghcr.io', 'username': 'example-user', 'token': 'ghp_exampletoken0123456789'});
      expect(find.textContaining('ghp_'), findsNothing);
      await _finish(tester);
    });

    testWidgets('GitHub: sahip eklenir, belirteç yazılır ve null ile kaldırılır; Loki; yerel klasör; gece saatleri', (tester) async {
      await _Env().h.pump(tester, route: '/security/scanners?host=atlas');
      _tall(tester, 3600);
      await _load(tester);
      await _tapText(tester, 'Sahip ekle');
      await _dialogField(tester, 0, 'other-org');
      await _dialogButton(tester, 'Ekle');
      expect(_sent('PATCH', '/v1/security/scanners').last.$3, {'github': {'owners': ['example-org', 'other-org']}});

      await tester.enterText(find.widgetWithText(TextFormField, 'GitHub belirteci'), 'ghp_newtoken0123456789abcdef');
      await _tap(tester, find.widgetWithText(FilledButton, 'Kaydet').first);
      expect(_sent('PATCH', '/v1/security/scanners').last.$3, {'github': {'owners': ['example-org', 'other-org'], 'token': 'ghp_newtoken0123456789abcdef'}});
      await _tapText(tester, 'Belirteci kaldır');
      await _dialogButton(tester, 'Belirteci kaldır');
      expect((_sent('PATCH', '/v1/security/scanners').last.$3 as Map)['github']['token'], isNull);

      await _tapText(tester, 'Klasör ekle');
      await _dialogField(tester, 0, '~/work');
      await _dialogButton(tester, 'Ekle');
      expect(_sent('PATCH', '/v1/security/scanners').last.$3, {'localRoots': ['~/projects', '~/work']});

      await tester.enterText(find.widgetWithText(TextFormField, 'Başlangıç'), '1');
      await tester.enterText(find.widgetWithText(TextFormField, 'Bitiş'), '5');
      await _tap(tester, find.widgetWithText(FilledButton, 'Kaydet').last);
      expect(_sent('PATCH', '/v1/security/scanners').last.$3, {'nightHours': [1, 5]});

      await _tapText(tester, 'URL');
      await tester.enterText(find.widgetWithText(TextFormField, 'Loki adresi'), 'https://loki.example.org');
      await _tap(tester, find.widgetWithText(FilledButton, 'Kaydet').at(1));
      expect(_sent('PATCH', '/v1/security/scanners').last.$3, {'loki': {'url': 'https://loki.example.org'}});
      await _finish(tester);
    });
  });

  group('tuzaklar', () {
    testWidgets('TR: belirteçler, dosya durumları, tetiklenme, yedek uyarısı, SSH ve Telegram bölümleri', (tester) async {
      await _Env().h.pump(tester, route: '/security/traps?host=atlas');
      _tall(tester, 3300);
      await _load(tester);
      expect(find.text('backup-token'), findsOneWidget);
      expect(find.text('/home/alice/backup/.env.old'), findsOneWidget);
      expect(find.text('Kurulu'), findsOneWidget);
      expect(find.text('Okuma algılanamıyor'), findsOneWidget);
      expect(find.text('Dosya yok'), findsOneWidget);
      expect(find.textContaining('Disk erişim zamanı tutmadan bağlı'), findsOneWidget);
      expect(find.textContaining('2 sa önce tetiklendi'), findsOneWidget);
      expect(find.text('Hiç tetiklenmedi'), findsNWidgets(2));
      expect(find.textContaining('yedekleme veya eşitleme araçları'), findsWidgets, reason: 'yedek araçları tetikler uyarısı');
      expect(find.text('app_backup'), findsOneWidget);
      expect(find.text('Ayşe'), findsOneWidget, reason: 'Telegram alıcıları aynı ajanın alıcı API’sinden');
      expect(find.text('Eski'), findsNothing, reason: 'durdurulmuş alıcı sunulmaz');
      await golden('png/security_traps_light_tr.png');
      await _finish(tester);
    });

    testWidgets('sahte belirteç: bir kez, FLAG_SECURE sayfada; kopya hassas panoya; kapanınca kaybolur', (tester) async {
      final env = _Env();
      await env.h.pump(tester, route: '/security/traps?host=atlas');
      _tall(tester, 3300);
      await _load(tester);
      await _tapText(tester, 'Sahte belirteç ekle');
      await _dialogField(tester, 0, 'yedek-notu');
      await _dialogButton(tester, 'Oluştur');
      expect(_sent('POST', '/v1/security/traps/tokens').single.$3, {'name': 'yedek-notu'});
      expect(find.text('tps_decoyTokenExampleValue0123456789'), findsOneWidget);
      expect(find.text('Yalnızca bir kez gösterilir. Sonra tekrar okunamaz.'), findsOneWidget);
      expect(find.textContaining('eski bir .env yedeğine'), findsOneWidget, reason: 'nereye konacağı ipucu');
      expect(env.secure, [true], reason: 'FLAG_SECURE açıldı');
      await _tapText(tester, 'Kopyala');
      expect(env.native.copied, ['tps_decoyTokenExampleValue0123456789']);
      await _tapText(tester, 'Sakladım, kapat');
      expect(find.text('tps_decoyTokenExampleValue0123456789'), findsNothing);
      expect(env.secure, [true, false]);
      expect(find.text('yedek-notu'), findsOneWidget, reason: 'liste yenilendi');
      await _finish(tester);
    });

    testWidgets('tek seferlik sayfa uygulama arka plana geçince kapanır', (tester) async {
      final env = _Env();
      await env.h.pump(tester, route: '/security/traps?host=atlas');
      _tall(tester, 3300);
      await _load(tester);
      await _tapText(tester, 'Sahte belirteç ekle');
      await _dialogField(tester, 0, 'yedek-notu');
      await _dialogButton(tester, 'Oluştur');
      expect(find.text('tps_decoyTokenExampleValue0123456789'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // No frames are drawn while paused: come back, then the sheet must be gone.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('tps_decoyTokenExampleValue0123456789'), findsNothing);
      expect(env.secure.last, false);
      await _finish(tester);
    });

    testWidgets('sahte belirteç ekleme hatası: çok fazla tuzak; sahte belirteç silme', (tester) async {
      final env = _Env();
      await env.h.pump(tester, route: '/security/traps?host=atlas');
      _tall(tester, 3300);
      await _load(tester);
      FakeAgent.securityMore.errors['POST /v1/security/traps/tokens'] = const AgentError('agent.security.tooManyTraps', {}, 409);
      await _tapText(tester, 'Sahte belirteç ekle');
      await _dialogField(tester, 0, 'x');
      await _dialogButton(tester, 'Oluştur');
      expect(find.textContaining('Çok fazla tuzak'), findsOneWidget);
      expect(env.secure, isEmpty, reason: 'başarısızsa sayfa açılmaz');
      await tester.tap(find.byTooltip('backup-token sil'));
      await _load(tester);
      await _dialogButton(tester, 'Sil');
      expect(_sent('DELETE', '/v1/security/traps/tokens/trap-1a2b3c4d'), hasLength(1));
      await _finish(tester);
    });

    testWidgets('sahte dosya: ekleme gövdesi, var olan yol hatası, izlemeyi bırakma (dosya kalır notu)', (tester) async {
      await _Env().h.pump(tester, route: '/security/traps?host=atlas');
      _tall(tester, 3300);
      await _load(tester);
      await _tapText(tester, 'Sahte dosya ekle');
      await _dialogField(tester, 0, '/home/alice/old/.env.copy');
      await _dialogButton(tester, 'Oluştur');
      expect(_sent('POST', '/v1/security/traps/files').single.$3, {'path': '/home/alice/old/.env.copy', 'kind': 'env'});
      await _tapText(tester, 'Sahte dosya ekle');
      await _dialogField(tester, 0, '/home/alice/old/.env.copy');
      await _dialogButton(tester, 'Oluştur');
      expect(find.textContaining('zaten bir dosya var'), findsOneWidget);
      await tester.tap(find.byTooltip('/srv/example/.env.bak sil'));
      await _load(tester);
      expect(find.textContaining('Dosya diskte kalır'), findsOneWidget);
      await _dialogButton(tester, 'Sil');
      expect(_sent('DELETE', '/v1/security/traps/files/trap-f3'), hasLength(1));
      await _finish(tester);
    });

    testWidgets('sahte DB kullanıcısı PUT; SSH anahtarı PATCH; deneme uyarısı POST; Telegram alıcısı PUT', (tester) async {
      await _Env().h.pump(tester, route: '/security/traps?host=argo');
      _tall(tester, 3600);
      await _load(tester);
      await _tapText(tester, 'Kullanıcı adı ekle');
      await _dialogField(tester, 0, 'Bad-Name');
      await _dialogButton(tester, 'Ekle');
      expect(find.text('Geçersiz değer'), findsOneWidget, reason: 'ajanın deseniyle doğrulanır');
      await _dialogField(tester, 0, 'report_ro');
      await _dialogButton(tester, 'Ekle');
      expect(_sent('PUT', '/v1/security/traps/db-users').single.$3, {'users': ['app_backup', 'report_ro']});

      expect(find.text('Sahte dosya okumalarını bildir'), findsOneWidget, reason: 'argo orion’u SSH ile denetler');
      await tester.tap(find.byType(Switch).first);
      await _load(tester);
      expect(_sent('PATCH', '/v1/security/hosts/orion').single.$3, {'traps': true});

      await _tapText(tester, 'Deneme uyarısı gönder');
      expect(_sent('POST', '/v1/security/traps/test'), hasLength(1));
      expect(find.text('Deneme uyarısı gönderildi'), findsOneWidget);

      await _tapText(tester, 'Ayşe');
      expect(_sent('PUT', '/v1/security/alerts').single.$3, {'telegramRecipient': 'r_ayse'});
      await _tapText(tester, 'Kapalı');
      expect(_sent('PUT', '/v1/security/alerts').last.$3, {'telegramRecipient': null});
      await _finish(tester);
    });
  });

  group('dış görünüm', () {
    testWidgets('TR: açık portlar, bulgular önem sırasıyla, geçmiş', (tester) async {
      await _Env().h.pump(tester, route: '/security/exposure?host=atlas');
      _tall(tester, 2600);
      await _load(tester);
      expect(find.text('203.0.113.10'), findsOneWidget);
      expect(find.text('5432'), findsOneWidget);
      expect(find.textContaining('5432 portu internete açık'), findsOneWidget);
      expect(find.textContaining('/.env dosyasını sunuyor'), findsOneWidget);
      expect(find.textContaining('9 gün sonra doluyor'), findsOneWidget);
      expect(find.textContaining('x-content-type-options, referrer-policy'), findsOneWidget);
      expect(find.text('5 bulgu'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('"Şimdi çalıştır" POST; hedef düzenleyici PUT gövdesi; geçersiz değer reddedilir; hız sınırı', (tester) async {
      await _Env().h.pump(tester, route: '/security/exposure?host=atlas');
      _tall(tester, 2600);
      await _load(tester);
      await _tapText(tester, 'Şimdi çalıştır');
      expect(_sent('POST', '/v1/security/exposure/run').single.$3, <String, dynamic>{});
      FakeAgent.securityMore.errors['POST /v1/security/exposure/run'] = const AgentError('agent.security.scanBusy', {}, 409);
      await _tapText(tester, 'Şimdi çalıştır');
      expect(find.text('Bir tarama zaten sürüyor.'), findsOneWidget);

      await _tapText(tester, 'Hedefleri düzenle');
      await _tapText(tester, 'Hedef ekle');
      await _dialogField(tester, 0, 'not a host');
      await _dialogButton(tester, 'Ekle');
      expect(find.text('Geçersiz değer'), findsOneWidget);
      await _dialogField(tester, 0, 'api.example.org');
      await _dialogButton(tester, 'Ekle');
      await _tapText(tester, 'Kaydet');
      final body = _sent('PUT', '/v1/security/exposure').single.$3 as Map;
      expect(body['enabled'], isTrue);
      expect(body['intervalDays'], 7);
      expect((body['targets'] as List).last, {'id': 'domain-api-example-org', 'kind': 'domain', 'value': 'api.example.org'});
      expect((body['targets'] as List).first['expectedPorts'], [22, 443]);

      await tester.tap(find.byType(Switch).first);
      await _load(tester);
      expect(_sent('PUT', '/v1/security/exposure').last.$3, containsPair('enabled', false));
      await _finish(tester);
    });
  });

  group('saldırılar', () {
    testWidgets('TR: saldırgan kartları, engel, yollar; "Şimdi kontrol et" POST', (tester) async {
      await _Env().h.pump(tester, route: '/security/attacks?host=atlas');
      _tall(tester, 2200);
      await _load(tester);
      expect(find.text('198.51.100.23'), findsOneWidget);
      expect(find.text('88 hata'), findsOneWidget);
      expect(find.text('14 tarayıcı yolu'), findsOneWidget);
      expect(find.textContaining('/phpmyadmin/index.php'), findsOneWidget);
      expect(find.textContaining('tarihine kadar engelli'), findsOneWidget);
      await _tapText(tester, 'Şimdi kontrol et');
      expect(_sent('POST', '/v1/security/attacks/run'), hasLength(1));
      expect(find.text('Kontrol edildi: 1 yeni kaynak, 0 engellendi'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('Cloudflare bağlı değilse açıklama ve ayar bağlantısı; kontrol hatası metni', (tester) async {
      FakeAgent.securityMore.attacksConfigured = false;
      await _Env().h.pump(tester, route: '/security/attacks?host=atlas');
      await _load(tester);
      expect(find.textContaining('Cloudflare bağlı değil'), findsWidgets);
      await _tapText(tester, 'Cloudflare ayarları');
      expect(find.textContaining('Zone Analytics Read + Zone Read'), findsOneWidget);
      expect(find.textContaining('Zone Firewall Services Edit'), findsOneWidget);
      await _finish(tester);

      FakeAgent.securityMore.attacksConfigured = true;
      FakeAgent.securityMore.errors['POST /v1/security/attacks/run'] = const AgentError('agent.security.cloudflareUnauthorized', {}, 502);
      await _Env().h.pump(tester, route: '/security/attacks?host=atlas');
      _tall(tester, 2200);
      await _load(tester);
      await _tapText(tester, 'Şimdi kontrol et');
      expect(find.textContaining('Cloudflare belirteci kabul etmedi'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('Cloudflare ayarları: belirteçler yazılır (geri gelmez), engelleme uyarı ile, null ile kaldırma', (tester) async {
      await _Env().h.pump(tester, route: '/security/cloudflare?host=atlas');
      _tall(tester, 3000);
      await _load(tester);
      expect(find.textContaining('Zone Analytics Read + Zone Read'), findsOneWidget);
      expect(find.text('example.org'), findsOneWidget);
      expect(find.text('198.51.100.7'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, 'Engelleme belirteci'), 'cf_blocktoken_example');
      await _tap(tester, find.widgetWithText(FilledButton, 'Kaydet').first);
      expect(_sent('PUT', '/v1/security/cloudflare').single.$3, {'blockToken': 'cf_blocktoken_example'});
      expect(find.text('cf_blocktoken_example'), findsNothing);
      expect(find.textContaining('anlış bir engel'), findsOneWidget, reason: 'engelleme uyarısı');

      await tester.tap(find.byType(Switch).first);
      await _load(tester);
      expect(find.textContaining('24 saat engellenecek'), findsOneWidget);
      await _dialogButton(tester, 'Aç');
      expect(_sent('PUT', '/v1/security/cloudflare').last.$3, {'block': true});

      await _tapText(tester, 'Okuma belirtecini kaldır');
      await _dialogButton(tester, 'Belirteci kaldır');
      expect(_sent('PUT', '/v1/security/cloudflare').last.$3, {'readToken': null});
      await _finish(tester);
    });
  });

  group('kara kutu', () {
    testWidgets('durum ve son kayıtlar; zinciri doğrula: sağlam', (tester) async {
      await _Env().h.pump(tester, route: '/security/blackbox?host=atlas');
      _tall(tester, 2500);
      await _load(tester);
      expect(find.text('Burada tut'), findsWidgets);
      expect(find.textContaining('3 kayıt · son f00dfeedc0de1234'), findsOneWidget);
      expect(find.text('POST /v1/security/vulns/scan'), findsOneWidget);
      expect(find.text('security.change'), findsOneWidget);
      expect(find.text('recoveryCodeCreated'), findsOneWidget);
      await _tapText(tester, 'Zinciri doğrula');
      expect(_sent('GET', '/v1/blackbox/verify'), hasLength(1));
      expect(find.text('Zincir sağlam'), findsOneWidget);
      expect(find.textContaining('3 kayıt denetlendi'), findsOneWidget);
      expect(find.textContaining('2026-11-13 · 2 kayıt · ab12cd34ef56'), findsOneWidget);
      await golden('png/security_blackbox_ok_light_tr.png');
      await _finish(tester);
    });

    testWidgets('zinciri doğrula: bozuk (kayıt no ve neden) ve çapa uyuşmazlığı', (tester) async {
      FakeAgent.securityMore.bbVerify = {'ok': false, 'count': 1, 'head': 'aa', 'brokenAt': 2, 'reason': 'hash', 'anchors': FakeAgent.securityMore.bbAnchors, 'anchorMismatch': ['2026-11-12']};
      await _Env().h.pump(tester, route: '/security/blackbox?host=atlas');
      _tall(tester, 2600);
      await _load(tester);
      await _tapText(tester, 'Zinciri doğrula');
      expect(find.text('Zincir bozuk'), findsOneWidget);
      expect(find.text('2. kayıtta bozuk'), findsOneWidget);
      expect(find.text('Bir kaydın içeriği özetiyle uyuşmuyor.'), findsOneWidget);
      expect(find.textContaining('çapaları artık zincirde yok: 2026-11-12'), findsOneWidget);
      await golden('png/security_blackbox_broken_light_tr.png');
      await _finish(tester);

      FakeAgent.securityMore.bbVerify = {'ok': true, 'count': 3, 'head': 'aa', 'brokenAt': null, 'reason': null, 'anchors': FakeAgent.securityMore.bbAnchors, 'anchorMismatch': ['2026-11-12']};
      await _Env().h.pump(tester, route: '/security/blackbox?host=atlas');
      _tall(tester, 2600);
      await _load(tester);
      await _tapText(tester, 'Zinciri doğrula');
      expect(find.text('Zincir çapalarıyla uyuşmuyor'), findsOneWidget, reason: 'sağlam görünse de çapa uyuşmazlığı güvenilir değildir');
      await _finish(tester);
    });

    testWidgets('bugünün çapası POST; ayar PUT ve yeniden başlatma uyarısı; push modu durumu; yerel değilse açıklama', (tester) async {
      await _Env().h.pump(tester, route: '/security/blackbox?host=atlas');
      _tall(tester, 2600);
      await _load(tester);
      await _tapText(tester, 'Zinciri doğrula');
      await _tapText(tester, 'Bugünün çapasını gönder');
      expect(_sent('POST', '/v1/blackbox/anchor'), hasLength(1));
      expect(find.text('Çapa kaydedildi'), findsOneWidget);
      expect(find.textContaining('2026-11-14 · 3 kayıt'), findsOneWidget);
      await _tapText(tester, 'Sunucuya gönder');
      await tester.enterText(find.widgetWithText(TextFormField, 'Sunucu adresi'), 'https://atlas.example.org:6767');
      await tester.enterText(find.widgetWithText(TextFormField, 'Belirteç'), 'tps_blackboxTokenExample0123456789');
      await _tap(tester, find.widgetWithText(FilledButton, 'Kaydet'));
      expect(_sent('PUT', '/v1/blackbox/settings').single.$3, {'mode': 'push', 'url': 'https://atlas.example.org:6767', 'token': 'tps_blackboxTokenExample0123456789'});
      expect(find.textContaining('Değişikliğin geçerli olması için ajanı yeniden başlat'), findsOneWidget);
      await _finish(tester);

      FakeAgent.securityMore.bbMode = 'push';
      await _Env().h.pump(tester, route: '/security/blackbox?host=atlas');
      _tall(tester, 2600);
      await _load(tester);
      expect(find.text('4 kayıt gönderilmeyi bekliyor'), findsOneWidget);
      expect(find.textContaining('Son gönderim 40 dk önce'), findsOneWidget);
      expect(find.text('Zinciri doğrula'), findsNothing);
      await _finish(tester);

      FakeAgent.securityMore.bbMode = 'off';
      await _Env().h.pump(tester, route: '/security/blackbox?host=atlas');
      await _load(tester);
      expect(find.textContaining('Kara kutu kapalı'), findsWidgets);
      expect(find.text('Zinciri doğrula'), findsNothing);
      await _finish(tester);
    });

    testWidgets('push için adres ve belirteç doğrulanır (https, tps_)', (tester) async {
      await _Env().h.pump(tester, route: '/security/blackbox?host=atlas');
      _tall(tester, 2600);
      await _load(tester);
      await _tapText(tester, 'Sunucuya gönder');
      await tester.enterText(find.widgetWithText(TextFormField, 'Sunucu adresi'), 'http://atlas.example.org');
      await _tap(tester, find.widgetWithText(FilledButton, 'Kaydet'));
      expect(_sent('PUT', '/v1/blackbox/settings'), isEmpty);
      expect(find.text('Geçersiz değer'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('telefon kaybı', () {
    testWidgets('kod oluşturma: onay, uygulama kilidi, bir kez gösterim, FLAG_SECURE, kopyalama yok', (tester) async {
      final env = _Env();
      await env.h.pump(tester, route: '/security/recovery?host=atlas');
      _tall(tester, 2500);
      await _load(tester);
      expect(find.textContaining('kurtarma kodu var'), findsOneWidget);
      expect(find.text('orion'), findsOneWidget);
      await _tapText(tester, 'Yeni kod oluştur');
      expect(find.textContaining('Eski kod hemen geçersiz olur'), findsOneWidget);
      await _dialogButton(tester, 'Kurtarma kodu oluştur');
      expect(env.auths, 1, reason: 'uygulama kilidi soruldu');
      expect(_sent('POST', '/v1/security/recovery').single.$3, {'confirm': true});
      expect(find.text('ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2'), findsOneWidget);
      expect(find.textContaining('Gösterildiği gibi kâğıda yaz'), findsOneWidget);
      expect(find.text('Kopyala'), findsNothing, reason: 'kod kâğıda yazılır: kopyalama düğmesi yok');
      expect(env.secure, [true]);
      await golden('png/security_recovery_code_light_tr.png');
      await _tapText(tester, 'Sakladım, kapat');
      expect(find.text('ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2'), findsNothing);
      expect(env.secure, [true, false]);
      expect(env.native.copied, isEmpty);
      await _finish(tester);
    });

    testWidgets('kilit yoksa veya doğrulama iptal edilirse kod oluşturulmaz', (tester) async {
      final noLock = _Env(lock: false);
      await noLock.h.pump(tester, route: '/security/recovery?host=atlas');
      _tall(tester, 2500);
      await _load(tester);
      await _tapText(tester, 'Yeni kod oluştur');
      await _dialogButton(tester, 'Kurtarma kodu oluştur');
      expect(find.textContaining('PIN veya parmak izi kilidi kur'), findsOneWidget);
      expect(noLock.auths, 0);
      expect(_sent('POST', '/v1/security/recovery'), isEmpty);
      await _finish(tester);

      final cancelled = _Env(authOk: false);
      await cancelled.h.pump(tester, route: '/security/recovery?host=atlas');
      _tall(tester, 2500);
      await _load(tester);
      await _tapText(tester, 'Yeni kod oluştur');
      await _dialogButton(tester, 'Kurtarma kodu oluştur');
      expect(cancelled.auths, 1);
      expect(_sent('POST', '/v1/security/recovery'), isEmpty);
      expect(cancelled.secure, isEmpty);
      await _finish(tester);
    });

    testWidgets('kilitleme hedefleri: ekle (belirteç yazılır), sil; doğrulama', (tester) async {
      await _Env().h.pump(tester, route: '/security/recovery?host=atlas');
      _tall(tester, 2500);
      await _load(tester);
      expect(find.textContaining('belirteç kayıtlı'), findsOneWidget);
      await _tapText(tester, 'Ajan ekle');
      await _dialogField(tester, 0, 'Bad Id');
      await _dialogField(tester, 3, 'short');
      await _dialogButton(tester, 'Ekle');
      expect(_sent('POST', '/v1/security/lockdown/targets'), isEmpty);
      await _dialogField(tester, 0, 'nova');
      await _dialogField(tester, 1, 'nova');
      await _dialogField(tester, 2, 'https://nova.example.org:6767');
      await _dialogField(tester, 3, 'tps_lockdownTokenExample0123456789');
      await _dialogButton(tester, 'Ekle');
      expect(_sent('POST', '/v1/security/lockdown/targets').single.$3, {'id': 'nova', 'name': 'nova', 'url': 'https://nova.example.org:6767', 'token': 'tps_lockdownTokenExample0123456789'});
      expect(find.textContaining('tps_lockdown'), findsNothing);
      await tester.tap(find.byTooltip('orion ajanını kaldır'));
      await _load(tester);
      await _dialogButton(tester, 'Sil');
      expect(_sent('DELETE', '/v1/security/lockdown/targets/orion'), hasLength(1));
      await _finish(tester);
    });
  });

  group('kurtarma koduyla kilitle', () {
    testWidgets('yalnız https; ekran FLAG_SECURE', (tester) async {
      final env = _Env();
      await env.h.pump(tester, route: '/security/lockdown?host=atlas');
      _tall(tester, 1500);
      await _load(tester);
      expect(env.secure, [true], reason: 'kod yazılan ekran');
      await tester.enterText(find.widgetWithText(TextFormField, 'https://atlas.example.ts.net:7443'), 'http://atlas.example.ts.net:7443');
      await tester.enterText(find.widgetWithText(TextFormField, 'Kurtarma kodu'), 'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2');
      await _tap(tester, find.widgetWithText(FilledButton, 'Her şeyi kilitle'));
      expect(find.text('Kurtarma kodu yalnız https adresine gönderilir.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(env.lockdownCalls, isEmpty);
      await _finish(tester);
    });

    testWidgets('adres ajan profilinden gelir; güçlü uyarı; onay olmadan gönderilmez; belirteçsiz çağrı; sonuçlar', (tester) async {
      final env = _Env();
      await env.h.pump(tester, route: '/security/lockdown?host=atlas');
      _tall(tester, 1500);
      await _load(tester);
      expect(find.text('Bu her şeyi kilitler'), findsOneWidget);
      expect(find.textContaining('Geri alınamaz'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'https://atlas.example.ts.net:7443'), findsOneWidget, reason: 'ajan profilinden');
      await tester.enterText(find.widgetWithText(TextFormField, 'Kurtarma kodu'), 'abcde fghjk lmnpq rstuv wxyz2');
      await tester.pump();
      await golden('png/security_lockdown_light_tr.png');
      await _tap(tester, find.widgetWithText(FilledButton, 'Her şeyi kilitle'));
      expect(find.textContaining('Her şey şimdi kilitlensin mi?'), findsOneWidget);
      await _dialogButton(tester, 'Vazgeç');
      expect(env.lockdownCalls, isEmpty, reason: 'onaysız gönderilmez');
      await _tap(tester, find.widgetWithText(FilledButton, 'Her şeyi kilitle'));
      await _dialogButton(tester, 'Her şeyi kilitle');
      expect(env.lockdownCalls.single, ('https://atlas.example.ts.net:7443', 'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2'));
      expect(FakeAgent.calls.where((c) => c.$2.contains('lockdown')), isEmpty, reason: 'agent istemcisi (belirteçli) kullanılmadı');
      expect(find.text('Her şey kilitlendi'), findsOneWidget);
      expect(find.textContaining('yeniden eşleş'), findsOneWidget);
      expect(find.text('Kilitlendi'), findsOneWidget);
      expect(find.textContaining('Ulaşılamadı'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('eksik kod doğrulanır; yanlış kod ve hız sınırı hata metinleri; 375 px', (tester) async {
      final env = _Env();
      await env.h.pump(tester, route: '/security/lockdown?host=atlas');
      _tall(tester, 1500, 375);
      await _load(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Kurtarma kodu'), 'ABCDE-FGHJK');
      await _tap(tester, find.widgetWithText(FilledButton, 'Her şeyi kilitle'));
      expect(find.text('Kod 25 harf ve rakamdan oluşur.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      env.lockdownError = const AgentError('agent.security.badRecoveryCode', {}, 401);
      await tester.enterText(find.widgetWithText(TextFormField, 'Kurtarma kodu'), 'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2');
      await _tap(tester, find.widgetWithText(FilledButton, 'Her şeyi kilitle'));
      await _dialogButton(tester, 'Her şeyi kilitle');
      expect(find.text('Kurtarma kodu yanlış.'), findsOneWidget);
      expect(find.text('Her şey kilitlendi'), findsNothing);
      expect(tester.widgetList<EditableText>(find.byType(EditableText)).any((e) => e.controller.text.contains('ABCDE')), isFalse, reason: 'kod çağrıdan sonra tutulmaz');
      env.lockdownError = const AgentError('agent.security.rateLimited', {}, 429);
      await tester.enterText(find.widgetWithText(TextFormField, 'Kurtarma kodu'), 'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2');
      await _tap(tester, find.widgetWithText(FilledButton, 'Her şeyi kilitle'));
      await _dialogButton(tester, 'Her şeyi kilitle');
      expect(find.textContaining('Çok sık'), findsOneWidget);
      await _finish(tester);
    });
  });
}
