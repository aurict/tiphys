// Event stream and backup status: notification texts, preference filter, links, helpers, profile fields.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/system/backups.dart';
import 'package:tiphys/features/system/events.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';

void main() {
  final tr = lookupAppLocalizations(const Locale('tr'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('Docker ve yedek bildirim metinleri iki dilde', () {
    expect(noticeText(tr, 'docker.died', {'host': 'atlas', 'container': 'web', 'code': 137}), ('Container çöktü · atlas', 'web (çıkış kodu 137)'));
    expect(noticeText(en, 'docker.oom', {'host': 'atlas', 'container': 'web'}), ('Container out of memory · atlas', 'web'));
    expect(noticeText(tr, 'docker.restarted', {'host': 'atlas', 'container': 'gitea'})!.$1, 'Container yeniden başladı · atlas');
    expect(noticeText(tr, 'backup.stale', {'host': 'atlas', 'name': 'Obsidian', 'hours': 30}), ('Yedek eskidi: Obsidian', 'atlas · son yedek 30 saat önce'));
    expect(noticeText(en, 'backup.failed', {'host': 'atlas', 'name': 'DB', 'reason': 'exit-code'}), ('Backup failed: DB', 'atlas · unit result: exit-code'));
    expect(noticeText(tr, 'backup.failed', {'host': 'atlas', 'name': 'DB', 'reason': 'no-match'})!.$2, 'atlas · eşleşen dosya yok');
    expect(noticeText(tr, 'backup.ok', {'host': 'atlas', 'name': 'DB'}), ('Yedek düzeldi: DB', 'atlas'));
  });

  test('tercih süzgeci: yedek uyarıları ayrı, Docker servis uyarılarıyla birlikte', () {
    const off = Profile(notifications: NotificationSettings(backupAlerts: false, serviceDown: false));
    expect(noticeAllowed(off, 'backup.stale'), isFalse);
    expect(noticeAllowed(off, 'backup.ok'), isFalse);
    expect(noticeAllowed(off, 'docker.died'), isFalse);
    expect(noticeAllowed(const Profile(), 'backup.failed'), isTrue);
    expect(noticeAllowed(const Profile(), 'docker.oom'), isTrue);
  });

  test('kimlik konuları: aynı yedeğin durumları birbirinin yerine geçer, farklı yedekler ayrı', () {
    final a = noticeId('backup.stale', {'host': 'atlas', 'id': 'db'});
    expect(noticeId('backup.ok', {'host': 'atlas', 'id': 'db'}), a);
    expect(noticeId('backup.stale', {'host': 'atlas', 'id': 'obsidian'}), isNot(a));
    expect(noticeId('docker.died', {'host': 'atlas', 'container': 'web'}), noticeId('docker.oom', {'host': 'atlas', 'container': 'web'}));
    expect(a, lessThan(0x40000000));
  });

  test('bağlantılar', () {
    expect(routeForLink('tiphys://system/backups'), '/system/backups');
    expect(routeForLink('tiphys://system/events'), '/system/events');
    expect(routeForLink('tiphys://system'), '/system');
  });

  test('olay türleri', () {
    expect(eventType('backup.stale'), 'backup');
    expect(eventType('disk.full'), 'system');
    expect(eventType('agent.restarted'), 'system');
    expect(eventType('compose.updated'), 'docker'); // compose stacks fall under the Docker filter
    expect(eventType('foo.bar'), 'other');
    expect(eventTypes.toSet(), containsAll(['system', 'docker', 'backup', 'claude', 'other']));
  });

  test('yedek denetimi yardımcıları', () {
    expect(backupPathValid('~/backups/obsidian/*.json.gz'), isTrue);
    expect(backupPathValid('/srv/*/x.gz'), isFalse);
    expect(backupPathValid(' '), isFalse);
    expect(backupCheckId('Veritabanı yedeği', []), 'veritabani-yedegi');
    expect(backupCheckId('DB', ['db', 'db-2']), 'db-3');
    expect(backupCheckId('***', []), 'yedek');
  });

  test('profil: "Son olaylar" kartı seçilebilir ama varsayılan değil; yedek uyarısı tercihi şemada', () {
    expect(allHomeCards, contains('events'));
    expect(const AppSettings().cards, isNot(contains('events')));
    final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
    final p = codec.decode('''{"format": "tiphys-profile", "schemaVersion": 1,
      "app": {"home": {"cards": ["events", "infra"]}}, "notifications": {"backupAlerts": false}}''').toProfile();
    expect(p.app.cards, ['events', 'infra']);
    expect(p.notifications.backupAlerts, isFalse);
    expect(NotificationSettings.fromJson(p.notifications.toJson()).backupAlerts, isFalse);
    expect(const NotificationSettings().backupAlerts, isTrue);
  });
}
