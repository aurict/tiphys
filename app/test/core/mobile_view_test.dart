// Mobile view (11.4) data: tree → sections (recorded mousepad and Firefox trees), search by name (Turkish
// case-insensitive), controller: silent refresh on a stale generation + one retry, SSE "changed" merging, re-read +
// reconnect on disconnect, pause in background, DELETE on exit. Fake agent; nothing reaches the PC.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/push/push_service.dart' show noticeText;
import 'package:tiphys/features/desktop/mobile_view.dart';
import 'package:tiphys/features/system/agent_providers.dart' show agentErrorText;
import 'package:tiphys/features/system/events.dart' show eventType;
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/harness.dart';

List<String> _names(List<UiNode> l) => [for (final n in l) n.label];

String _shape(List<UiSection> s) => [for (final x in s) '${x.kind.name}:${x.title}(${x.chips.length}/${x.items.length})'].join(' ');

void main() {
  group('bölümler', () {
    test('mousepad: menü çubuğu çipleri, açık File menüsü kartı, tek sekme → düz grup', () {
      final s = uiSections(UiSnapshot(sampleUiMousepad()));
      expect(_shape(s), 'bar:(6/0) menu:File(0/14) group:(0/1)');
      expect(_names(s[0].chips), ['File', 'Edit', 'Search', 'View', 'Document', 'Help']);
      expect(s[0].node!.role, 'menu bar');
      expect(_names(s[1].items).take(5), ['New', 'New Window', 'New From Template', 'Open...', 'Open Recent']);
      expect(s[1].items.where((n) => !n.enabled).map((n) => n.label), ['Reload', 'Detach Tab']);
      expect(s[2].items.single.role, 'text');
    });

    test('Firefox: araç çubuğu (adres alanı açılır listeyle), sekmeler, web içeriği; şifre alanı metinsiz', () {
      final snap = UiSnapshot(sampleUiFirefox());
      final s = uiSections(snap);
      expect(_shape(s), 'bar:Gezinti(2/1) tabs:(2/0) document:Giriş(0/8)');
      expect(_names(s[0].chips), ['Geri', 'İleri']);
      expect(s[0].chips[1].enabled, isFalse);
      expect(s[0].items.single.role, 'combo box');
      expect(snap.entryOf(s[0].items.single)!.text, 'https://example.com/giris');
      expect(s[1].chips.where((t) => t.selected).single.label, 'Giriş');
      expect([for (final n in s[2].items) n.role],
          ['heading', 'entry', 'password text', 'check box', 'toggle button', 'button', 'slider', 'link'],
          reason: 'alanın adını tekrarlayan etiket atlanır');
      final pw = s[2].items[2];
      expect((pw.password, pw.text), (true, null));
      expect(s[2].items[6].value!.now, 40);
      expect(s[2].items[4].checked, isTrue); // pressed → checked
    });

    test('heading düz grubu böler, label bağlam olarak kalır, kapalı menü düğme gibi gruba girer', () {
      Map<String, Object?> n(String id, String role, String name, {String? parent, int depth = 0, List<String> states = const ['enabled']}) =>
          {'id': id, 'parent': parent, 'depth': depth, 'role': role, 'name': name, 'states': states, 'actions': ['click']};
      final s = uiSections(UiSnapshot({
        'gen': 1,
        'nodes': [
          n('0', 'heading', 'Çıkış'),
          n('1', 'combo box', 'Aygıt'),
          n('2', 'slider', 'Ses'),
          n('3', 'heading', 'Giriş'),
          n('4', 'label', 'Mikrofon kapalı'),
          n('5', 'menu', 'Seçenekler'),
          n('6', 'list item', 'Dahili', states: ['enabled', 'selected']),
        ],
      }));
      expect(_shape(s), 'group:Çıkış(0/2) group:Giriş(0/3)');
      expect(_names(s[1].items), ['Mikrofon kapalı', 'Seçenekler', 'Dahili']);
    });

    test('arama: ada göre, Türkçe harf duyarsız; menü başlığı eşleşirse menü bütün; eşleşme yoksa boş', () {
      final ff = UiSnapshot(sampleUiFirefox());
      expect(_shape(uiSections(ff, query: 'ŞİFRE')), 'document:Giriş(0/2)');
      expect(_names(uiSections(ff, query: 'şifre').single.items), ['Şifre', 'Şifremi unuttum']);
      expect(_names(uiSections(ff, query: 'geri').single.chips), ['Geri']);
      expect(uiSections(ff, query: 'kullanıcı').single.items.map((n) => n.role), ['entry']);
      expect(uiSections(ff, query: 'yok-boyle'), isEmpty);
      final mp = UiSnapshot(sampleUiMousepad());
      expect(_shape(uiSections(mp, query: 'file')), 'bar:(1/0) menu:File(0/14)');
      expect(_shape(uiSections(mp, query: 'save')), 'menu:File(0/3)');
    });
  });

  test('hata kodları ve olay kaydı metni (TR/EN)', () {
    final tr = AppLocalizationsTr(), en = AppLocalizationsEn();
    for (final code in ['unsupported', 'stale', 'timeout', 'helperMissing', 'helperFailed', 'confirmRequired', 'noAction', 'a11yBus', 'failed']) {
      for (final l in [tr, en]) {
        expect(agentErrorText(l, AgentError('agent.ui.$code')), isNot(contains('agent.ui')), reason: code);
      }
    }
    expect(agentErrorText(tr, const AgentError('agent.desktop.badAddress')), 'Geçersiz pencere adresi');
    expect(agentErrorText(en, const AgentError('agent.desktop.badAddress')), 'Invalid window address');
    expect(agentErrorText(tr, const AgentError('agent.ui.unsupported')), 'Bu pencere bileşen ağacı vermiyor; canlı ekranı kullan.');
    expect(noticeText(tr, 'ui.opened', {'class': 'firefox-esr'}), ('Mobil görünüm açıldı', 'firefox-esr'));
    expect(noticeText(en, 'ui.opened', {'class': 'kitty'}), ('Mobile view opened', 'kitty'));
    expect(eventType('ui.opened'), 'system');
  });

  group('denetleyici', () {
    setUp(() {
      FakeAgent.calls.clear();
      FakeAgent.resetUi();
    });

    List<String> uiCalls() => [
          for (final c in FakeAgent.calls)
            if (c.$2.startsWith('/v1/desktop/ui') && c.$1 != 'SSE') '${c.$1} ${c.$2}${c.$1 == 'POST' ? ' gen=${(c.$3 as Map)['gen']}' : ''}',
        ];

    UiViewController make({String? token = 'tpc_fake'}) =>
        UiViewController(client: () async => FakeAgent(), token: () async => token, address: '0x55d1a0');

    test('eski kuşak: sessizce yenilenir, aynı düğüm varsa yeni kuşakla bir kez daha denenir; yoksa hata', () async {
      final c = make();
      await c.start();
      expect(c.snap!.gen, 1);
      final geri = c.snap!.nodes.firstWhere((n) => n.label == 'Geri');
      FakeAgent.uiGen++; // another read advanced the generation on the agent
      FakeAgent.calls.clear();
      await c.send(geri, 'act', {'action': 'press'});
      expect(uiCalls(), [
        'POST /v1/desktop/ui/act gen=1',
        'GET /v1/desktop/ui',
        'POST /v1/desktop/ui/act gen=3',
        'GET /v1/desktop/ui',
      ]);
      expect(FakeAgent.calls.where((x) => x.$1 == 'GET').first.$3, {'address': '0x55d1a0'});

      // Node no longer exists (window changed): no second attempt, the error goes to the user.
      FakeAgent.uiGen++;
      FakeAgent.ui = sampleUiMousepad();
      FakeAgent.calls.clear();
      await expectLater(c.send(geri, 'act', {'action': 'press'}), throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.ui.stale')));
      expect(uiCalls(), ['POST /v1/desktop/ui/act gen=1', 'GET /v1/desktop/ui'], reason: 'düğümün kendi kuşağıyla');
      expect(c.snap!.title, 'Untitled 1 - Mousepad');

      // Other errors are not retried.
      FakeAgent.uiErrors.add(const AgentError('agent.ui.noAction', {}, 400));
      FakeAgent.calls.clear();
      final file = c.snap!.nodes.firstWhere((n) => n.label == 'File');
      await expectLater(c.send(file, 'act', {'action': 'click'}), throwsA(isA<AgentError>()));
      expect(uiCalls(), ['POST /v1/desktop/ui/act gen=6']);
      c.dispose();
    });

    test('düğüm eski ağaçtan: "changed" sonrası yol kaydıysa yeni kuşakla gönderilmez (başka düğüme basılmaz)', () async {
      final c = make();
      await c.start();
      final geri = c.snap!.nodes.firstWhere((n) => n.label == 'Geri');
      expect((geri.gen, geri.address), (1, '0x55d1a0'));
      // Tree changed while the long-press sheet was open: the same path now holds a different node.
      final shifted = sampleUiFirefox();
      final nodes = [for (final n in shifted['nodes'] as List) {...n as Map}];
      nodes.firstWhere((n) => n['id'] == geri.id)['name'] = 'Sil';
      FakeAgent.ui = {...shifted, 'nodes': nodes};
      await c.refresh();
      expect(c.snap!.gen, 2);
      FakeAgent.calls.clear();
      await expectLater(c.send(geri, 'act', {'action': 'press'}), throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.ui.stale')));
      expect(uiCalls(), ['POST /v1/desktop/ui/act gen=1', 'GET /v1/desktop/ui'], reason: 'yeniden deneme yok');
      // The node in the new tree goes with its new generation.
      FakeAgent.calls.clear();
      await c.send(c.snap!.byId(geri.id)!, 'act', {'action': 'press'});
      expect(uiCalls(), ['POST /v1/desktop/ui/act gen=3', 'GET /v1/desktop/ui']);
      c.dispose();
    });

    test('pencere değiştiyse eski pencerenin düğümü hiç gönderilmez; okuma sürerken değişirse eski ağaç gösterilmez', () async {
      final c = make();
      await c.start();
      final geri = c.snap!.nodes.firstWhere((n) => n.label == 'Geri');
      c.setAddress('0x55d1b2');
      await Future<void>.delayed(Duration.zero);
      FakeAgent.calls.clear();
      await expectLater(c.send(geri, 'act', {'action': 'press'}), throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.ui.stale')));
      expect(uiCalls().where((x) => x.startsWith('POST')), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(c.snap!.address, '0x55d1b2');
      expect(c.snap!.nodes.every((n) => n.address == '0x55d1b2'), isTrue);
      // Focus changed during a read: the old window's response is dropped, the new one is read.
      FakeAgent.calls.clear();
      final f = c.refresh();
      c.setAddress('0x55d1c4');
      await f;
      expect(c.snap!.address, '0x55d1c4');
      expect([for (final x in FakeAgent.calls) if (x.$2 == '/v1/desktop/ui') x.$3], [{'address': '0x55d1b2'}, {'address': '0x55d1c4'}]);
      c.dispose();
    });

    test('odak izleme: 300 ms sabit kalan pencereye geçilir, hızlı geçişler okunmaz, geri dönerse iptal', () {
      fakeAsync((fa) {
        final c = make();
        unawaited(c.start());
        fa.flushMicrotasks();
        int gets() => FakeAgent.calls.where((x) => x.$1 == 'GET' && x.$2 == '/v1/desktop/ui').length;
        expect(gets(), 1);
        c.follow('0x1');
        fa.elapse(const Duration(milliseconds: 100));
        c.follow('0x2');
        fa.elapse(const Duration(milliseconds: 100));
        c.follow('0x55d1a0'); // came back
        fa.elapse(const Duration(seconds: 1));
        expect((gets(), c.address), (1, '0x55d1a0'));
        c.follow('0x3');
        fa.elapse(const Duration(milliseconds: 299));
        expect(c.address, '0x55d1a0');
        fa.elapse(const Duration(milliseconds: 2));
        fa.flushMicrotasks();
        expect((gets(), c.address), (2, '0x3'));
        c.follow('0x4');
        c.dispose();
        fa.elapse(const Duration(seconds: 1));
        expect(c.address, '0x3', reason: 'çıkınca bekleyen geçiş iptal');
      });
    });

    test('vazgeçilirse oturum istenmez; desteklenmeyen pencere hata olarak kalır, akış açılmaz', () async {
      final none = make(token: null);
      await none.start();
      expect((none.cancelled, none.loading), (true, false));
      FakeAgent.ui = const AgentError('agent.ui.unsupported', {}, 422);
      final c = make();
      await c.start();
      expect((c.error as AgentError).code, 'agent.ui.unsupported');
      expect(FakeAgent.uiSubscribers, 0);
      none.dispose();
      c.dispose();
    });

    test('SSE: "changed" birleştirilir, kopunca 1 sn sonra yeniden okunur, arka planda kapalı, çıkınca DELETE', () {
      fakeAsync((fa) {
        FakeAgent.uiEvents = StreamController.broadcast(); // inside the fake-time zone
        final c = make();
        var notified = 0;
        c.addListener(() => notified++);
        unawaited(c.start());
        fa.flushMicrotasks();
        expect(c.snap, isNotNull);
        expect(FakeAgent.uiSubscribers, 1);
        expect(FakeAgent.calls.last.$2, '/v1/desktop/ui/events?address=0x55d1a0');
        int gets() => FakeAgent.calls.where((x) => x.$1 == 'GET' && x.$2 == '/v1/desktop/ui').length;
        expect(gets(), 1);

        for (var i = 0; i < 3; i++) {
          FakeAgent.uiEvents.add(('changed', '{}'));
          fa.elapse(const Duration(milliseconds: 100));
        }
        expect(gets(), 1, reason: 'olaylar sürerken okunmaz');
        fa.elapse(const Duration(milliseconds: 300));
        expect(gets(), 2, reason: 'üç olay tek okuma');
        expect(notified, greaterThan(1));

        // The agent closed the view / the connection dropped.
        final old = FakeAgent.uiEvents;
        FakeAgent.uiEvents = StreamController.broadcast();
        unawaited(old.close());
        fa.flushMicrotasks();
        expect(FakeAgent.uiSubscribers, 0);
        fa.elapse(const Duration(milliseconds: 1100));
        expect(gets(), 3);
        expect(FakeAgent.uiSubscribers, 1);

        c.pause();
        fa.flushMicrotasks();
        expect(FakeAgent.uiSubscribers, 0);
        FakeAgent.uiEvents.add(('changed', '{}'));
        fa.elapse(const Duration(seconds: 2));
        expect(gets(), 3, reason: 'arka planda okunmaz');
        c.resume();
        fa.flushMicrotasks();
        expect((gets(), FakeAgent.uiSubscribers), (4, 1));

        // Live screen focus changed: the new window's tree and stream.
        c.setAddress('0x55d1b2');
        fa.flushMicrotasks();
        expect(FakeAgent.calls.last.$2, '/v1/desktop/ui/events?address=0x55d1b2');
        expect(FakeAgent.uiSubscribers, 1);

        c.dispose();
        fa.flushMicrotasks();
        expect(FakeAgent.uiSubscribers, 0);
        expect(FakeAgent.calls.last.$1, 'DELETE');
        expect(FakeAgent.calls.last.$2, '/v1/desktop/ui');
        fa.elapse(const Duration(minutes: 1));
        expect(fa.pendingTimers, isEmpty);
      });
    });

    test('oturum bitince akış yeniden bağlanmaz', () {
      fakeAsync((fa) {
        FakeAgent.uiEvents = StreamController.broadcast();
        final c = make();
        unawaited(c.start());
        fa.flushMicrotasks();
        FakeAgent.uiEvents.addError(const AgentError('agent.control.sessionRequired', {}, 403));
        fa.flushMicrotasks();
        expect((c.error as AgentError).code, 'agent.control.sessionRequired');
        fa.elapse(const Duration(seconds: 40));
        expect(FakeAgent.uiSubscribers, 0);
        c.dispose();
        fa.flushMicrotasks();
      });
    });
  });
}
