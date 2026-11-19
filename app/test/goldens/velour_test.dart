// Velour remote (System › Media › Velour): tabs, controls, song menu, search, library, album page, lyrics and errors.
// The fake agent answers POST /v1/velour from sampleVelour(); the real player is never touched.
// To update: flutter test test/goldens/velour_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/system/velour_data.dart';

import '../helpers/harness.dart';

const _route = '/system/velour?host=argo';

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
  debugDisableShadows = true;
}

Future<void> _wait(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

/// Ops sent to Velour (other than polling), with their fields.
List<Map> _ops() => [
      for (final c in FakeAgent.calls)
        if (c.$2 == '/v1/velour' && !const {'state', 'queue', 'lyrics', 'suggest', 'playlists'}.contains((c.$3 as Map)['op'])) c.$3 as Map,
    ];

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.velour = sampleVelour();
  });

  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('velour: çalıyor $v', (tester) async {
      await Harness().pump(tester, route: _route, dark: dark);
      await _wait(tester);
      expect(find.text('Kaç Kadeh Kırıldı'), findsOneWidget);
      expect(find.text('Sezen Aksu · Gülümse'), findsOneWidget);
      expect(find.text('1:01'), findsOneWidget);
      expect(find.text('4:05'), findsOneWidget);
      expect(find.text('Beğenildi'), findsOneWidget);
      expect(find.byTooltip('Tümü tekrarlanıyor'), findsOneWidget);
      await golden('png/velour_now_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('velour: kontroller doğru komutları gönderir', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    Future<void> tap(Finder f) async {
      await tester.tap(f);
      await _wait(tester);
    }

    await tap(find.byIcon(LucideIcons.pause).first);
    await tap(find.byTooltip('Sonraki'));
    await tap(find.byTooltip('Karıştır'));
    await tap(find.byTooltip('Tümü tekrarlanıyor'));
    await tap(find.text('Beğenildi'));
    await tap(find.byTooltip('Sesi kapat'));
    expect(_ops(), [
      {'op': 'toggle'},
      {'op': 'next'},
      {'op': 'shuffle', 'on': true},
      {'op': 'repeat', 'mode': 'one'},
      {'op': 'rate', 'videoId': 'a2', 'like': 'indifferent'},
      {'op': 'mute', 'on': true},
    ]);
    expect(tester.widget<Slider>(find.byType(Slider).first).semanticFormatterCallback!(61.5), '1:01 / 4:05');
    expect(tester.widget<Slider>(find.byType(Slider).last).semanticFormatterCallback!(70), 'Ses düzeyi %70');
    await _finish(tester);
  });

  testWidgets('velour: koyu temada mini oynatıcı okunur', (tester) async {
    await Harness().pump(tester, route: _route, dark: true);
    await _wait(tester);
    await tester.tap(find.text('Sıradaki'));
    await _wait(tester);
    await golden('png/velour_queue_dark_tr.png');
    await _finish(tester);
  });

  testWidgets('velour: sıradaki listesi, atlama ve şarkı menüsü', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.text('Sıradaki'));
    await _wait(tester);
    expect(find.text('4 şarkı · radyo sırayı uzatıyor'), findsOneWidget);
    expect(find.text('Kuzu Kuzu'), findsOneWidget);
    await golden('png/velour_queue_light_tr.png');

    await tester.tap(find.text('Kuzu Kuzu'));
    await _wait(tester);
    expect(_ops().last, {'op': 'jump', 'index': 2});

    await tester.tap(find.byTooltip('Diğer seçenekler').at(3));
    await _wait(tester);
    await tester.tap(find.text('Sıradaki çal'));
    await _wait(tester);
    final sent = _ops().last;
    expect(sent['op'], 'play-next');
    // The track goes back exactly as Velour sent it.
    expect(sent['track'], (FakeAgent.velour['queue'] as Map)['tracks'][3]);
    expect(find.text('“Tüm Bir Yaşam” sıradaki'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('velour: arama öneri, sonuç ve çalma', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.text('Ara'));
    await _wait(tester);
    await tester.enterText(find.byType(TextField), 'sezen');
    await tester.pump(const Duration(milliseconds: 400));
    await _wait(tester);
    expect(find.text('sezen aksu gidiyorum'), findsOneWidget);
    await tester.tap(find.text('sezen aksu gidiyorum'));
    await _wait(tester);
    expect(_ops().last, {'op': 'search', 'query': 'sezen aksu gidiyorum'});
    expect(find.text('Songs'.toUpperCase()), findsOneWidget);
    expect(find.text('Gülümse'), findsWidgets);
    await golden('png/velour_search_light_tr.png');

    // A song plays the whole section from that song.
    await tester.tap(find.text('Gidiyorum'));
    await _wait(tester);
    final play = _ops().last;
    expect(play['op'], 'play');
    expect(play['start'], 0);
    expect((play['tracks'] as List).map((t) => (t as Map)['videoId']), ['a1', 'a2', 'a3']);
    await _finish(tester);
  });

  testWidgets('velour: kütüphane sekmeleri ve albüm sayfası', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.text('Kütüphane'));
    await _wait(tester);
    expect(find.text('Olds'), findsOneWidget);
    await golden('png/velour_library_light_tr.png');
    await tester.tap(find.text('Albümler'));
    await _wait(tester);
    expect(_ops().where((o) => o['op'] == 'library').map((o) => o['tab']), ['playlists', 'albums']);
    await tester.ensureVisible(find.text('Beğenilenler'));
    await tester.pump();
    await tester.tap(find.text('Beğenilenler'));
    await _wait(tester);
    expect(_ops().last, {'op': 'liked'});

    // Search → album card → page with Play / Shuffle / Radio.
    await tester.tap(find.text('Ara'));
    await _wait(tester);
    await tester.enterText(find.byType(TextField), 'gülümse');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _wait(tester);
    await tester.tap(find.text('Deliveren'));
    await _wait(tester);
    expect(_ops().last, {'op': 'page', 'id': 'MPREb'});
    expect(find.text('10 songs • 45 minutes'), findsOneWidget);
    await golden('png/velour_album_light_tr.png');
    await tester.tap(find.text('Karışık çal'));
    await _wait(tester);
    expect(_ops().last, containsPair('shuffle', true));
    await tester.tap(find.text('Radyo başlat'));
    await _wait(tester);
    expect(_ops().last, {'op': 'play-target', 'target': {'kind': 'watch', 'videoId': null, 'playlistId': 'RDAMPLgulumse', 'params': 'wAEB'}});
    await _finish(tester);
  });

  testWidgets('velour: zamanlı sözler, etkin satır', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.text('Sözler'));
    await _wait(tester);
    expect(find.text('Sana kim söyledi'), findsOneWidget);
    expect(find.text('Kaynak: LRCLIB'), findsOneWidget);
    await golden('png/velour_lyrics_light_tr.png');
    await tester.tap(find.text('Sevmenin kolay olduğunu'));
    await _wait(tester);
    expect(_ops().last, {'op': 'seek', 'seconds': 75.0});
    await _finish(tester);
  });

  test('etkin söz satırı', () {
    final ly = VLyrics(sampleVelour()['lyrics'] as Map);
    expect(ly.activeLine(10), isNull);
    expect(ly.activeLine(61.5), 2);
    expect(ly.activeLine(500), 5);
  });

  testWidgets('velour: kapalıysa nasıl açılacağını söyler', (tester) async {
    FakeAgent.velour = {'state': const AgentError('agent.velour.unavailable', {}, 503)};
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    expect(find.textContaining('Remote control açık mı'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('medya: Velour çalıyorsa kumandaya giriş', (tester) async {
    FakeAgent.media = {
      'state': {
        'players': [{'name': 'velour', 'status': 'Playing'}],
        'player': {
          'name': 'velour', 'status': 'Playing', 'title': 'Kaç Kadeh Kırıldı', 'artist': 'Sezen Aksu', 'album': null,
          'length': 245.0, 'position': 61.5, 'artUrl': null, 'localArt': false, 'artId': null,
        },
      },
      'volume': {'percent': 60, 'muted': false},
    };
    await Harness().pump(tester, route: '/system/media?host=argo');
    await _wait(tester);
    await tester.tap(find.text('Velour kumandasını aç'));
    await _wait(tester);
    expect(find.byIcon(LucideIcons.skipForward), findsWidgets);
    expect(find.text('Çalıyor'), findsOneWidget);
    FakeAgent.media = sampleMedia();
    await _finish(tester);
  });
}
