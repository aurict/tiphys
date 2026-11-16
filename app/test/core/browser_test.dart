// 11.2/11.3 Firefox bridge, app logic: tab parsing (favicon, domain, letter), grouping by window and
// search, active tab of the focused window, reader text blocks, URL validation, summary message and live list
// controller (fake agent + fake SSE: initial load, events, reconnect with growing backoff on disconnect, stop when
// the session ends, pause in background, dispose).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/desktop/browser.dart';
import 'package:tiphys/features/desktop/browser_screen.dart' show normalizeTabUrl;
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/harness.dart';

void main() {
  group('sekmeler', () {
    final tabs = parseTabs(sampleTabs());

    test('ayrıştırma: favicon, alan adı, harf, http(s) mi', () {
      expect(tabs, hasLength(6));
      final mail = tabs.first;
      expect(mail.favicon, isNotNull);
      expect((mail.domain, mail.pinned, mail.webUrl), ('mail.example.com', true, true));
      expect(tabs[2].domain, 'youtube.com');
      expect(tabs[2].letter, 'Y');
      final about = tabs.last;
      expect((about.domain, about.webUrl, about.letter), ('', false, 'A'));
      // Broken / unsupported favicons and entries without an id are skipped.
      final bad = parseTabs([
        {'id': 1, 'title': '', 'url': null, 'favicon': 'data:image/svg+xml;base64,PHN2Zz4='},
        {'title': 'kimliksiz'},
      ]);
      expect(bad, hasLength(1));
      expect((bad.single.favicon, bad.single.label, bad.single.letter), (null, '', '?'));
    });

    test('pencereye göre gruplama ve arama (Türkçe harf duyarsız)', () {
      final g = groupTabs(tabs);
      expect([for (final (w, l) in g) '$w: ${l.map((t) => t.id).join(',')}'], ['1: 11,12,13,14', '2: 21,22']);
      expect([for (final (w, l) in groupTabs(tabs, 'İSTANBUL')) (w, l.single.id)], [(2, 21)]);
      expect(groupTabs(tabs, 'github.com').single.$2.single.id, 12);
      expect(groupTabs(tabs, 'yok-boyle-bir-sey'), isEmpty);
      // Ordered by position (even if they arrive out of order).
      final mixed = parseTabs([
        {'id': 2, 'windowId': 5, 'index': 1, 'title': 'b'},
        {'id': 1, 'windowId': 5, 'index': 0, 'title': 'a'},
        {'id': 3, 'windowId': 3, 'index': 0, 'title': 'c'},
      ]);
      expect([for (final (w, l) in groupTabs(mixed)) '$w: ${l.map((t) => t.id).join(',')}'], ['3: 3', '5: 1,2']);
    });

    test('odaktaki pencerenin etkin sekmesi: başlık eşleşmesi, yoksa en son erişilen', () {
      expect(activeTabFor(tabs, 'Hava durumu — İstanbul — Mozilla Firefox')?.id, 21);
      expect(activeTabFor(tabs, 'Tiphys — uzaktan kontrol — Mozilla Firefox')?.id, 12);
      expect(activeTabFor(tabs, 'Başka bir şey')?.id, 12); // highest lastAccessed
      expect(activeTabFor(const [], 'x'), isNull);
    });
  });

  test('okuma metni blokları', () {
    final b = readerBlocks('${sampleArticle()['text']}\n\n# Son\nsatır bir\nsatır iki\n\n\n');
    expect([for (final x in b) (x.kind, x.level, x.marker, x.text)], [
      (ReaderKind.paragraph, 0, '', 'Pencere kuralları, belirli pencerelere açılışta davranış atamanızı sağlar.'),
      (ReaderKind.heading, 2, '', 'Temel kullanım'),
      (ReaderKind.paragraph, 0, '', 'Kurallar yapılandırma dosyasına yazılır ve yeniden yüklemede uygulanır.'),
      (ReaderKind.bullet, 0, '', 'Yüzen pencere'),
      (ReaderKind.bullet, 0, '', 'Çalışma alanına taşı'),
      (ReaderKind.bullet, 0, '', 'Saydamlık'),
      (ReaderKind.heading, 3, '', 'Sıra'),
      (ReaderKind.numbered, 0, '1.', 'Sınıfı bulun'),
      (ReaderKind.numbered, 0, '2.', 'Kuralı yazın'),
      (ReaderKind.numbered, 0, '3.', 'Yeniden yükleyin'),
      (ReaderKind.paragraph, 0, '', 'Sonraki kural öncekini ezebilir; en özel kuralı en sona koyun.'),
      (ReaderKind.heading, 1, '', 'Son'),
      (ReaderKind.paragraph, 0, '', 'satır bir\nsatır iki'),
    ]);
    expect(readerBlocks(''), isEmpty);
    // "#etiket" is not a heading.
    expect(readerBlocks('#etiket').single.kind, ReaderKind.paragraph);
  });

  test('yeni sekme adresi: yalnız http/https, şemasıza https', () {
    expect(normalizeTabUrl(' example.com/a?b=1 '), 'https://example.com/a?b=1');
    expect(normalizeTabUrl('http://10.0.0.2:8080'), 'http://10.0.0.2:8080');
    for (final bad in ['', 'javascript:alert(1)', 'file:///etc/passwd', 'ftp://x.org', 'about:config', 'iki kelime', 'https://']) {
      expect(normalizeTabUrl(bad), isNull, reason: bad);
    }
  });

  test('özet mesajı: istek, başlık, adres, metin; çok uzunsa kesilir', () {
    final l = AppLocalizationsTr();
    final p = browserSummaryPrompt(l, title: 'Başlık', url: 'https://x.org', text: 'metin');
    expect(p, '${l.browserSummaryIntro}\n\n# Başlık\nhttps://x.org\n\nmetin');
    expect(browserSummaryPrompt(l, title: 't', text: 'a' * 200000).length, lessThan(200000));
  });

  test('ajan istemcisi SSE: olay/veri satırları, ping yorumu, belirteç başlığı, hata yanıtı, kapanış', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final headers = <String?>[];
    server.listen((r) async {
      headers.add(r.headers.value('X-Tiphys-Control'));
      if (r.headers.value('X-Tiphys-Control') != 'tpc_ok') {
        r.response.statusCode = 403;
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"error":{"code":"agent.control.sessionRequired","params":{}}}');
        return r.response.close();
      }
      r.response.headers.contentType = ContentType('text', 'event-stream');
      r.response.write('event: status\ndata: {"connected":true}\n\n: ping\n\nevent: tabs\ndata: {"tabs":\ndata: []}\n\n');
      await r.response.close();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      final c = AgentClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'x');
      expect(await c.sse('/v1/desktop/browser/events', headers: {'X-Tiphys-Control': 'tpc_ok'}).toList(), [
        ('status', '{"connected":true}'),
        ('tabs', '{"tabs":\n[]}'),
      ]);
      await expectLater(
        c.sse('/v1/desktop/browser/events', headers: {'X-Tiphys-Control': 'eski'}).toList(),
        throwsA(isA<AgentError>().having((e) => (e.code, e.status), 'kod', ('agent.control.sessionRequired', 403))),
      );
      c.close();
    }, _RealHttp());
    await server.close();
    expect(headers, ['tpc_ok', 'eski']);
  });

  group('canlı liste denetleyicisi', () {
    setUp(() {
      FakeAgent.calls.clear();
      FakeAgent.browser = {'connected': true, 'version': 1, 'ext': '0.1.0', 'permissions': {'content': true}};
      FakeAgent.browserTabs = sampleTabs();
      FakeAgent.browserEvents = StreamController.broadcast();
      FakeAgent.browserSubscribers = 0;
    });
    tearDown(() => FakeAgent.browser = null);

    var unreachable = false;
    BrowserTabsController make({String? token = 'tpc_fake'}) => BrowserTabsController(
          client: () async => unreachable ? throw const AgentError('net.unreachable') : FakeAgent(),
          token: () async => token,
        );

    test('yükleme, olaylar, kopunca artan aralıkla yeniden bağlanma, arka planda duraklama', () {
      fakeAsync((fa) {
        FakeAgent.browserEvents = StreamController.broadcast(); // inside the fake-time zone
        final c = make();
        var notified = 0;
        c.addListener(() => notified++);
        c.start();
        fa.flushMicrotasks();
        expect((c.status?.connected, c.status?.content, c.tabs?.length, c.error), (true, true, 6, null));
        expect(FakeAgent.browserSubscribers, 1);
        // A tab event changes the list.
        FakeAgent.browserEvents.add(('tabs', jsonEncode({'tabs': sampleTabs().take(2).toList()})));
        fa.flushMicrotasks();
        expect(c.tabs!.map((t) => t.id), [11, 12]);
        // Bridge disconnected: the list goes away; on reconnect the list is read from the agent.
        FakeAgent.browserEvents.add(('status', jsonEncode({'connected': false, 'permissions': {'content': false}})));
        fa.flushMicrotasks();
        expect((c.status!.connected, c.tabs), (false, null));
        FakeAgent.browserEvents.add(('status', jsonEncode(FakeAgent.browser)));
        fa.flushMicrotasks();
        expect(c.tabs, hasLength(6));
        // Stream closed (agent restarted) / errored: reconnects after a delay.
        final old = FakeAgent.browserEvents;
        FakeAgent.browserEvents = StreamController.broadcast();
        old.close();
        fa.elapse(const Duration(milliseconds: 900));
        expect(FakeAgent.browserSubscribers, 0);
        fa.elapse(const Duration(milliseconds: 200));
        expect(FakeAgent.browserSubscribers, 1, reason: 'ilk deneme 1 sn sonra');
        // Agent unreachable: as attempts keep failing the delay grows 1 → 2 s; reset once connected (status event).
        unreachable = true;
        FakeAgent.browserEvents.addError(const AgentError('net.unreachable'));
        fa.elapse(const Duration(milliseconds: 1100)); // 1st attempt fails
        unreachable = false;
        fa.elapse(const Duration(milliseconds: 1800));
        expect(FakeAgent.browserSubscribers, 0, reason: 'ikinci deneme 2 sn sonra');
        fa.elapse(const Duration(milliseconds: 300));
        expect(FakeAgent.browserSubscribers, 1);
        expect(browserBackoff(0), const Duration(seconds: 1));
        expect(browserBackoff(9), const Duration(seconds: 30));
        // Background: the stream closes; on return to foreground the list is re-read and the stream reopened.
        c.pause();
        fa.flushMicrotasks();
        expect(FakeAgent.browserSubscribers, 0);
        fa.elapse(const Duration(minutes: 2));
        expect(FakeAgent.browserSubscribers, 0);
        FakeAgent.calls.clear();
        c.resume();
        fa.flushMicrotasks();
        expect(FakeAgent.browserSubscribers, 1);
        expect(FakeAgent.calls.map((x) => '${x.$1} ${x.$2}'), containsAll(['GET /v1/desktop/browser/tabs', 'SSE /v1/desktop/browser/events']));
        expect(notified, greaterThan(4));
        c.dispose();
        fa.flushMicrotasks();
        expect(FakeAgent.browserSubscribers, 0);
        expect(fa.pendingTimers, isEmpty);
      });
    });

    test('oturum bitti: yeniden bağlanılmaz, hata gösterilir', () {
      fakeAsync((fa) {
        FakeAgent.browserEvents = StreamController.broadcast();
        final c = make();
        c.start();
        fa.flushMicrotasks();
        FakeAgent.browserEvents.addError(const AgentError('agent.control.sessionRequired', {}, 403));
        fa.flushMicrotasks();
        fa.elapse(const Duration(minutes: 1));
        expect((c.error as AgentError).code, 'agent.control.sessionRequired');
        expect(FakeAgent.browserSubscribers, 0);
        expect(fa.pendingTimers, isEmpty);
        c.dispose();
      });
    });

    test('bağlı değil: 10 sn arayla durum okunur, bağlanınca oturum + akış; arka planda ve çıkınca okunmaz', () {
      fakeAsync((fa) {
        FakeAgent.browserEvents = StreamController.broadcast();
        FakeAgent.browser = {'connected': false, 'version': null, 'ext': null, 'permissions': {'content': false}};
        final c = make();
        c.start();
        fa.flushMicrotasks();
        int polls() => FakeAgent.calls.where((x) => x.$1 == 'GET' && x.$2 == '/v1/desktop/browser').length;
        expect((c.status!.connected, polls()), (false, 1));
        fa.elapse(const Duration(seconds: 9));
        expect(polls(), 1);
        fa.elapse(const Duration(seconds: 1));
        expect(polls(), 2);
        // Not read in the background; back in the foreground, again every 10 s.
        c.pause();
        fa.elapse(const Duration(minutes: 1));
        expect(polls(), 2);
        c.resume();
        fa.elapse(const Duration(seconds: 10));
        expect(polls(), 3);
        // Extension connected: the session opens, the list is read, the stream opens; no more polling.
        FakeAgent.browser = {'connected': true, 'version': 1, 'ext': '0.1.0', 'permissions': {'content': true}};
        fa.elapse(const Duration(seconds: 10));
        expect((c.status!.connected, c.tabs?.length, FakeAgent.browserSubscribers), (true, 6, 1));
        final n = polls();
        fa.elapse(const Duration(minutes: 1));
        expect(polls(), n);
        c.dispose();
        fa.flushMicrotasks();

        FakeAgent.browser = {'connected': false, 'permissions': {'content': false}};
        final d = make();
        d.start();
        fa.flushMicrotasks();
        d.dispose();
        expect(fa.pendingTimers, isEmpty, reason: 'çıkınca yoklama durur');
      });
    });

    test('bağlı değil: oturum istenmez; oturumdan vazgeçilirse akış açılmaz; eski ajan hatası', () {
      fakeAsync((fa) {
        FakeAgent.browser = {'connected': false, 'version': null, 'ext': null, 'permissions': {'content': false}};
        var asked = 0;
        final c = BrowserTabsController(client: () async => FakeAgent(), token: () async => (asked++, 'tpc_fake').$2);
        c.start();
        fa.flushMicrotasks();
        expect((c.status!.connected, asked, c.tabs, c.loading), (false, 0, null, false));
        c.dispose();

        FakeAgent.browser = {'connected': true, 'permissions': {'content': false}};
        final d = make(token: null);
        d.start();
        fa.flushMicrotasks();
        expect((d.cancelled, FakeAgent.browserSubscribers, d.loading), (true, 0, false));
        d.dispose();

        FakeAgent.browser = null;
        final e = make();
        e.start();
        fa.flushMicrotasks();
        expect((e.error as AgentError).code, 'agent.route.notFound');
        e.dispose();
      });
    });
  });
}

class _RealHttp extends HttpOverrides {}
