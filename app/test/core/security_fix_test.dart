// "Send to Claude" logic (PLAN.md §16 F4): brief request from the selection, permission mode rules, the session body,
// target validation, lock-screen visibility, tool names and the sudo dialog (the password is sent and not kept).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' show NotificationVisibility;
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/claude/claude_controller.dart';
import 'package:tiphys/features/claude/security_session.dart';
import 'package:tiphys/features/security/security_fix.dart';
import 'package:tiphys/features/vault/vault_state.dart' show secureWindowProvider;
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/theme/theme.dart';
import 'package:tiphys/theme/tokens.dart';

FixBrief _brief({bool investigate = false}) => FixBrief({
      'text': 'BRIEF',
      'bytes': 5,
      'truncated': false,
      'investigate': investigate,
      'hosts': [
        {'id': 'orion', 'name': 'orion', 'role': 'server', 'root': true, 'source': 'ssh'},
      ],
      'items': [
        {'ref': 'finding:orion:ssh.passwordAuth', 'type': 'finding', 'host': 'orion', 'mode': investigate ? 'investigate' : 'fix'},
        {'ref': 'x', 'type': 'secret', 'error': 'agent.security.itemNotFound'},
      ],
    });

void main() {
  test('brief isteği: seçimden öğeler, dil tr|en', () {
    final items = [
      FixItem.finding(host: 'orion', id: 'ssh.passwordAuth', label: 'a'),
      FixItem.change(host: 'orion', category: 'ports', item: 'tcp/2222', label: 'b'),
      FixItem.vuln(hex: 'a' * 64, cve: 'CVE-2026-0001', label: 'c'),
      FixItem.secret(id: 's1', label: 'd'),
      FixItem.exposure(id: 'e1', label: 'e'),
    ];
    expect(fixBriefRequest(items, 'tr'), {
      'items': [
        {'type': 'finding', 'host': 'orion', 'id': 'ssh.passwordAuth'},
        {'type': 'change', 'host': 'orion', 'id': 'ports|tcp/2222'},
        {'type': 'vuln', 'image': 'sha256:${'a' * 64}', 'cve': 'CVE-2026-0001'},
        {'type': 'secret', 'id': 's1'},
        {'type': 'exposure', 'id': 'e1'},
      ],
      'language': 'tr',
    });
    expect(fixBriefRequest(items, 'de')['language'], 'en');
    final many = [for (var i = 0; i < 40; i++) FixItem.secret(id: 's$i', label: '$i')];
    expect((fixBriefRequest(many, 'en')['items'] as List).length, fixMaxItems);
  });

  test('seçim: aynı öğe iki kez eklenmez, tekrar dokunmak kaldırır', () {
    final sel = FixSelection()..toggleMode();
    final a = FixItem.secret(id: 's1', label: 'x');
    sel.toggle(a);
    sel.toggle(FixItem.secret(id: 's1', label: 'başka etiket'));
    expect(sel.count, 0);
    sel.toggle(a);
    expect(sel.has(FixItem.secret(id: 's1', label: 'z')), isTrue);
    sel.toggleMode();
    expect(sel.count, 0, reason: 'seçim kipinden çıkınca temizlenir');
  });

  test('kip kuralları: investigate yalnız plan, bypass yalnız normal oturumda', () {
    expect(fixAllowedModes(investigate: true), ['plan']);
    expect(fixAllowedModes(investigate: false), contains('bypassPermissions'));
    expect(fixDefaultMode(investigate: true), 'plan');
    expect(fixDefaultMode(investigate: false), 'default');
    final inv = fixSessionBody(brief: _brief(investigate: true), agentHostId: 'argo', mode: 'bypassPermissions');
    expect(inv['permissionMode'], 'plan', reason: 'investigate bypass istese de plan');
    expect(fixSessionBody(brief: _brief(), agentHostId: 'argo', mode: 'acceptEdits')['permissionMode'], 'acceptEdits');
  });

  test('oturum gövdesi: kind, brief, host kimlikleri, origin, not', () {
    final b = fixSessionBody(brief: _brief(), agentHostId: 'argo', mode: 'default', note: '  8080 açık kalsın ', effort: 'high');
    expect(b['kind'], 'security');
    expect(b['cwd'], '~');
    expect(b['prompt'], '8080 açık kalsın');
    expect(b['effort'], 'high');
    expect(b.containsKey('model'), isFalse);
    final sec = b['security'] as Map;
    expect(sec['brief'], 'BRIEF');
    expect(sec['hosts'], ['orion']);
    expect(sec['investigate'], false);
    expect(sec['origin'], {'agentHostId': 'argo', 'refs': ['finding:orion:ssh.passwordAuth']});
  });

  test('origin 4 KB sınırını aşmaz', () {
    final refs = [for (var i = 0; i < 400; i++) 'finding:orion:rule.number$i:with-a-long-suffix'];
    final o = fixOrigin('argo', refs);
    expect(utf8.encode(jsonEncode(o)).length, lessThanOrEqualTo(4096));
    expect((o['refs'] as List).isNotEmpty, isTrue);
  });

  test('hedef doğrulama: host, ssh, port, yinelenen, sayı', () {
    FixTargets t(List<FixTarget> l, [int cache = 15]) => FixTargets(targets: l, sudoCacheMinutes: cache);
    const ok = FixTarget(host: 'orion', name: 'orion', ssh: 'tiphys@orion.example.org', port: 22);
    expect(fixTargetsProblem(t([ok, const FixTarget(host: 'self', name: 'PC')])), isNull);
    expect(fixTargetsProblem(t([const FixTarget(host: 'Orion', name: 'x')])), FixTargetProblem.host);
    expect(fixTargetsProblem(t([const FixTarget(host: '-orion', name: 'x')])), FixTargetProblem.host);
    expect(fixTargetsProblem(t([const FixTarget(host: 'a', name: ' ')])), FixTargetProblem.name);
    expect(fixTargetsProblem(t([const FixTarget(host: 'a', name: 'a', ssh: 'bad host')])), FixTargetProblem.ssh);
    expect(fixTargetsProblem(t([const FixTarget(host: 'a', name: 'a', ssh: 'u@h;rm')])), FixTargetProblem.ssh);
    expect(fixTargetsProblem(t([const FixTarget(host: 'a', name: 'a', ssh: 'h', port: 70000)])), FixTargetProblem.port);
    expect(fixTargetsProblem(t([const FixTarget(host: 'a', name: 'a', port: 22)])), FixTargetProblem.port, reason: 'port yalnız SSH hedefinde');
    expect(fixTargetsProblem(t([ok, ok])), FixTargetProblem.duplicate);
    expect(fixTargetsProblem(t([for (var i = 0; i < 21; i++) FixTarget(host: 'h$i', name: 'n')])), FixTargetProblem.tooMany);
    expect(fixTargetsProblem(t([ok], 0)), FixTargetProblem.cache);
    expect(fixTargetsProblem(t([ok], 121)), FixTargetProblem.cache);
    expect(validFixSsh('orion'), isTrue);
    expect(validFixSsh('user@orion.example.org'), isTrue);
    expect(validFixSsh('-oProxyCommand=x'), isFalse, reason: 'tireyle başlayan seçenek enjeksiyonu');
    expect(FixTarget.fromJson({'host': 'a', 'name': 'a', 'ssh': null}).toJson(), {'host': 'a', 'name': 'a', 'ssh': null});
  });

  test('bildirim: güvenlik oturumunun izin bildirimi kilit ekranında gizli, sudo da', () {
    expect(lockScreenVisibility('claude.waiting', {'security': 1}, 's1', null), NotificationVisibility.secret);
    expect(lockScreenVisibility('claude.waiting', {'pc': 1}, 's1', null), NotificationVisibility.secret);
    expect(lockScreenVisibility('claude.waiting', {}, 's1', null), isNull);
    expect(lockScreenVisibility('claude.sudo', {'title': 't', 'host': 'orion'}, 's1', null), NotificationVisibility.secret);
    expect(noticeId('claude.sudo', const {}, link: 'tiphys://claude/s1', requestId: 'r1'), isNot(noticeId('claude.sudo', const {}, link: 'tiphys://claude/s1', requestId: 'r2')));
  });

  testWidgets('claude.sudo bildirim metni iki dilde', (tester) async {
    for (final lang in ['tr', 'en']) {
      final l = lookupAppLocalizations(Locale(lang));
      final n = noticeText(l, 'claude.sudo', {'title': 'Düzelt', 'host': 'orion'});
      expect(n, isNotNull);
      expect(n!.$2, contains('orion'));
    }
  });

  test('araç adları okunur: host + komut / yol', () {
    expect(secToolName('mcp__tiphys_sec__run'), 'run');
    expect(secToolName('run'), isNull, reason: 'çıplak ad host girdisi olmadan araç sayılmaz');
    expect(secToolName('run', {'host': 'orion'}), 'run');
    expect(toolSummary('mcp__tiphys_sec__run', {'host': 'orion', 'cmd': 'ss -tlnp', 'sudo': true}), 'orion · sudo ss -tlnp');
    expect(toolSummary('mcp__tiphys_sec__read_file', {'host': 'orion', 'path': '/etc/ssh/sshd_config'}), 'orion · /etc/ssh/sshd_config');
    expect(toolSummary('mcp__tiphys_sec__safe_apply', {'host': 'orion', 'kind': 'sshd'}), 'orion · sshd');
    expect(toolSummary('mcp__tiphys_sec__rollback', {'host': 'orion'}), 'orion');
    expect(toolDiff('mcp__tiphys_sec__write_file', {'content': 'a\nb'}), [('+', 'a'), ('+', 'b')]);
    expect(toolDiff('write_file', {'diff': '--- a\n+++ b\n@@ -1 +1 @@\n-x\n+y\n z\n'}), [(' ', '@@ -1 +1 @@'), ('-', 'x'), ('+', 'y'), (' ', 'z')]);
  });

  testWidgets('sudo penceresi: parola gönderilir, alan boşalır, FLAG_SECURE açılıp kapanır, saklanmaz', (tester) async {
    final secure = <bool>[];
    final sent = <String>[];
    String? fieldAtSend;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        secureWindowProvider.overrideWithValue((on) async => secure.add(on)),
      ],
      child: MaterialApp(
        theme: buildTheme(TiphysTokens.light),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: c,
                builder: (_) => SudoDialog(
                  host: 'orion',
                  attempt: 2,
                  onPassword: (pw) async {
                    fieldAtSend = tester.widget<TextField>(find.byType(TextField)).controller!.text;
                    sent.add(pw);
                  },
                  onDeny: () async {},
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(secure, [true]);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    expect(field.autofillHints, isNull);
    expect(find.textContaining('attempt 2'), findsOneWidget, reason: 'yanlış parola ipucu');
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(sent, ['hunter2']);
    expect(fieldAtSend, '', reason: 'istek çıkarken alan zaten boş');
    expect(find.byType(SudoDialog), findsNothing);
    expect(secure, [true, false]);
  });

  testWidgets('sudo penceresi: istek başka yerde sonuçlanınca (iptal) kapanır', (tester) async {
    final source = ChangeNotifier();
    addTearDown(source.dispose);
    var pending = true;
    await tester.pumpWidget(ProviderScope(
      overrides: [secureWindowProvider.overrideWithValue((on) async {})],
      child: MaterialApp(
        theme: buildTheme(TiphysTokens.light),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(context: c, builder: (_) => SudoDialog(host: 'orion', attempt: 1, source: source, stillPending: () => pending, onPassword: (_) async {}, onDeny: () async {})),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(SudoDialog), findsOneWidget);
    pending = false;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    source.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(SudoDialog), findsNothing);
  });

  testWidgets('sudo penceresi: investigate uyarısı ve reddet', (tester) async {
    var denied = false;
    await tester.pumpWidget(ProviderScope(
      overrides: [secureWindowProvider.overrideWithValue((on) async {})],
      child: MaterialApp(
        theme: buildTheme(TiphysTokens.light),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SudoDialog(host: 'orion', attempt: 1, investigate: true, onPassword: (_) async {}, onDeny: () async => denied = true)),
      ),
    ));
    await tester.pump();
    expect(find.textContaining('may be compromised'), findsOneWidget);
    expect(find.textContaining('could capture the password'), findsOneWidget);
    expect(find.textContaining('attempt'), findsNothing);
    await tester.tap(find.text('Deny'));
    await tester.pump();
    expect(denied, isTrue);
  });
}
