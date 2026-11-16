// 9.5 session changes (file ↔ git status matching) and 9.6 clipboard sync (notification, "Kopyala",
// phone → PC, last seen clipboard entry).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/clipboard.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/claude/session_insights.dart';
import 'package:tiphys/features/system/clipboard_sync.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';

final tr = lookupAppLocalizations(const Locale('tr'));
final en = lookupAppLocalizations(const Locale('en'));

void main() {
  test('ajan istemcisi: yolda verilen sorgu ayrı gönderilir (önceden "?" yola kodlanıp 404 oluyordu)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <Uri>[];
    server.listen((r) async {
      seen.add(r.uri);
      r.response.headers.contentType = ContentType.json;
      r.response.write('{}');
      await r.response.close();
    });
    // The test framework replaces HttpClient with a fake; here we go to a real local server.
    await HttpOverrides.runWithHttpOverrides(() async {
      final c = AgentClient(baseUrl: 'http://127.0.0.1:${server.port}/', token: 'x');
      await c.request('GET', Uri(path: '/v1/git/diff', queryParameters: {'path': '/home/u/a b', 'file': 'x.ts', 'head': 'true'}).toString());
      await c.request('GET', '/v1/git/status', query: {'path': '/p'});
      c.close();
    }, _RealHttp());
    await server.close();
    expect(seen[0].path, '/v1/git/diff');
    expect(seen[0].queryParameters, {'path': '/home/u/a b', 'file': 'x.ts', 'head': 'true'});
    expect(seen[1].queryParameters, {'path': '/p'});
  });

  group('oturum dosyaları ↔ git durumu', () {
    final status = {
      'root': '/home/user/web',
      'files': [
        {'path': 'src/a.ts', 'index': '.', 'worktree': 'M', 'untracked': false, 'conflicted': false},
        {'path': 'src/yeni.ts', 'index': '.', 'worktree': '?', 'untracked': true, 'conflicted': false},
        {'path': 'src/hazir.ts', 'index': 'A', 'worktree': '.', 'untracked': false, 'conflicted': false},
        {'path': 'README.md', 'index': '.', 'worktree': 'M', 'untracked': false, 'conflicted': false},
      ],
    };

    test('göreli yollar oturum klasörüne göre, depo dışı ve değişmemiş dosyalar ayrılır', () {
      final files = mapSessionFiles(
        ['/home/user/web/src/a.ts', 'src/yeni.ts', './src/../src/hazir.ts', '/home/user/web/src/eski.ts', '/etc/hosts', '/home/user/website/x.ts'],
        '/home/user/web',
        status,
      );
      expect([for (final f in files) f.rel], ['src/a.ts', 'src/yeni.ts', 'src/hazir.ts', 'src/eski.ts', null, null]);
      expect([for (final f in files) f.git != null], [true, true, true, false, false, false]);
      expect([for (final f in files) f.isNew], [false, true, true, false, false, false]);
    });

    test('alt klasördeki oturum: depo kökü durumdan gelir; durum yoksa eşleşme yok', () {
      final f = mapSessionFiles(['a.ts'], '/home/user/web/src', status).single;
      expect(f.rel, 'src/a.ts');
      expect(mapSessionFiles(['a.ts'], '/home/user/web/src', null).single.rel, isNull);
    });
  });

  group('bildirim metinleri', () {
    test('PC panosu: tek satırlık kısa önizleme; git olayları', () {
      final long = 'ilk satır\n\n  ikinci\tsatır ${'x' * 200}';
      final (title, body) = noticeText(tr, 'clipboard.pc', {'text': long})!;
      expect(title, "PC'de kopyalandı");
      expect(body, startsWith('ilk satır ikinci satır x'));
      expect(body.length, 81);
      expect(body, endsWith('…'));
      expect(noticeText(en, 'clipboard.pc', {'text': 'ssh a@b'}), ('Copied on PC', 'ssh a@b'));
      expect(noticeText(tr, 'git.committed', {'repo': 'web', 'branch': 'main', 'hash': 'abc1234', 'files': 2, 'subject': 'Testler'}),
          ('Commit: web · main', 'Testler · abc1234'));
      expect(noticeText(en, 'git.pushed', {'repo': 'web', 'branch': 'tiphys/1'}), ('Push: web', 'tiphys/1'));
    });

    test('tercih, sabit kimlik ve gizli/sessiz Android ayrıntıları', () {
      expect(noticeAllowed(const Profile(), 'clipboard.pc'), isTrue);
      expect(noticeAllowed(const Profile(notifications: NotificationSettings(clipboardFromPc: false)), 'clipboard.pc'), isFalse);
      expect(noticeId('clipboard.pc', {'text': 'a'}), noticeId('clipboard.pc', {'text': 'b'}));
      expect(noticeId('clipboard.pc', {}), lessThan(0x40000000));
      final d = clipboardNotificationDetails(tr);
      expect(d.visibility, NotificationVisibility.secret); // never shown on the lock screen
      expect(d.importance, Importance.low);
      expect(d.silent, isTrue);
      expect(d.actions!.single.id, actionCopyClipboard);
      expect(d.actions!.single.title, 'Kopyala');
      expect(d.actions!.single.showsUserInterface, isFalse); // the app does not open
    });
  });

  group('Kopyala düğmesi ve son görülen pano', () {
    test('yükteki metin panoya yazılır ve görüldü işaretlenir; bozuk yük ya da hata false', () async {
      final written = <String>[];
      final seen = ClipboardSeen(() async => null);
      final payload = jsonEncode({'clipboard': 'ssh user@100.64.0.2'});
      expect(await copyFromNotification(payload, setClipboard: (t) async => written.add(t), seen: seen), isTrue);
      expect(written, ['ssh user@100.64.0.2']);
      expect(await seen.isNew('ssh user@100.64.0.2'), isFalse);
      expect(await copyFromNotification('tiphys://system', setClipboard: (t) async => written.add(t)), isFalse);
      expect(await copyFromNotification(payload, setClipboard: (t) async => throw Exception('kanal yok')), isFalse);
      expect(written, hasLength(1));
    });

    test('dosyada metnin kendisi değil tuzlu özeti durur; başka örnek (arka plan) aynı dosyayı görür', () async {
      final dir = Directory.systemTemp.createTempSync('tiphys-clip');
      final a = ClipboardSeen(() async => dir.path);
      const secret = 'gizli-metin-123';
      expect(await a.isNew(secret), isTrue);
      await a.mark(secret);
      final raw = File('${dir.path}/clipboard-seen.json').readAsStringSync();
      expect(raw, isNot(contains(secret)));
      final b = ClipboardSeen(() async => dir.path);
      expect(await b.isNew(secret), isFalse);
      await b.mark('başka');
      expect(await a.isNew(secret), isTrue); // re-reads file a
    });
  });

  group('telefon → PC', () {
    Profile profile({bool on = true, String? hostId, String? claudeHost = 'argo'}) => Profile(
          hosts: [
            const Host(id: 'orion', name: 'Orion', address: 'orion'),
            const Host(id: 'argo', name: 'Argo', address: 'argo', agent: AgentRef(url: 'https://argo', tokenRef: 'secret:agent-argo')),
            const Host(id: 'atlas', name: 'Atlas', address: 'atlas', agent: AgentRef(url: 'https://atlas', tokenRef: 'secret:agent-atlas')),
          ],
          claude: ClaudeSettings(agentHostId: claudeHost),
          notifications: NotificationSettings(clipboardToPc: on, clipboardHostId: hostId),
        );

    test('PC seçimi: seçili host, yoksa Claude hostu, yoksa ajanlı ilk host; ajansız host seçilmez', () {
      expect(clipboardHost(profile())!.id, 'argo');
      expect(clipboardHost(profile(hostId: 'atlas'))!.id, 'atlas');
      expect(clipboardHost(profile(hostId: 'orion'))!.id, 'argo');
      expect(clipboardHost(profile(claudeHost: null))!.id, 'argo');
      expect(clipboardHost(profile(claudeHost: 'orion', hostId: null))!.id, 'argo');
    });

    test('kapalıyken pano okunmaz; değişince bir kez gönderilir; hata olursa sonra yeniden denenir', () async {
      var reads = 0;
      var clip = 'kopya 1';
      final sent = <(String, String)>[];
      var fail = false;
      final seen = ClipboardSeen(() async => null);
      Future<bool> run(Profile p) => syncClipboardToPc(
            profile: p,
            read: () async {
              reads++;
              return clip;
            },
            seen: seen,
            send: (h, t) async {
              if (fail) throw Exception('ajan kapalı');
              sent.add((h.id, t));
            },
          );
      expect(await run(profile(on: false)), isFalse);
      expect(reads, 0);
      expect(await run(profile()), isTrue);
      expect(await run(profile()), isFalse); // unchanged
      expect(sent, [('argo', 'kopya 1')]);
      clip = 'kopya 2';
      fail = true;
      await expectLater(run(profile(hostId: 'atlas')), throwsException);
      fail = false;
      expect(await run(profile(hostId: 'atlas')), isTrue);
      expect(sent.last, ('atlas', 'kopya 2'));
      // Text that came from the PC via "Kopyala" is not sent back.
      await copyFromNotification(jsonEncode({'clipboard': 'pc metni'}), setClipboard: (t) async => clip = t, seen: seen);
      expect(await run(profile()), isFalse);
      clip = '   ';
      expect(await run(profile()), isFalse);
      expect(sent, hasLength(2));
    });

    test('profil: yeni alanlar şemadan geçer ve geri okunur', () {
      final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
      final p = codec.decode(codec.encode(profile(hostId: 'atlas'))).toProfile();
      expect((p.notifications.clipboardToPc, p.notifications.clipboardFromPc, p.notifications.clipboardHostId), (true, true, 'atlas'));
      expect(codec.decode(codec.encode(const Profile())).toProfile().notifications.clipboardToPc, isFalse);
    });
  });
}

class _RealHttp extends HttpOverrides {}
