// Security center: overview, host screen (normal, with changes, with an error), confirm dialog, rate limit, settings,
// the incident button, the System / Home entries. Machine names are examples (argo, atlas, orion).
// To update: TZ=Europe/Berlin flutter test test/goldens/security_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';

import 'package:tiphys/features/system/events.dart' show ChipRow;

import '../helpers/harness.dart';

Harness _env({bool feature = true}) => Harness(agentFeatures: [...Harness.defaultAgentFeatures, if (feature) 'security', 'incidents']);

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

/// Opens a tab of the host screen (the chip row is a horizontal list: scroll to it first).
Future<void> _tab(WidgetTester tester, String label) async {
  final row = find.byType(ChipRow);
  final chip = find.descendant(of: row, matching: find.text(label));
  await tester.scrollUntilVisible(chip, 80, scrollable: find.descendant(of: row, matching: find.byType(Scrollable)).first);
  await tester.tap(chip);
  await _load(tester);
}

const _orion = '/security/orion?host=argo';

void main() {
  setUp(() {
    FakeAgent.resetSecurity();
    FakeAgent.resetIncidents();
    FakeAgent.calls.clear();
  });

  testWidgets('liste TR: puan rozetleri, çipler, değişiklik çipi, ajan başlıkları', (tester) async {
    await _env().pump(tester, route: '/security');
    _tall(tester, 1100);
    await _load(tester);
    expect(find.text('Güvenlik merkezi'), findsOneWidget);
    expect(find.text('52'), findsOneWidget);
    expect(find.text('91'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('2 değişiklik'), findsOneWidget);
    expect(find.text('1 Kritik'), findsOneWidget);
    expect(find.text('1 Yüksek'), findsOneWidget);
    expect(find.text('ARGO (PC)'), findsOneWidget, reason: 'ajan başlığı');
    expect(find.bySemanticsLabel(RegExp('Güvenlik puanı 52 / 100')), findsWidgets);
    await golden('png/security_overview_light_tr.png');
    await _finish(tester);
  });

  testWidgets('liste: bayat durum, hata kodu, çalışan denetim ve puansız makine', (tester) async {
    final st = FakeAgent.security;
    final o = st.find('argo', 'orion')!;
    o.stale = true;
    o.lastOkAgo = const Duration(hours: 7);
    o.lastError = {'code': 'agent.security.sshFailed', 'at': '2026-11-14T10:00:00Z'};
    st.find('argo', 'self')!
      ..running = true
      ..score = null
      ..lastOkAgo = null;
    st.overviewErrors['atlas'] = const AgentError('net.unreachable');
    await _env().pump(tester, route: '/security');
    _tall(tester, 1100);
    await _load(tester);
    expect(find.textContaining('Son bilinen durum · 7 sa'), findsWidgets);
    expect(find.textContaining('SSH bağlantısı kurulamadı'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('atlas için güvenlik verisi alınamadı'), findsOneWidget);
    await golden('png/security_overview_stale_light_tr.png');
    await _finish(tester);
  });

  testWidgets('liste: özellik yoksa açıklama; sistem ekranında satır yalnız özellik varsa; ana ekranda kart yalnız değişiklik varken', (tester) async {
    await _env(feature: false).pump(tester, route: '/security');
    await _load(tester);
    expect(find.textContaining('features.security'), findsOneWidget);
    await _finish(tester);

    await _env(feature: false).pump(tester, route: '/system');
    await _load(tester);
    await tester.scrollUntilVisible(find.text('Olay odası'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Güvenlik'), findsNothing);
    await _finish(tester);

    await _env().pump(tester, route: '/system');
    await _load(tester);
    await tester.scrollUntilVisible(find.text('Güvenlik'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Güvenlik'), findsOneWidget);
    await _finish(tester);

    await _env().pump(tester);
    await _load(tester);
    expect(find.textContaining('2 değişiklik onay bekliyor'), findsNothing, reason: 'kritik bulgu da var: ikisi birlikte');
    expect(find.textContaining('değişiklik · 1 kritik bulgu'), findsOneWidget);
    await _finish(tester);

    FakeAgent.security.find('argo', 'orion')!
      ..changes = []
      ..findings = [];
    await _env().pump(tester);
    await _load(tester);
    expect(find.textContaining('değişiklik'), findsNothing);
    expect(find.textContaining('kritik bulgu'), findsNothing);
    await _finish(tester);
  });

  testWidgets('ayrıntı TR: bulgular önem sırasıyla, bilinmeyen kural kimliğiyle, çıkarılmış değişiklikler', (tester) async {
    await _env().pump(tester, route: _orion);
    _tall(tester, 2600);
    await _load(tester);
    expect(find.text('Boş parolalı hesap: kiosk'), findsOneWidget);
    expect(find.text('SSH parola ile girişe açık'), findsOneWidget);
    expect(find.text('Dışarıya açık port: tcp/2222'), findsOneWidget);
    expect(find.text('some.futureRule'), findsOneWidget);
    expect(find.textContaining('Öneri:'), findsWidgets);
    expect(find.text('Değişiklikler · 2'), findsOneWidget);
    expect(find.text('Bu durumu kabul et'), findsOneWidget);
    expect(find.text('Şimdi denetle'), findsOneWidget);
    expect(find.text('tcp/2222'), findsWidgets);
    expect(find.text('dışarıya açık'), findsWidgets);
    await golden('png/security_detail_changes_light_tr.png');
    await _finish(tester);
  });

  testWidgets('ayrıntı TR: değişiklik yok, bulgu yok', (tester) async {
    await _env().pump(tester, route: '/security/self?host=atlas');
    _tall(tester, 1500);
    await _load(tester);
    expect(find.text('Bulgu yok; bu denetimde bir sorun görünmüyor.'), findsOneWidget);
    expect(find.textContaining('Değişiklikler'), findsNothing);
    expect(find.text('100'), findsOneWidget);
    await golden('png/security_detail_normal_light_tr.png');
    await _finish(tester);
  });

  testWidgets('ayrıntı TR: son denetim hatalı; bayat durum ve hata metni; rapor yoksa açıklama', (tester) async {
    final o = FakeAgent.security.find('argo', 'orion')!;
    o.stale = true;
    o.lastOkAgo = const Duration(hours: 8);
    o.lastError = {'code': 'agent.security.unreachable', 'at': '2026-11-14T10:00:00Z'};
    await _env().pump(tester, route: _orion);
    _tall(tester, 1700);
    await _load(tester);
    expect(find.textContaining('Son bilinen durum · 8 sa'), findsOneWidget);
    expect(find.text('Makineye ulaşılamıyor.'), findsOneWidget);
    await golden('png/security_detail_error_light_tr.png');
    await _finish(tester);

    o.report = null;
    o.score = null;
    o.findings = [];
    o.changes = [];
    o.lastOkAgo = null;
    await _env().pump(tester, route: _orion);
    await _load(tester);
    expect(find.textContaining('henüz rapor yok'), findsOneWidget);
    expect(find.text('Henüz denetlenmedi'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('ayrıntı: yükleme ve hata durumları, makine bulunamadı', (tester) async {
    await _env().pump(tester, route: '/security/unknown-host?host=argo');
    await _load(tester);
    expect(find.textContaining('Bu makine hiçbir ajanda bulunamadı: unknown-host'), findsOneWidget);
    expect(find.text('Tekrar dene'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('kimlik iki ajanda da varsa hangisi sorulur; ad ile açılır; ajan ipucu yeter', (tester) async {
    await _env().pump(tester, route: '/security/self');
    await _load(tester);
    expect(find.text('argo (PC)'), findsOneWidget);
    expect(find.text('atlas'), findsOneWidget);
    await tester.tap(find.text('atlas'));
    await _load(tester);
    expect(find.text('100'), findsOneWidget);
    await _finish(tester);

    // The incident room links by the audited host's display name.
    await _env().pump(tester, route: '/security/ORION?host=argo');
    await _load(tester);
    expect(find.text('Boş parolalı hesap: kiosk'), findsOneWidget);
    await _finish(tester);

    await _env().pump(tester, route: '/security/orion');
    await _load(tester);
    expect(find.text('Boş parolalı hesap: kiosk'), findsOneWidget, reason: 'yalnız bir ajanda var');
    await _finish(tester);
  });

  testWidgets('sekmeler: portlar, SSH, kullanıcılar, işler, güncellemeler, konteynerler, sistem', (tester) async {
    await _env().pump(tester, route: _orion);
    _tall(tester, 3200);
    await _load(tester);
    expect(find.text('0.0.0.0'), findsWidgets);
    expect(find.text('Tailscale'), findsOneWidget);
    expect(find.text('dinliyor, güvenlik duvarı engelliyor'), findsOneWidget);
    expect(find.text('Gelen bağlantılara varsayılan olarak izin veriliyor'), findsOneWidget);
    expect(find.text('yerel'), findsOneWidget);
    await _tab(tester, 'SSH');
    expect(find.text('passwordauthentication'), findsOneWidget);
    expect(find.text('alice, deploy'), findsOneWidget);
    await _tab(tester, 'Kullanıcılar');
    expect(find.text('boş parola'), findsOneWidget);
    expect(find.textContaining('SHA256:EXAMPLE'), findsWidgets);
    await _tab(tester, 'Zamanlanmış işler');
    expect(find.text('/etc/cron.d/example-backup'), findsOneWidget);
    expect(find.textContaining('apt-daily.timer'), findsOneWidget);
    await _tab(tester, 'Güncellemeler');
    expect(find.text('Yeniden başlatma gerekiyor'), findsWidgets);
    await _tab(tester, 'Konteynerler');
    expect(find.text('ayrıcalıklı'), findsOneWidget);
    expect(find.text('docker.sock'), findsOneWidget);
    expect(find.text('example-web'), findsOneWidget);
    await _tab(tester, 'Sistem');
    expect(find.text('/usr/bin/sudo', skipOffstage: false), findsNothing);
    expect(find.textContaining('4755 root /usr/bin/sudo'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('root olmayan denetim: alınamayan bölümler "root gerektirir" der; 375 px', (tester) async {
    await _env().pump(tester, route: '/security/self?host=argo');
    _tall(tester, 3000, 375);
    await _load(tester);
    await _tab(tester, 'Kullanıcılar');
    expect(find.textContaining('root gerektirir'), findsWidgets);
    await _tab(tester, 'Sistem');
    expect(find.textContaining('Bu denetimde alınamadı (root gerektirir): Parola durumu, Sudoers dosyaları, Otomatik başlatma'), findsOneWidget);
    expect(find.text('Yalnız tam denetimde taranır.'), findsWidgets);
    await _finish(tester);
  });

  testWidgets('uzun adlar ve yollar taşmaz (375 px)', (tester) async {
    final o = FakeAgent.security.find('argo', 'orion')!;
    o.name = 'orion-${'uzun-ad-' * 12}';
    o.changes.first['item'] = '/very/long/path/${'segment/' * 30}file';
    o.findings.add({'id': 'files.agentPerms:x', 'rule': 'files.agentPerms', 'severity': 'medium', 'params': {'path': '/home/alice/${'deep/' * 30}agent.json', 'mode': '644'}});
    await _env().pump(tester, route: _orion);
    _tall(tester, 2600, 375);
    await _load(tester);
    expect(tester.takeException(), isNull);
    await _finish(tester);
    await _env().pump(tester, route: '/security');
    _tall(tester, 1200, 375);
    await _load(tester);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('kabul et: onay penceresi, çift dokunuşa karşı koruma, yalnız bir istek', (tester) async {
    await _env().pump(tester, route: _orion);
    _tall(tester, 2600);
    await _load(tester);
    await _tap(tester, find.text('Bu durumu kabul et'));
    expect(find.text('Bu durum kabul edilsin mi?'), findsOneWidget);
    expect(find.textContaining('2 değişiklik listeden kalkar'), findsOneWidget);
    // Cancel: nothing is sent.
    await tester.tap(find.text('Vazgeç'));
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$2.endsWith('/baseline')), isEmpty);
    await _tap(tester, find.text('Bu durumu kabul et'));
    final confirm = find.descendant(of: find.byType(AlertDialog), matching: find.text('Bu durumu kabul et'));
    await tester.tap(confirm);
    await tester.tap(confirm, warnIfMissed: false);
    await _load(tester);
    final sent = FakeAgent.calls.where((c) => c.$2 == '/v1/security/hosts/orion/baseline').toList();
    expect(sent, hasLength(1));
    expect(sent.single.$1, 'POST');
    expect(sent.single.$3, {'confirm': true});
    expect(find.textContaining('Durum kabul edildi (2 değişiklik)'), findsOneWidget);
    expect(find.textContaining('Değişiklikler ·'), findsNothing);
    await _finish(tester);
  });

  testWidgets('şimdi denetle ve tam denetim: gövde, başarı iletisi', (tester) async {
    await _env().pump(tester, route: _orion);
    _tall(tester, 2600);
    await _load(tester);
    await _tap(tester, find.text('Şimdi denetle'));
    expect(FakeAgent.calls.where((c) => c.$2 == '/v1/security/hosts/orion/check').single.$3, {'full': false});
    expect(find.text('Denetim tamamlandı'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await settle(tester);
    await tester.tap(find.text('Tam denetim'));
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$2 == '/v1/security/hosts/orion/check').last.$3, {'full': true});
    await _finish(tester);
  });

  testWidgets('429: çok sık denetim iletisi, ekran bozulmaz', (tester) async {
    FakeAgent.security.checkError = const AgentError('agent.security.rateLimited', {}, 429);
    await _env().pump(tester, route: _orion);
    _tall(tester, 2600);
    await _load(tester);
    await _tap(tester, find.text('Şimdi denetle'));
    expect(find.textContaining('Çok sık denetim istendi'), findsOneWidget);
    expect(find.text('Şimdi denetle'), findsOneWidget, reason: 'düğme yeniden etkin');
    await _finish(tester);
  });

  testWidgets('denetim hatası: ajanın hata kodu metne çevrilir', (tester) async {
    FakeAgent.security.checkError = const AgentError('agent.security.timeout', {}, 504);
    await _env().pump(tester, route: _orion);
    _tall(tester, 2600);
    await _load(tester);
    await _tap(tester, find.text('Şimdi denetle'));
    expect(find.text('Denetim zaman aşımına uğradı.'), findsWidgets);
    await _finish(tester);
  });

  testWidgets('olay odası: güvenlik olayında "Güvenlik ekranını aç" düğmesi ana makineyi açar', (tester) async {
    final inc = Map<String, dynamic>.from(FakeAgent.incidents['argo']!.first);
    inc
      ..['kind'] = 'security.change'
      ..['target'] = 'orion'
      ..['status'] = 'open'
      ..['signals'] = [
        {'at': '2026-11-14T13:00:00Z', 'key': 'security.change', 'params': {'host': 'orion', 'hostId': 'orion', 'count': 2}},
      ];
    FakeAgent.incidents['argo'] = [inc];
    await _env().pump(tester, route: '/incidents/${inc['id']}?host=argo');
    _tall(tester, 2000);
    await _load(tester);
    expect(find.textContaining('Güvenlik değişikliği: orion'), findsWidgets);
    await _tap(tester, find.text('Güvenlik ekranını aç'));
    expect(find.text('Boş parolalı hesap: kiosk'), findsOneWidget);
    expect(FakeAgent.calls.where((c) => c.$2 == '/v1/security/hosts/orion'), isNotEmpty);
    await _finish(tester);

    // Without a hostId in the signals the incident's target (the name) is resolved through the overview.
    inc['signals'] = [
      {'at': '2026-11-14T13:00:00Z', 'key': 'security.change', 'params': {'host': 'orion'}},
    ];
    inc['target'] = 'Orion';
    FakeAgent.calls.clear();
    await _env().pump(tester, route: '/incidents/${inc['id']}?host=argo');
    _tall(tester, 2000);
    await _load(tester);
    await _tap(tester, find.text('Güvenlik ekranını aç'));
    expect(find.text('Boş parolalı hesap: kiosk'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('ayarlar: bu makine, beklenen portlar, sudo onayı, makine listesi', (tester) async {
    await _env().pump(tester, route: '/security/settings');
    _tall(tester, 2200);
    await _load(tester);
    expect(find.text('Denetim ayarları'), findsOneWidget);
    expect(find.text('tcp/22'), findsWidgets);
    expect(find.text('orion'), findsOneWidget);
    await golden('png/security_settings_light_tr.png');
    // Invalid port: error, nothing sent.
    await _tap(tester, find.text('Port ekle').first);
    await tester.enterText(find.byType(TextField), 'tcp/99999');
    await tester.tap(find.text('Ekle'));
    await settle(tester);
    expect(find.textContaining('tcp/22 ya da udp/53 biçiminde'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'udp/53');
    await tester.tap(find.text('Ekle'));
    await _load(tester);
    final first = FakeAgent.calls.firstWhere((c) => c.$1 == 'PATCH');
    expect(first.$2, '/v1/security/hosts/self');
    expect(first.$3, {'allowedPorts': ['udp/53']});
    expect(FakeAgent.security.selfSettings['argo']!['allowedPorts'], ['udp/53']);
    // sudo: asks first.
    await _tap(tester, find.text('sudo ile denetle'));
    expect(find.textContaining('root yetkisiyle çalışacak'), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await _load(tester);
    expect(FakeAgent.security.selfSettings['argo']!['sudo'], false);
    await _tap(tester, find.text('sudo ile denetle'));
    await tester.tap(find.text('Onayla'));
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$1 == 'PATCH').last.$3, {'sudo': true});
    await _finish(tester);
  });

  testWidgets('ayarlar: ajan kaynağı eklemek belirteç ister; belirteç alanı gizli; düzenleyince "değiştirmek için yaz"', (tester) async {
    await _env().pump(tester, route: '/security/settings');
    _tall(tester, 2400);
    await _load(tester);
    await _tap(tester, find.text('Makine ekle').first);
    await tester.enterText(find.widgetWithText(TextFormField, 'Kimlik'), 'orion2');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ad'), 'orion2');
    await tester.tap(find.text('Ajan ile'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Ajan adresi (https)'), 'https://orion2.example.org');
    final token = find.widgetWithText(TextFormField, 'Belirteç');
    expect(tester.widget<EditableText>(find.descendant(of: token, matching: find.byType(EditableText))).obscureText, isTrue);
    await tester.tap(find.text('Kaydet').last);
    await settle(tester);
    expect(find.text('Ajan kaynağı için belirteç gerekli.'), findsWidgets);
    expect(FakeAgent.calls.where((c) => c.$1 == 'POST'), isEmpty);
    await tester.enterText(token, 'tps_EXAMPLEEXAMPLEEXAMPLE0001');
    await tester.tap(find.text('Kaydet').last);
    await _load(tester);
    final post = FakeAgent.calls.firstWhere((c) => c.$1 == 'POST');
    expect(post.$2, '/v1/security/hosts');
    expect((post.$3! as Map)['source'], {'kind': 'agent', 'url': 'https://orion2.example.org', 'token': 'tps_EXAMPLEEXAMPLEEXAMPLE0001'});
    expect(FakeAgent.security.find('argo', 'orion2'), isNotNull);
    expect(find.text('orion2'), findsOneWidget);
    await _finish(tester);

    // Edit the agent source: the token is kept when the URL is unchanged, so it is not sent.
    await _env().pump(tester, route: '/security/settings');
    _tall(tester, 2400);
    await _load(tester);
    FakeAgent.security.find('argo', 'orion')!.sourceConfig = {'kind': 'agent', 'url': 'https://orion.example.org', 'token': 'x'};
    await tester.pumpWidget(const SizedBox());
    await _env().pump(tester, route: '/security/settings');
    _tall(tester, 2400);
    await _load(tester);
    await _tap(tester, find.text('orion'));
    expect(find.text('değiştirmek için yaz'), findsOneWidget);
    await tester.tap(find.text('Kaydet').last);
    await _load(tester);
    final patch = FakeAgent.calls.lastWhere((c) => c.$1 == 'PATCH');
    expect((patch.$3! as Map)['source'], {'kind': 'agent', 'url': 'https://orion.example.org'});
    await _finish(tester);
  });

  testWidgets('ayarlar: makineyi silmek onay ister', (tester) async {
    await _env().pump(tester, route: '/security/settings');
    _tall(tester, 2400);
    await _load(tester);
    await _tap(tester, find.text('orion'));
    await _tap(tester, find.text('Makineyi sil'));
    expect(find.textContaining('orion denetim listesinden silinsin mi?'), findsOneWidget);
    await tester.tap(find.text('Sil'));
    await _load(tester);
    expect(FakeAgent.calls.where((c) => c.$1 == 'DELETE').single.$2, '/v1/security/hosts/orion');
    expect(FakeAgent.security.find('argo', 'orion'), isNull);
    await _finish(tester);
  });
}
