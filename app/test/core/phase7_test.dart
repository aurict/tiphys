import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/features/claude/session_insights.dart';
import 'package:tiphys/features/claude/claude_controller.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/claude/attachments.dart';
import 'package:tiphys/features/git/git_screen.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';

void main() {
  final tr = lookupAppLocalizations(const Locale('tr'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('yeni bildirimler iki dilde', () {
    expect(noticeText(tr, 'disk.full', {'host': 'argo', 'mount': '/', 'percent': 93}), ('argo: disk dolmak üzere', '/ %93 dolu'));
    expect(noticeText(en, 'service.failed', {'host': 'argo', 'unit': 'app-backup.service'}), ('argo: service failed', 'app-backup.service'));
    expect(noticeText(tr, 'grafana.alert', {'name': 'BackupStale', 'severity': 'critical'}), ('Alarm: BackupStale', 'critical'));
    expect(noticeText(en, 'command.done', {'host': 'argo', 'command': 'npm run build', 'seconds': 95}), ('argo: command finished', 'npm run build · 95 s'));
    expect(noticeText(tr, 'command.failed', {'host': 'atlas', 'command': 'make', 'seconds': 3, 'code': 2}), ('atlas: komut hata verdi (çıkış 2)', 'make · 3 sn'));
  });

  test('servis ve Grafana bildirimleri tercihlere uyar', () {
    const p = Profile(notifications: NotificationSettings(serviceDown: false, grafanaAlerts: false));
    expect(noticeAllowed(p, 'service.failed'), isFalse);
    expect(noticeAllowed(p, 'grafana.alert'), isFalse);
    expect(noticeAllowed(p, 'disk.full'), isTrue);
  });

  test('yeni derin bağlantılar', () {
    expect(routeForLink('tiphys://monitor/grafana'), '/monitor/grafana');
    expect(routeForLink('tiphys://terminal'), '/terminal');
  });

  test('git hata metinleri (stderr eklenir)', () {
    expect(gitErrorText(tr, const AgentError('agent.git.nothingToCommit')), "Commit'lenecek değişiklik yok");
    expect(
      gitErrorText(en, const AgentError('agent.git.pushFailed', {'stderr': 'fatal: could not read Username\nline2'})),
      'Push failed\nfatal: could not read Username\nline2',
    );
  });

  test('büyük fotoğraf 1568 px PNG olarak küçültülür, küçük olan olduğu gibi kalır', () async {
    Future<Uint8List> png(int w, int h) async {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFF3366FF));
      final img = await rec.endRecording().toImage(w, h);
      return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    }

    final small = await png(400, 300);
    final a = await prepareImage('kucuk.png', small);
    expect(a.mediaType, 'image/png');
    expect(a.bytes, same(small));

    final big = await prepareImage('buyuk.bmp', await png(3000, 1500));
    expect(big.mediaType, 'image/png');
    final codec = await ui.instantiateImageCodec(big.bytes);
    final f = await codec.getNextFrame();
    expect((f.image.width, f.image.height), (1568, 784));
    expect(a.toJson()['data'], isNotEmpty);
  });

  test('ajan sürümü karşılaştırması', () {
    expect(agentOutdated('0.2.0'), isTrue);
    expect(agentOutdated(kExpectedAgentVersion), isFalse);
    expect(agentOutdated('0.10.0'), isFalse);
    expect(agentOutdated('1.0.0'), isFalse);
    expect(agentOutdated(null), isFalse);
    expect(agentOutdated('geliştirme'), isFalse);
  });

  group('oturum özetleri', () {
    ClaudeEvent e(int seq, String kind, [Map<String, dynamic> x = const {}]) => ClaudeEvent({'seq': seq, 'kind': kind, ...x});
    final events = [
      e(1, 'user', {'text': 'başla'}),
      e(2, 'result', {'costUsd': 0.40}),
      e(3, 'tool_use', {'name': 'Bash', 'input': {'command': 'ls'}}),
      e(4, 'tool_use', {'name': 'Edit', 'input': {'file_path': '/p/a.dart', 'old_string': 'x', 'new_string': 'y'}}),
      e(5, 'tool_use', {'name': 'Write', 'input': {'file_path': '/p/b.dart', 'content': 'z'}}),
      e(6, 'tool_use', {'name': 'Edit', 'input': {'file_path': '/p/a.dart', 'old_string': 'y', 'new_string': 'w'}}),
      e(7, 'text', {'text': 'Bitti, iki dosya değişti.'}),
      e(8, 'result', {'costUsd': 0.65}),
    ];
    test('sen yokken: tur, komut, dosya ve maliyet farkı', () {
      final d = awayDigest(events, 2)!;
      expect(d.turns, 1);
      expect(d.commands, 1);
      expect(d.files, ['/p/a.dart', '/p/b.dart']);
      expect(d.costUsd, closeTo(0.25, 1e-9));
      expect(d.lastText, 'Bitti, iki dosya değişti.');
      expect(awayDigest(events, 8), isNull); // yeni bir şey yok
    });
    test('değişiklikler: dosya başına düzenlemeler', () {
      final c = sessionChanges(events);
      expect(c.keys, ['/p/a.dart', '/p/b.dart']);
      expect(c['/p/a.dart'], hasLength(2));
      expect(c['/p/b.dart']!.single, [('+', 'z')]);
    });
  });
}
