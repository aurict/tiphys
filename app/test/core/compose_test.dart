// Compose stacks (SSH script, parsing, update flow) and scheduled task / compose event texts.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/core/ssh/compose.dart';
import 'package:tiphys/features/claude/schedules.dart';
import 'package:tiphys/features/system/compose.dart';
import 'package:tiphys/features/system/events.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';

import '../helpers/fake_shell.dart';

void main() {
  final tr = lookupAppLocalizations(const Locale('tr'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('liste betiği: kökler kaçışlı, ~ ev dizinine genişler, docker öncelik sırası; sh ile sözdizimi geçerli', () async {
    final s = composeListScript(['~/stack', "/srv/o'ne/"]);
    expect(s, contains(r'"$HOME"/'"'stack'/*/compose.yaml"));
    expect(s, contains(r"'/srv/o'\''ne'/*/docker-compose.yml"));
    expect(s.indexOf('/*/compose.yaml'), lessThan(s.indexOf('/*/docker-compose.yml')));
    // In a real shell: two stacks with fake docker (one has two files: compose.yaml takes precedence, listed once).
    final dir = Directory.systemTemp.createTempSync('tiphys-compose');
    for (final f in ['a/compose.yaml', 'a/docker-compose.yml', 'b c/docker-compose.yml']) {
      File('${dir.path}/stack/$f').createSync(recursive: true);
    }
    File('${dir.path}/bin/docker').createSync(recursive: true);
    File('${dir.path}/bin/docker').writeAsStringSync('#!/bin/sh\necho "{\\"Service\\":\\"svc\\",\\"State\\":\\"running\\",\\"Status\\":\\"Up\\",\\"Name\\":\\"\${PWD##*/}-svc-1\\"}"\n');
    await Process.run('chmod', ['+x', '${dir.path}/bin/docker']);
    final r = await Process.run('sh', ['-c', composeListScript(['~/stack'])], environment: {'HOME': dir.path, 'PATH': '${dir.path}/bin:/usr/bin:/bin'});
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final l = parseComposeList(r.stdout as String);
    expect(l.home, dir.path);
    expect([for (final s in l.stacks) '${s.name}/${s.file}'], ['a/compose.yaml', 'b c/docker-compose.yml']);
    expect(l.stacks.last.containers.single.name, 'b c-svc-1');
    expect(l.pretty(l.stacks.first.dir), '~/stack/a');
    dir.deleteSync(recursive: true);
  });

  test('ayrıştırma: satır satır JSON, eski dizi biçimi, uyarı, hata, container yok', () {
    final l = parseComposeList(FakeComposeHost().listing);
    expect(l.stacks.map((s) => s.name), ['aurict', 'monitoring', 'web', 'yedek']);
    final byName = {for (final s in l.stacks) s.name: s};
    expect(byName['web']!.state, 'running');
    expect(byName['monitoring']!.state, 'partial');
    expect(byName['monitoring']!.warnings, contains('obsolete'));
    expect(byName['monitoring']!.containers.map((c) => c.health), ['healthy', 'unhealthy', '']);
    expect(byName['aurict']!.state, 'error');
    expect(byName['aurict']!.error, contains('AURICT_IMAGE_WEB'));
    expect(byName['yedek']!.state, 'down');
    final old = parseComposeList('@@stack /s/x/compose.yaml\n[{"Service":"a","State":"exited"},{"Service":"b","State":"exited"}]\n@@exit 0\n');
    expect(old.stacks.single.state, 'stopped');
    expect(composeStackSubtitle(tr, byName['monitoring']!), '2/3 çalışıyor · sağlıksız');
  });

  ComposeStack web() => parseComposeList(FakeComposeHost().listing).stacks.firstWhere((s) => s.name == 'web');

  test('güncelleme: yalnız yeni imajı olan servis yeniden oluşturulur; değişiklik yoksa up yok', () async {
    final h = FakeComposeHost()..afterPull['nginx:1.27-alpine'] = 'sha256:new';
    final out = StringBuffer();
    final r = await ComposeOps(h.shell, web()).update(out.write);
    expect(r.check.pulled, ['nginx:1.27-alpine']);
    expect(r.check.outdated, ['nginx']);
    expect(r.recreated, isTrue);
    expect(h.shell.commands.last, endsWith("up -d 'nginx'"));
    expect(h.shell.commands.last, startsWith("cd '/home/ubuntu/stack/web' && docker compose -f 'compose.yaml'"));
    expect(out.toString(), contains(r'$ docker compose pull --ignore-buildable'));
    expect(out.toString(), contains('nginx Pulled'));

    // Second time: image unchanged, container up to date → up does not run.
    final n = h.shell.commands.length;
    final again = await ComposeOps(h.shell, web()).update((_) {});
    expect(again.recreated, isFalse);
    expect(h.shell.commands.skip(n).where((c) => c.contains(' up ')), isEmpty);
    // Forced: up -d on the whole stack.
    final forced = await ComposeOps(h.shell, web()).update((_) {}, force: true);
    expect(forced.recreated && forced.forced, isTrue);
    expect(h.shell.commands.last, endsWith(' up -d'));
    // Every generated command (including the image/container scripts) is syntactically valid in the shell.
    await ComposeOps(h.shell, web()).logs();
    for (final c in h.shell.commands.toSet()) {
      final r = await Process.run('sh', ['-n', '-c', c]);
      expect(r.exitCode, 0, reason: '$c\n${r.stderr}');
    }
  });

  test('önceden denetlenmiş (çekilmiş ama uygulanmamış) imaj da güncellenir', () async {
    final h = FakeComposeHost()..ids['redis:7'] = 'sha256:pulled-earlier';
    final r = await ComposeOps(h.shell, web()).update((_) {});
    expect(r.check.pulled, isEmpty);
    expect(r.check.outdated, ['cache']);
    expect(h.shell.commands.last, endsWith("up -d 'cache'"));
  });

  test('pull ya da up başarısızsa adımı ve çıkış koduyla hata', () async {
    final h = FakeComposeHost()..pullCode = 18;
    await expectLater(ComposeOps(h.shell, web()).update((_) {}), throwsA(isA<ComposeFailure>().having((f) => f.step, 'step', 'pull').having((f) => f.code, 'code', 18)));
    final u = FakeComposeHost()
      ..afterPull['redis:7'] = 'sha256:new'
      ..upCode = 1;
    await expectLater(ComposeOps(u.shell, web()).update((_) {}), throwsA(isA<ComposeFailure>().having((f) => f.step, 'step', 'up')));
  });

  test('compose ve zamanlanmış görev olay metinleri; bilinmeyen olayda genel başlık', () {
    expect(noticeText(tr, 'compose.updated', {'host': 'orion', 'stack': 'web', 'services': 'nginx, cache', 'count': 2}), ('web güncellendi', 'orion · nginx, cache'));
    expect(noticeText(tr, 'compose.updated', {'host': 'orion', 'stack': 'web'}), ('web güncellendi', 'orion'));
    expect(noticeText(en, 'compose.failed', {'host': 'orion', 'stack': 'web', 'step': 'pull', 'code': 18}), ('web update failed', 'orion · pull failed (exit 18)'));
    expect(noticeText(tr, 'claude.scheduleFailed', {'name': 'Rapor', 'reason': 'agent.claude.folderNotFound'}), ('Zamanlanmış görev başlatılamadı: Rapor', 'Klasör bulunamadı'));
    expect(noticeText(en, 'claude.scheduled', {'name': 'Report'})!.$1, 'Scheduled task started: Report');
    expect(noticeId('compose.updated', {'host': 'a', 'stack': 'web'}), noticeId('compose.failed', {'host': 'a', 'stack': 'web'}));
    expect(routeForLink('tiphys://system/compose'), '/system/compose');
    expect(routeForLink('tiphys://claude/schedules'), '/claude/schedules');
    expect(routeForLink('tiphys://claude/abc'), '/claude/session/abc');
    final e = HostEvent(const Host(id: 'a', name: 'a', address: 'a'), {'id': '1', 'at': '2026-11-14T10:00:00Z', 'key': 'docker.paused', 'params': {'container': 'web'}});
    expect(eventText(tr, e), ('Docker olayı', 'web'));
  });

  test('zamanlanmış görev zaman metinleri', () {
    expect(scheduleWhenText(tr, 'tr', {'kind': 'daily', 'time': '03:00'}), 'Her gün 03:00');
    expect(scheduleWhenText(tr, 'tr', {'kind': 'weekly', 'time': '08:30', 'days': [5, 1]}), 'Pzt, Cum · 08:30');
    expect(scheduleWhenText(en, 'en', {'kind': 'interval', 'everyMinutes': 360}), 'Every 6 h');
    expect(scheduleWhenText(tr, 'tr', {'kind': 'interval', 'everyMinutes': 45}), '45 dakikada bir');
    final now = DateTime(2026, 11, 14, 14, 5);
    expect(scheduleTimeText(tr, 'tr', DateTime(2026, 11, 15, 3), now), 'yarın 03:00');
    expect(scheduleTimeText(en, 'en', DateTime(2026, 11, 14, 18), now), 'today 18:00');
    expect(scheduleInput({'name': 'A', 'cwd': '~', 'prompt': 'p', 'when': {'kind': 'daily', 'time': '03:00'}, 'enabled': true, 'id': 'x', 'lastRun': null}, enabled: false),
        {'name': 'A', 'cwd': '~', 'prompt': 'p', 'when': {'kind': 'daily', 'time': '03:00'}, 'permissionMode': 'default', 'enabled': false});
  });
}
