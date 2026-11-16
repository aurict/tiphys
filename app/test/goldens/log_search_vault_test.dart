// 9.10 Cross-server log search (fake SSH shell) and 9.11 password vault (in-memory vault, fake clipboard/window).
// All data is synthetic. To update: flutter test test/goldens/log_search_vault_test.dart --update-goldens
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/security/app_lock.dart';
import 'package:tiphys/core/vault/sensitive_clipboard.dart';
import 'package:tiphys/core/vault/vault.dart';
import 'package:tiphys/features/system/log_search.dart';
import 'package:tiphys/features/vault/vault_import.dart';
import 'package:tiphys/features/vault/vault_state.dart';

import '../core/vault_test.dart' show FakeNative, FakeTimers, fixture;
import '../helpers/fake_shell.dart';
import '../helpers/harness.dart';

Future<void> _wait(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
}

// ── Log arama ───────────────────────────────────────────────────────────────

String _jl(String cursor, int min, int sec, String msg, {String? unit, String? ident, int prio = 6}) => jsonEncode({
      '__CURSOR': cursor,
      '__REALTIME_TIMESTAMP': '${DateTime(2026, 11, 14, 13, min, sec).microsecondsSinceEpoch}',
      'MESSAGE': msg,
      'PRIORITY': '$prio',
      '_SYSTEMD_UNIT': ?unit,
      'SYSLOG_IDENTIFIER': ?ident,
    });

String _dl(String c, int min, int sec, String msg) => '@@d $c ${DateTime(2026, 11, 14, 13, min, sec).toUtc().toIso8601String()} $msg';

/// Synthetic search output per host (search for "timeout").
final _outputs = {
  'argo': [
    '@@j system',
    '@@j user',
    _jl('a1', 58, 12, 'tiphys-agent: upstream timeout after 30000 ms (GET /v1/system)', unit: 'tiphys-agent.service'),
    '@@useronly',
    _dl('homepage', 59, 40, 'Error: connect ETIMEDOUT 10.0.0.12:443 (Timeout while fetching widget)'),
  ].join('\n'),
  'atlas': [
    '@@j system',
    _jl('b1', 59, 58, 'nginx: upstream timed out (110: Connection timed out) — timeout reached', unit: 'nginx.service', prio: 3),
    _jl('b2', 57, 3, 'sshd: Timeout before authentication for 100.64.0.9 port 51544', ident: 'sshd'),
    '@@j user',
    _dl('grafana', 58, 31, 'level=warn msg="Query timeout" datasource=prometheus duration=30s'),
    _dl('uptime-kuma', 56, 2, '[MONITOR] WARN: Pinging https://example.com timeout 48s'),
  ].join('\n'),
};

Harness _logs({Map<String, String>? outputs, Set<String> failing = const {}}) => Harness(extra: [
      logSearchShellOpenerProvider.overrideWithValue((h) async {
        if (failing.contains(h.id)) throw TimeoutException('ssh');
        return FakeShell((cmd) => (stdout: (outputs ?? _outputs)[h.id] ?? '@@j system\n@@j user\n@@nodocker\n', stderr: '', code: 0));
      }),
    ]);

// ── Kasa ────────────────────────────────────────────────────────────────────

final _entries = [
  VaultEntry(id: 'e1', title: 'Grafana', username: 'admin', password: 'Graf-Örnek-1', url: 'https://grafana.example.ts.net', tags: const ['atlas'], updatedAt: DateTime.utc(2026, 11, 12, 9)),
  VaultEntry(id: 'e2', title: 'Uptime Kuma', username: 'kuma', password: 'Kuma-Örnek-2', url: 'http://100.64.0.1:3001', tags: const ['atlas', 'izleme'], updatedAt: DateTime.utc(2026, 11, 10)),
  VaultEntry(id: 'e3', title: 'Wi-Fi (ev)', password: 'ev-ağı-örnek', notes: 'Misafir ağı: misafir / örnek', updatedAt: DateTime.utc(2026, 10, 1)),
  VaultEntry(id: 'e4', title: 'n8n', username: 'ben@example.com', password: 'N8n-Örnek-4', url: 'https://n8n.example.ts.net', tags: const ['orion'], updatedAt: DateTime.utc(2026, 11, 1)),
];

class _FakeFiles implements VaultFileAccess {
  _FakeFiles(this.text);
  final String text;
  final reads = <String>[];
  final deletes = <String>[];
  @override
  Future<String> read(Host host, String path) async {
    reads.add('${host.id}:$path');
    return text;
  }

  @override
  Future<void> delete(Host host, String path) async => deletes.add('${host.id}:$path');
}

class _YesBiometrics implements Biometrics {
  int asked = 0;
  @override
  Future<bool> available() async => true;
  @override
  Future<bool> authenticate(String reason) async {
    asked++;
    return true;
  }
}

class _Vault {
  _Vault({List<VaultEntry>? entries, this.files, this.bio}) : entries = entries ?? _entries;
  final List<VaultEntry> entries;
  final _FakeFiles? files;
  final _YesBiometrics? bio;
  final native = FakeNative();
  final timers = FakeTimers();
  final secure = <bool>[];

  late final Harness h = Harness(
        secrets: {'ssh-phone': 'x', 'agent-argo': 'x', 'grafana-atlas': 'x', vaultSecretId: encodeVault(entries)},
        extra: [
          sensitiveClipboardProvider.overrideWithValue(SensitiveClipboard(native, timer: timers.call, random: Random(3))),
          secureWindowProvider.overrideWithValue((on) async => secure.add(on)),
          if (files != null) vaultFileAccessProvider.overrideWithValue(files!),
        ],
        biometrics: bio,
      );

  /// Opens the app and unlocks the vault directly (authentication is covered in a separate test).
  Future<void> open(WidgetTester tester, {bool dark = false}) async {
    final c = await h.pump(tester, dark: dark);
    await tester.runAsync(() => c.read(vaultProvider.notifier).open());
    c.router.push('/vault');
    await _wait(tester);
  }
}

void main() {
  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('log arama $v: iki host, birleşik sonuç, vurgu, yalnız kullanıcı günlüğü notu', (tester) async {
      await _logs().pump(tester, route: '/system/logs?q=timeout', dark: dark);
      await _wait(tester);
      expect(find.textContaining('yalnız kullanıcı günlüğü'), findsOneWidget);
      expect(find.text('nginx'), findsOneWidget);
      expect(find.text('homepage'), findsOneWidget);
      expect(find.text('Tüm kaynaklar'), findsOneWidget);
      await golden('png/log_search_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('log arama: kaynak süzgeci, hata veren host, uzun basınca menü', (tester) async {
    await _logs(failing: {'orion'}).pump(tester, route: '/system/logs?q=timeout');
    await _wait(tester);
    expect(find.textContaining('Bağlantı zaman aşımına uğradı'), findsWidgets);
    await tester.ensureVisible(find.text('grafana · 1', skipOffstage: false));
    await settle(tester);
    await tester.tap(find.text('grafana · 1'));
    await settle(tester);
    expect(find.textContaining('Query timeout'), findsOneWidget);
    expect(find.textContaining('upstream timed out'), findsNothing);
    await tester.longPress(find.textContaining('Query timeout'));
    await settle(tester);
    expect(find.text('Kopyala'), findsOneWidget);
    expect(find.text("Claude'a sor"), findsOneWidget);
    expect(find.text("Obsidian'a kaydet"), findsOneWidget);
    await tester.tap(find.text('Kopyala'));
    await settle(tester);
    debugDisableShadows = true;
    await _finish(tester);
  });

  testWidgets('log arama: eşleşme yoksa boş durum', (tester) async {
    await _logs(outputs: const {}).pump(tester, route: '/system/logs?q=yok-boyle-bir-sey');
    await _wait(tester);
    expect(find.text('Son 15 dk içinde "yok-boyle-bir-sey" bulunamadı.'), findsOneWidget);
    expect(find.textContaining('Docker yok'), findsWidgets);
    debugDisableShadows = true;
    await _finish(tester);
  });

  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('şifre kasası listesi $v', (tester) async {
      final vault = _Vault();
      await vault.open(tester, dark: dark);
      expect(find.text('Grafana'), findsOneWidget);
      expect(find.text('admin · grafana.example.ts.net · atlas'), findsOneWidget);
      expect(find.textContaining('Örnek'), findsNothing); // no passwords in the list
      expect(vault.secure, [true]);
      await golden('png/vault_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('kasa: arama, ayrıntı, göster/gizle, hassas kopya, sil onayı, çıkınca FLAG_SECURE kalkar', (tester) async {
    final vault = _Vault();
    await vault.open(tester);
    await tester.enterText(find.byType(TextField), 'izleme');
    await settle(tester);
    expect(find.text('Grafana'), findsNothing);
    await tester.tap(find.text('Uptime Kuma'));
    await _wait(tester);
    expect(find.text('Kuma-Örnek-2'), findsNothing);
    expect(find.text('••••••••••••'), findsOneWidget);
    await golden('png/vault_entry_light_tr.png');
    await tester.tap(find.byTooltip('Şifreyi göster'));
    await settle(tester);
    expect(find.text('Kuma-Örnek-2'), findsOneWidget);
    await tester.tap(find.byTooltip('Şifreyi gizle'));
    await settle(tester);
    expect(find.text('Kuma-Örnek-2'), findsNothing);

    await tester.tap(find.byTooltip('Şifreyi kopyala'));
    await settle(tester);
    expect(vault.native.clip, 'Kuma-Örnek-2');
    expect(find.text('Şifre kopyalandı; pano 30 sn sonra temizlenecek'), findsOneWidget);
    vault.timers.fireAll();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(vault.native.clip, isNull);

    await tester.tap(find.byTooltip('Sil'));
    await settle(tester);
    expect(find.text('"Uptime Kuma" silinsin mi? Geri alınamaz.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Sil'));
    await _wait(tester);
    expect(find.text('Uptime Kuma'), findsNothing);
    final stored = decodeVault((await tester.runAsync<String?>(() => vault.h.secrets.read(vaultSecretId)))!);
    expect(stored.map((e) => e.id), ['e1', 'e3', 'e4']);
    await tester.tap(find.byIcon(LucideIcons.chevronLeft).last);
    await _wait(tester);
    expect(vault.secure, [true, false]);
    debugDisableShadows = true;
    await _finish(tester);
  });

  testWidgets('kasa: yeni kayıt + şifre üretici; depoya yazılır', (tester) async {
    final vault = _Vault(entries: const []);
    final h = vault.h;
    final c = await h.pump(tester);
    await tester.runAsync(() => c.read(vaultProvider.notifier).open());
    c.router.push('/vault');
    await _wait(tester);
    expect(find.text('Kasa boş'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Yeni kayıt'));
    await _wait(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Başlık'), 'Router');
    await tester.enterText(find.widgetWithText(TextFormField, 'Etiketler'), 'ev, ağ');
    await tester.tap(find.byTooltip('Şifre üret'));
    await settle(tester);
    expect(find.text('Uzunluk 20'), findsOneWidget);
    await tester.tap(find.text('Kullan'));
    await settle(tester);
    await tester.tap(find.text('Kaydet'));
    await _wait(tester);
    final saved = decodeVault((await tester.runAsync<String?>(() => h.secrets.read(vaultSecretId)))!).single;
    expect((saved.title, saved.tags.join(','), saved.password.length), ('Router', 'ev,ağ', 20));
    expect(find.text('Router'), findsOneWidget);
    debugDisableShadows = true;
    await _finish(tester);
  });

  testWidgets('kasa: uygulama kilidi yeniden istenir (parmak izi), kilitle düğmesi kayıtları bellekten atar', (tester) async {
    final bio = _YesBiometrics();
    final vault = _Vault(bio: bio);
    final c = await vault.h.pump(tester);
    await _wait(tester);
    final before = bio.asked; // app launch lock
    c.router.push('/vault');
    await _wait(tester);
    await _wait(tester);
    expect(bio.asked, before + 1);
    expect(find.text('Grafana'), findsOneWidget);
    await tester.tap(find.byTooltip('Kasayı kilitle'));
    await _wait(tester);
    expect(c.read(vaultProvider).entries, isNull);
    expect(find.text('Kasa kilitli'), findsOneWidget);
    expect(find.text('Grafana'), findsNothing);
    debugDisableShadows = true;
    await _finish(tester);
  });

  testWidgets('kasa: kilit kurulu değilse açılmaz, güvenlik ayarına yönlendirir', (tester) async {
    final c = await _Vault().h.pump(tester, route: '/vault');
    await _wait(tester);
    expect(c.read(vaultProvider).unlocked, isFalse);
    expect(find.textContaining('Önce PIN ya da parmak izi kilidini aç'), findsOneWidget);
    await golden('png/vault_needs_lock_light_tr.png');
    await _finish(tester);
  });

  testWidgets('kasa: Markdown içe aktarma önizlemesi, seçim, birleştirme, silme ayrıca sorulur', (tester) async {
    final files = _FakeFiles(fixture);
    final vault = _Vault(files: files);
    final h = vault.h;
    final c = await h.pump(tester);
    await tester.runAsync(() => c.read(vaultProvider.notifier).open());
    c.router.push('/vault');
    await _wait(tester);
    await tester.tap(find.byTooltip('İçe aktar'));
    await _wait(tester);
    await tester.tap(find.text('Dosyayı oku'));
    await _wait(tester);
    expect(files.reads, ['argo:~/SIFRELER.md']);
    expect(find.text('7 SATIR BULUNDU'), findsOneWidget); // section header in uppercase
    expect(find.textContaining('Graf-Sifre'), findsNothing); // passwords are masked
    await golden('png/vault_import_light_tr.png');
    await tester.scrollUntilVisible(find.text('4 kaydı içe aktar'), 200, scrollable: find.byType(Scrollable).first);
    await settle(tester);
    expect(find.text('4 kaydı içe aktar'), findsOneWidget); // rows without a password are not selected
    expect(find.textContaining('güncellenecek', skipOffstage: false), findsNWidgets(2)); // Grafana/admin, Uptime Kuma/kuma
    await tester.tap(find.text('4 kaydı içe aktar'));
    await _wait(tester);
    expect(find.textContaining('silinsin mi?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Vazgeç'));
    await _wait(tester);
    expect(files.deletes, isEmpty);
    final stored = decodeVault((await tester.runAsync<String?>(() => h.secrets.read(vaultSecretId)))!);
    expect(stored.length, 4 + 2);
    final g = stored.singleWhere((e) => e.title == 'Grafana'); // same title + user: updated
    expect((g.id, g.password), ('e1', 'Graf-Sifre_1'));
    debugDisableShadows = true;
    await _finish(tester);
  });
}
