import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';

void main() {
  test('bildirim metinleri iki dilde', () {
    final tr = lookupAppLocalizations(const Locale('tr'));
    final en = lookupAppLocalizations(const Locale('en'));
    expect(noticeText(tr, 'host.offline', {'host': 'argo', 'minutes': 3}), ('argo çevrimdışı', '3 dakikadır yanıt yok'));
    expect(noticeText(en, 'claude.waiting', {'title': 'Testler', 'tool': 'Bash'}), ('Claude needs your approval', 'Testler · wants to use Bash'));
    expect(noticeText(tr, 'bilinmeyen', {}), isNull);
  });

  test('tercihlere göre süzme', () {
    const p = Profile(claude: ClaudeSettings(notifyDone: false), notifications: NotificationSettings(pcOffline: false));
    expect(noticeAllowed(p, 'claude.done'), isFalse);
    expect(noticeAllowed(p, 'claude.waiting'), isTrue);
    expect(noticeAllowed(p, 'host.offline'), isFalse);
  });

  test('derin bağlantılar', () {
    expect(routeForLink('tiphys://claude/abc'), '/claude/session/abc');
    expect(routeForLink('tiphys://system'), '/system');
    expect(routeForLink('https://kotu.example'), isNull);
  });
}
