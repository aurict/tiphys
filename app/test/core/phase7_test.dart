import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
