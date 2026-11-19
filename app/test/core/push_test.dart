import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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

  test('Claude bitti bildirimi: özet + dosya · maliyet · süre; eski ajanın eksik alanları atlanır', () {
    final tr = lookupAppLocalizations(const Locale('tr'));
    final en = lookupAppLocalizations(const Locale('en'));
    expect(noticeText(tr, 'claude.done', {'title': 'Testler', 'summary': 'İki test düzeltildi', 'files': 2, 'cost': 0.37, 'seconds': 125}),
        ('Claude bitirdi: Testler', 'İki test düzeltildi\n2 dosya değişti · \$0.37 · 2 dk'));
    expect(noticeText(en, 'claude.done', {'title': 'T', 'files': 1, 'cost': 0, 'seconds': 9})!.$2, '1 file changed · 9 s');
    expect(noticeText(tr, 'claude.done', {'title': 'Eski', 'cost': 0.5})!.$2, '\$0.50');
  });

  test('uzun komut eşiği: kısa süren başarılı komut bildirilmez, hata her zaman; kapalıysa hiçbiri', () {
    const p60 = Profile();
    expect(noticeAllowed(p60, 'command.done', {'seconds': 30}), isFalse);
    expect(noticeAllowed(p60, 'command.done', {'seconds': 61}), isTrue);
    expect(noticeAllowed(p60, 'command.failed', {'seconds': 2}), isTrue);
    const off = Profile(notifications: NotificationSettings(longCommandSeconds: 0));
    expect(noticeAllowed(off, 'command.done', {'seconds': 999}), isFalse);
  });

  test('bildirim kimlikleri: aynı konu aynı kimlik, farklı konu farklı kimlik', () {
    final off = noticeId('host.offline', {'host': 'argo'});
    expect(noticeId('host.online', {'host': 'argo'}), off); // back online, replaces the offline one
    expect(noticeId('host.offline', {'host': 'atlas'}), isNot(off));
    expect(noticeId('disk.full', {'host': 'a', 'mount': '/'}), noticeId('disk.ok', {'host': 'a', 'name': '/'}));
    final done = noticeId('claude.done', {}, link: 'tiphys://claude/s1');
    expect(noticeId('claude.error', {}, link: 'tiphys://claude/s1'), done);
    // Each approval request is a separate notification (two permission requests can be pending at once); topic ids are
    // below 2^30.
    expect(noticeId('claude.waiting', {}, link: 'tiphys://claude/s1', requestId: 'r1'), isNot(noticeId('claude.waiting', {}, link: 'tiphys://claude/s1', requestId: 'r2')));
    expect(done, lessThan(0x40000000));
    expect(noticeId('command.done', {'host': 'a'}), greaterThanOrEqualTo(0x40000000));
  });

  test('derin bağlantılar', () {
    expect(routeForLink('tiphys://claude/abc'), '/claude/session/abc');
    expect(routeForLink('tiphys://system'), '/system');
    expect(routeForLink('https://kotu.example'), isNull);
  });

  group('PC\'yi kullanan Claude: arka plan Durdur/Uzat', () {
    final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
    final profile = codec.decode(File('assets/profile/example.json').readAsStringSync()).toProfile();
    final hold = PcHold(hostId: 'argo', sessionId: 'pc1', title: 'Hava', token: 'tpc_x', expiresAt: DateTime.utc(2026, 11, 14, 11, 20));

    test('metinler, tercihler, kimlikler', () {
      final tr = lookupAppLocalizations(const Locale('tr'));
      expect(noticeText(tr, 'claude.pcEnded', {'title': 'Hava', 'reason': 'expired', 'working': 1}), ('Claude durdu', 'Hava · kontrol süresi doldu'));
      expect(noticeText(tr, 'claude.pcEnded', {'title': 'Hava', 'reason': 'shutdown'})!.$2, 'Hava · uzaktan kontrol kapandı');
      expect(noticeText(tr, 'claude.pcExpiring', {'title': 'Hava', 'minutes': 2}), ('PC kontrolü 2 dk içinde bitiyor', 'Hava'));
      const p = Profile(claude: ClaudeSettings(notifyError: false, notifyWaiting: false));
      expect(noticeAllowed(p, 'claude.pcEnded'), isFalse);
      expect(noticeAllowed(p, 'claude.pcExpiring'), isFalse);
      expect(noticeAllowed(const Profile(), 'claude.pcExpiring'), isTrue);
      // The check-finished notification replaces the session's "done/error" notification.
      expect(noticeId('claude.pcEnded', {}, link: 'tiphys://claude/pc1'), noticeId('claude.done', {}, link: 'tiphys://claude/pc1'));
      expect(routeForPayload(jsonEncode({'link': 'tiphys://claude/pc1', 'sessionId': 'pc1'})), '/claude/session/pc1');
      // Persistent notification: not dismissible, countdown, Stop button (without opening the app).
      final d = pcOngoingDetails(tr, hold.expiresAt);
      expect([d.ongoing, d.autoCancel, d.usesChronometer, d.chronometerCountDown, d.when], [true, false, true, true, hold.expiresAt.millisecondsSinceEpoch]);
      expect(d.actions!.single.id, actionPcStop);
      expect(d.actions!.single.showsUserInterface, isFalse);
      expect(d.actions!.single.cancelNotification, isFalse); // the notification stays if stopping fails
      expect(d.visibility, isNull); // Stop is usable on the lock screen
      expect(PcHold.fromJson(jsonEncode(hold.toJson()))!.expiresAt, hold.expiresAt.toLocal());
    });

    test('kilit ekranı: PC izin isteği ve Uzat hiç gösterilmez (secret); diğer izin istekleri olduğu gibi', () {
      expect(lockScreenVisibility('claude.pcExpiring', {}, 'pc1', null), NotificationVisibility.secret);
      expect(lockScreenVisibility('claude.waiting', {'pc': 1}, 's9', null), NotificationVisibility.secret);
      expect(lockScreenVisibility('claude.waiting', {}, 'pc1', 'pc1'), NotificationVisibility.secret); // telefonda tutulan PC oturumu
      expect(lockScreenVisibility('claude.waiting', {}, 's1', 'pc1'), isNull);
      expect(lockScreenVisibility('claude.waiting', {}, null, null), isNull);
      expect(lockScreenVisibility('claude.done', {'pc': 1}, 'pc1', 'pc1'), isNull);
    });

    test('Durdur: Claude kesilir, kontrol kapanır (belirteçle), saklı belirteç silinir', () async {
      final calls = <(String, String, Object?)>[];
      final secrets = MemorySecretStore({'agent-argo': 'tph_x', pcControlSecretId: jsonEncode(hold.toJson())});
      final ok = await pcStopFromNotification(profile: profile, secrets: secrets, clientFor: (u, t) => _Rec(u, t, calls));
      expect(ok, isTrue);
      expect(calls.map((c) => c.$2), ['/v1/claude/sessions/pc1/interrupt', 'DELETE /v1/desktop/control/session tpc_x']);
      expect(await secrets.read(pcControlSecretId), isNull);
      // No registration or agent unreachable: false (reported to the user), the registration is not deleted.
      expect(await pcStopFromNotification(profile: profile, secrets: MemorySecretStore({'agent-argo': 'x'})), isFalse);
      final kept = MemorySecretStore({'agent-argo': 'x', pcControlSecretId: jsonEncode(hold.toJson())});
      expect(await pcStopFromNotification(profile: profile, secrets: kept, clientFor: (u, t) => _Rec(u, t, [], fail: true)), isFalse);
      expect(await kept.read(pcControlSecretId), isNotNull);
    });

    test('Uzat: belirteçle 15 dk, yeni bitiş saklanır', () async {
      final calls = <(String, String, Object?)>[];
      final secrets = MemorySecretStore({'agent-argo': 'tph_x', pcControlSecretId: jsonEncode(hold.toJson())});
      final next = await pcExtendFromNotification(profile: profile, secrets: secrets, clientFor: (u, t) => _Rec(u, t, calls, expiresAt: '2026-11-14T11:35:00Z'));
      expect(next!.expiresAt, DateTime.utc(2026, 11, 14, 11, 35).toLocal());
      expect(calls.single.$2, 'POST /v1/desktop/control/session/extend tpc_x');
      expect(calls.single.$3, {'minutes': 15});
      expect(PcHold.fromJson(await secrets.read(pcControlSecretId))!.expiresAt, next.expiresAt);
      expect(await pcExtendFromNotification(profile: profile, secrets: secrets, clientFor: (u, t) => _Rec(u, t, [], fail: true)), isNull);
    });
  });

  group('bildirimden izin kararı', () {
    final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
    final profile = codec.decode(File('assets/profile/example.json').readAsStringSync()).toProfile();
    const sid = '11111111-2222-4333-8444-555555555555';
    const rid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    final payload = jsonEncode({'link': 'tiphys://claude/$sid', 'sessionId': sid, 'requestId': rid});

    test('Claude ajanına doğru oturum ve isteğe karar gider', () async {
      final calls = <(String, String, Object?)>[];
      final ok = await decideFromNotification(payload, true,
          profile: profile,
          secrets: MemorySecretStore({'agent-argo': 'tph_x'}),
          clientFor: (url, token) => _Rec(url, token, calls));
      expect(ok, isTrue);
      expect(calls.single.$1, 'https://argo.example.ts.net:7443 tph_x');
      expect(calls.single.$2, '/v1/claude/sessions/$sid/permissions/$rid');
      expect(calls.single.$3, {'allow': true});
    });

    test('kimlikler biçime uymazsa hiçbir istek gitmez (yol kaçışı yok)', () async {
      for (final bad in [
        {'link': 'tiphys://claude/x', 'sessionId': '../../security/x', 'requestId': rid},
        {'link': 'tiphys://claude/x', 'sessionId': sid, 'requestId': 'r1?x=1'},
        {'link': 'tiphys://agy/x', 'sessionId': 'agy-../../../x', 'requestId': 'aaaaaaaaaaaa'},
        {'link': 'tiphys://agy/x', 'sessionId': 'agy-aaaaaaaaaaaa', 'requestId': '..'},
      ]) {
        final calls = <(String, String, Object?)>[];
        final ok = await decideFromNotification(jsonEncode(bad), true,
            profile: profile, secrets: MemorySecretStore({'agent-argo': 'tph_x'}), clientFor: (url, token) => _Rec(url, token, calls));
        expect(ok, isFalse, reason: '$bad');
        expect(calls, isEmpty, reason: '$bad');
      }
    });

    test('token yoksa ya da ajan ulaşılamazsa false (kullanıcıya bildirilir)', () async {
      expect(await decideFromNotification(payload, false, profile: profile, secrets: MemorySecretStore()), isFalse);
      final down = await decideFromNotification(payload, false,
          profile: profile, secrets: MemorySecretStore({'agent-argo': 't'}), clientFor: (u, t) => _Rec(u, t, [], fail: true));
      expect(down, isFalse);
      expect(await decideFromNotification('bozuk', true, profile: profile, secrets: MemorySecretStore()), isFalse);
    });

    test('düğmeli bildirim yükünden de ekran açılır', () {
      expect(routeForPayload(payload), '/claude/session/$sid');
      expect(routeForPayload('tiphys://system'), '/system');
    });
  });
}

class _Rec extends AgentClient {
  _Rec(String url, String token, this.calls, {this.fail = false, this.expiresAt}) : super(baseUrl: url, token: token);
  final List<(String, String, Object?)> calls;
  final bool fail;
  final String? expiresAt;
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    if (fail) throw const AgentError('net.unreachable');
    // Calls with a control token header are recorded as "METHOD path token".
    final ctl = headers?['X-Tiphys-Control'];
    calls.add(('$baseUrl $token', ctl == null ? path : '$method $path $ctl', body));
    return {'ok': true, if (expiresAt != null) 'expiresAt': expiresAt};
  }
}
