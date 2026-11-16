// 9.5 Claude session changes (diff, commit + push, revert) and 9.6 clipboard sync settings / phone → PC.
// To update: flutter test test/goldens/review_clipboard_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/claude/claude_controller.dart';
import 'package:tiphys/features/claude/session_insights.dart';
import 'package:tiphys/features/git/git_screen.dart';
import 'package:tiphys/features/system/clipboard_sync.dart';
import 'package:tiphys/state/providers.dart';

import '../helpers/harness.dart';

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
}

/// The profile updates once written to disk: real time + frames so real file operations finish in order.
Future<void> _saved(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

Future<void> _wait(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

/// Like session a1: runner.py edited, retry.py newly written (worktree branch, "website" repo in FakeAgent).
final _events = [
  ClaudeEvent({'kind': 'tool_use', 'seq': 1, 'id': 't1', 'name': 'Edit', 'input': {'file_path': 'agents/runner.py', 'old_string': '    return run(cfg)', 'new_string': '    return run(cfg, timeout=30)'}}),
  ClaudeEvent({'kind': 'tool_use', 'seq': 2, 'id': 't2', 'name': 'Write', 'input': {'file_path': '/home/user/Desktop/website/agents/retry.py', 'content': 'def retry(fn, n=3):\n    ...'}}),
];

Future<ProviderContainer> _openChanges(WidgetTester tester) async {
  final c = await Harness().pump(tester);
  c.router.routerDelegate.navigatorKey.currentState!.push(MaterialPageRoute<void>(
    builder: (_) => SessionChangesScreen(events: _events, cwd: '/home/user/Desktop/website', title: 'Testleri düzelt ve raporla'),
  ));
  await _wait(tester);
  return c;
}

void main() {
  tearDown(() => FakeAgent.pushNoUpstream = false);

  testWidgets('commit + push: mesaj oturum başlığı, yalnız oturum dosyaları; dal uzak depoda yoksa sorup gönderir', (tester) async {
    FakeAgent.calls.clear();
    FakeAgent.pushNoUpstream = true;
    await _openChanges(tester);
    expect(find.text('tiphys/3f9a1c2e'), findsOneWidget);
    expect(find.textContaining('worktree dalında'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Commit + push'));
    await settle(tester);
    expect(find.widgetWithText(TextField, 'Testleri düzelt ve raporla'), findsOneWidget);
    expect(find.text('agents/retry.py'), findsWidgets);
    await golden('png/claude_changes_commit_light_tr.png');
    await tester.tap(find.widgetWithText(FilledButton, 'Commit + push').last);
    await settle(tester);
    expect(find.textContaining('uzak depoda yok'), findsOneWidget);
    await tester.tap(find.text('Dalı gönder'));
    await _wait(tester);
    final commit = FakeAgent.calls.singleWhere((c) => c.$2 == '/v1/git/commit').$3 as Map;
    expect(commit, {'path': '/home/user/Desktop/website', 'message': 'Testleri düzelt ve raporla', 'files': ['agents/runner.py', 'agents/retry.py']});
    final pushes = [for (final c in FakeAgent.calls.where((c) => c.$2 == '/v1/git/push')) c.$3];
    expect(pushes, [
      {'path': '/home/user/Desktop/website'},
      {'path': '/home/user/Desktop/website', 'setUpstream': true},
    ]);
    expect(find.text('Commit edildi ve gönderildi'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('geri al: dosyalar listelenir, yeni dosya yalnız kutu işaretlenirse silinir', (tester) async {
    FakeAgent.calls.clear();
    await _openChanges(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Değişiklikleri geri al'));
    await settle(tester);
    expect(find.text('Değişiklikler geri alınsın mı?'), findsOneWidget);
    await golden('png/claude_changes_revert_light_tr.png');
    await tester.tap(find.widgetWithText(TextButton, 'Değişiklikleri geri al'));
    await _wait(tester);
    var body = FakeAgent.calls.lastWhere((c) => c.$2 == '/v1/git/discard').$3 as Map;
    expect(body, {'path': '/home/user/Desktop/website', 'files': ['agents/runner.py'], 'source': 'head', 'confirm': true, 'deleteNew': false});

    await tester.tap(find.widgetWithText(OutlinedButton, 'Değişiklikleri geri al'));
    await settle(tester);
    await tester.tap(find.textContaining('yeni dosyayı da sil'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Değişiklikleri geri al'));
    await _wait(tester);
    body = FakeAgent.calls.lastWhere((c) => c.$2 == '/v1/git/discard').$3 as Map;
    expect(body['files'], ['agents/runner.py', 'agents/retry.py']);
    expect(body['deleteNew'], true);

    // If cancelled, no request is sent.
    final before = FakeAgent.calls.length;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Değişiklikleri geri al'));
    await settle(tester);
    await tester.tap(find.text('Vazgeç'));
    await _wait(tester);
    expect(FakeAgent.calls.skip(before).where((c) => c.$2 == '/v1/git/discard'), isEmpty);
    await _finish(tester);
  });

  testWidgets('dosya farkı HEAD\'e göre açılır', (tester) async {
    FakeAgent.calls.clear();
    await _openChanges(tester);
    await tester.tap(find.byTooltip('Farkı göster').first);
    await _wait(tester);
    expect(find.byType(GitDiffScreen), findsOneWidget);
    expect(find.textContaining('+0–7. fazlar tamamlandı.'), findsOneWidget);
    final q = FakeAgent.calls.lastWhere((c) => c.$2 == '/v1/git/diff').$3 as Map;
    expect(q, {'path': '/home/user/Desktop/website', 'file': 'agents/runner.py', 'head': 'true'});
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('bildirim ayarları: pano bölümü, eşitleme açılınca PC seçimi', (tester) async {
    final c = await Harness().pump(tester, route: '/settings/notifications');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await settle(tester);
    expect(find.text('Eşitlenen PC'), findsNothing);
    await tester.tap(find.text('Panoyu PC ile eşitle'));
    await _saved(tester);
    expect(c.read(profileProvider).notifications.clipboardToPc, isTrue);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await settle(tester);
    expect(find.text('Otomatik (argo (PC))'), findsOneWidget);
    await golden('png/notifications_clipboard_light_tr.png');
    await tester.tap(find.text('atlas').last);
    await _saved(tester);
    expect(c.read(profileProvider).notifications.clipboardHostId, 'atlas');
    await _finish(tester);
  });

  testWidgets('telefon → PC: açılışta ve öne gelişte pano değiştiyse PC\'ye gönderilir', (tester) async {
    FakeAgent.calls.clear();
    var clip = 'telefondan kopya';
    final base = exampleProfile();
    final h = Harness(
      profile: base.copyWith(notifications: base.notifications.copyWith(clipboardToPc: true)),
      // On a real device the native plugin is queried; in tests there is no plugin (then the safe side: treated as
      // sensitive and not sent).
      extra: [clipboardReaderProvider.overrideWithValue(() async => clip), clipboardSensitiveProvider.overrideWithValue(() async => false)],
    );
    await h.pump(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 700));
    await _wait(tester);
    List<Object?> puts() => [for (final c in FakeAgent.calls.where((c) => c.$1 == 'PUT' && c.$2 == '/v1/desktop/clipboard')) c.$3];
    expect(puts(), [
      {'text': 'telefondan kopya'},
    ]);
    // Coming to the foreground with the same text doesn't resend; it sends once the text changes.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 700));
    await _wait(tester);
    expect(puts(), hasLength(1));
    clip = 'yeni kopya';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 700));
    await _wait(tester);
    expect(puts().last, {'text': 'yeni kopya'});
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('telefon → PC kapalıyken pano hiç okunmaz', (tester) async {
    var reads = 0;
    await Harness(extra: [
      clipboardReaderProvider.overrideWithValue(() async {
        reads++;
        return 'x';
      }),
    ]).pump(tester);
    await tester.pump(const Duration(seconds: 1));
    await _wait(tester);
    expect(reads, 0);
    expect(const NotificationSettings().clipboardToPc, isFalse);
    await _finish(tester);
    debugDisableShadows = true;
  });
}
