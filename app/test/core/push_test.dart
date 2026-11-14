import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
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

  group('bildirimden izin kararı', () {
    final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
    final profile = codec.decode(File('assets/profile/example.json').readAsStringSync()).toProfile();
    final payload = jsonEncode({'link': 'tiphys://claude/s1', 'sessionId': 's1', 'requestId': 'r1'});

    test('Claude ajanına doğru oturum ve isteğe karar gider', () async {
      final calls = <(String, String, Object?)>[];
      final ok = await decideFromNotification(payload, true,
          profile: profile,
          secrets: MemorySecretStore({'agent-argo': 'tph_x'}),
          clientFor: (url, token) => _Rec(url, token, calls));
      expect(ok, isTrue);
      expect(calls.single.$1, 'https://argo.example.ts.net:7443 tph_x');
      expect(calls.single.$2, '/v1/claude/sessions/s1/permissions/r1');
      expect(calls.single.$3, {'allow': true});
    });

    test('token yoksa ya da ajan ulaşılamazsa false (kullanıcıya bildirilir)', () async {
      expect(await decideFromNotification(payload, false, profile: profile, secrets: MemorySecretStore()), isFalse);
      final down = await decideFromNotification(payload, false,
          profile: profile, secrets: MemorySecretStore({'agent-argo': 't'}), clientFor: (u, t) => _Rec(u, t, [], fail: true));
      expect(down, isFalse);
      expect(await decideFromNotification('bozuk', true, profile: profile, secrets: MemorySecretStore()), isFalse);
    });

    test('düğmeli bildirim yükünden de ekran açılır', () {
      expect(routeForPayload(payload), '/claude/session/s1');
      expect(routeForPayload('tiphys://system'), '/system');
    });
  });
}

class _Rec extends AgentClient {
  _Rec(String url, String token, this.calls, {this.fail = false}) : super(baseUrl: url, token: token);
  final List<(String, String, Object?)> calls;
  final bool fail;
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout}) async {
    if (fail) throw const AgentError('net.unreachable');
    calls.add(('$baseUrl $token', path, body));
    return {'ok': true};
  }
}
