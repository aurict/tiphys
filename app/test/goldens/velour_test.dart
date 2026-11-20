// Velour remote (System › Media › Velour): home, full player (light/dark app theme, EN, landscape), controls, gestures,
// Up next / Lyrics / PC panel, sleep timer, audio output, search, library, album page, explore and errors.
// The fake agent answers POST /v1/velour from sampleVelour() and streams velour['state']; the real player is never touched.
// To update: flutter test test/goldens/velour_test.dart --update-goldens
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/system/velour_color.dart';
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

/// Ops sent to Velour (other than reads), with their fields.
List<Map> _ops() => [
      for (final c in FakeAgent.calls)
        if (c.$2 == '/v1/velour' && !const {'state', 'queue', 'lyrics', 'suggest', 'playlists', 'eq', 'home', 'explore'}.contains((c.$3 as Map)['op'])) c.$3 as Map,
    ];

Future<void> _openPlayer(WidgetTester tester) async {
  await tester.tap(find.text('Kaç Kadeh Kırıldı').first);
  await _wait(tester);
}

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.velour = sampleVelour();
    FakeAgent.outputs = sampleOutputs();
  });

  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('velour: ana sayfa ve mini oynatıcı $v', (tester) async {
      await Harness().pump(tester, route: _route, dark: dark);
      await _wait(tester);
      expect(find.text('İyi günler'), findsOneWidget);
      expect(find.text('QUİCK PİCKS'), findsOneWidget);
      expect(find.text('Kuzu Kuzu'), findsOneWidget);
      // Mini player: the song, and the live state was opened as a stream.
      expect(find.text('Kaç Kadeh Kırıldı'), findsOneWidget);
      expect(FakeAgent.calls.where((c) => c.$2 == '/v1/velour/events'), hasLength(1));
      await golden('png/velour_home_${v}_tr.png');
      await _finish(tester);
    });

    testWidgets('velour: tam ekran oynatıcı $v', (tester) async {
      await Harness().pump(tester, route: _route, dark: dark);
      await _wait(tester);
      await _openPlayer(tester);
      expect(find.text('argo (PC) üzerinde çalıyor'), findsOneWidget);
      expect(find.text('Sezen Aksu · Gülümse'), findsOneWidget);
      expect(find.text('1:01'), findsOneWidget);
      expect(find.text('4:05'), findsOneWidget);
      expect(find.byTooltip('Tümü tekrarlanıyor'), findsOneWidget);
      expect(find.byTooltip('Beğenilenlerden çıkar'), findsOneWidget);
      await golden('png/velour_player_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('velour: oynatıcı İngilizce ve yan çevrilmiş', (tester) async {
    await Harness().pump(tester, route: _route, lang: 'en');
    await _wait(tester);
    await tester.tap(find.text('Kaç Kadeh Kırıldı').first);
    await _wait(tester);
    expect(find.text('Playing on argo (PC)'), findsOneWidget);
    await golden('png/velour_player_light_en.png');
    tester.view.physicalSize = const Size(844 * 2, 390 * 2);
    await _wait(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Kaç Kadeh Kırıldı'), findsOneWidget);
    await golden('png/velour_player_landscape_en.png');
    await _finish(tester);
  });

  testWidgets('velour: 375 px genişlikte taşma yok', (tester) async {
    await Harness().pump(tester, route: _route);
    tester.view.physicalSize = const Size(375 * 2, 667 * 2);
    await _wait(tester);
    expect(tester.takeException(), isNull);
    await _openPlayer(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('PC'));
    await _wait(tester);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('velour: oynatıcı kontrolleri doğru komutları gönderir, ekran hemen değişir', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await _openPlayer(tester);
    Future<void> tap(Finder f) async {
      await tester.tap(f);
      await _wait(tester);
    }

    await tap(find.bySemanticsLabel('Duraklat'));
    await tap(find.byTooltip('Sonraki'));
    await tap(find.byTooltip('Karıştır'));
    await tap(find.byTooltip('Tümü tekrarlanıyor'));
    await tap(find.byTooltip('Beğenilenlerden çıkar'));
    expect(_ops(), [
      {'op': 'toggle'},
      {'op': 'next'},
      {'op': 'shuffle', 'on': true},
      {'op': 'repeat', 'mode': 'one'},
      {'op': 'rate', 'videoId': 'a2', 'like': 'indifferent'},
    ]);
    // Optimistic: the fake answers with the unchanged sample state, so the pushed/answered state wins again — but the
    // like button changed while waiting, and the seek bar reads out the position.
    expect(tester.widget<Slider>(find.byType(Slider).first).semanticFormatterCallback!(61.5), '1:01 / 4:05');

    // Swipe the cover: left = next, right = previous; double-tap likes (already liked here: nothing sent).
    FakeAgent.calls.clear();
    final cover = find.byWidgetPredicate((w) => w is Semantics && (w.properties.hint ?? '').contains('kapağı kaydır'));
    await tester.drag(cover, const Offset(-200, 0));
    await _wait(tester);
    await tester.drag(cover, const Offset(200, 0));
    await _wait(tester);
    expect(_ops(), [
      {'op': 'next'},
      {'op': 'prev'},
    ]);

    // Swipe down closes the player.
    await tester.drag(find.text('ÇALIYOR'), const Offset(0, 500));
    await _wait(tester);
    expect(find.text('ÇALIYOR'), findsNothing);
    expect(find.text('İyi günler'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('velour: canlı durum yeni şarkıyı gösterir', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    final next = {...FakeAgent.velour['state'] as Map, 'rev': 8, 'track': ((FakeAgent.velour['queue'] as Map)['tracks'] as List)[2], 'index': 2};
    FakeAgent.velourEvents.add(('state', jsonEncode(next)));
    await _wait(tester);
    // Mini player now shows the new song.
    expect(find.text('Tarkan'), findsWidgets);
    // An older state that arrives late is ignored.
    FakeAgent.velourEvents.add(('state', jsonEncode({...FakeAgent.velour['state'] as Map, 'rev': 6})));
    await _wait(tester);
    expect(find.text('Kaç Kadeh Kırıldı'), findsNothing);
    await _finish(tester);
  });

  testWidgets('velour: sıradaki paneli, atlama, şarkı menüsü ve listeye kaydetme', (tester) async {
    await Harness().pump(tester, route: _route, dark: true);
    await _wait(tester);
    await _openPlayer(tester);
    await tester.tap(find.text('Sıradaki'));
    await _wait(tester);
    expect(find.text('4 şarkı · radyo sırayı uzatıyor'), findsOneWidget);
    await golden('png/velour_queue_dark_tr.png');

    await tester.tap(find.text('Kuzu Kuzu'));
    await _wait(tester);
    expect(_ops().last, {'op': 'jump', 'index': 2});

    await tester.tap(find.byTooltip('Diğer seçenekler').at(4));
    await _wait(tester);
    await tester.tap(find.text('Sıradaki çal'));
    await _wait(tester);
    final sent = _ops().last;
    expect(sent['op'], 'play-next');
    // The track goes back exactly as Velour sent it.
    expect(sent['track'], (FakeAgent.velour['queue'] as Map)['tracks'][3]);

    await tester.tap(find.byTooltip('Liste olarak kaydet'));
    await _wait(tester);
    await tester.enterText(find.byType(TextField), 'Gece');
    await tester.tap(find.text('Oluştur'));
    await _wait(tester);
    expect(_ops().last, {'op': 'save-queue', 'title': 'Gece'});
    await _finish(tester);
  });

  testWidgets('velour: şarkı menüsünde beğenmedim', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.byTooltip('Diğer seçenekler').first);
    await _wait(tester);
    await tester.tap(find.text('Beğenmedim'));
    await _wait(tester);
    expect(_ops().last, {'op': 'rate', 'videoId': 'a3', 'like': 'dislike'});
    await _finish(tester);
  });

  testWidgets('velour: karaoke sözler, etkin satır, dokununca atlar', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await _openPlayer(tester);
    await tester.tap(find.text('Sözler').first);
    await _wait(tester);
    expect(find.text('Sana kim söyledi'), findsOneWidget);
    expect(find.text('Kaynak: LRCLIB'), findsOneWidget);
    await golden('png/velour_lyrics_dark_tr.png');
    await tester.tap(find.text('Sevmenin kolay olduğunu'));
    await _wait(tester);
    expect(_ops().last, {'op': 'seek', 'seconds': 75.0});
    await _finish(tester);
  });

  testWidgets('velour: PC paneli — sesler, ses çıkışı, ekolayzer', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.byTooltip('PC kontrolleri'));
    await _wait(tester);
    expect(find.text('Velour sesi'), findsOneWidget);
    expect(find.text('PC sesi'), findsOneWidget);
    expect(find.text('WH-1000XM4'), findsOneWidget);
    expect(find.text('Bass boost'), findsOneWidget);
    await golden('png/velour_pc_light_tr.png');

    await tester.tap(find.text('WH-1000XM4'));
    await _wait(tester);
    expect(FakeAgent.calls.where((c) => c.$2 == '/v1/media/output').map((c) => c.$3), [
      {'id': 81},
    ]);
    expect(find.text('Ses artık WH-1000XM4 üzerinden çalıyor'), findsOneWidget);

    await tester.tap(find.text('Vocal'));
    await _wait(tester);
    expect(_ops().last, {'op': 'set-eq', 'preset': 'Vocal'});

    await tester.tap(find.byTooltip('Sesi kapat').first);
    await _wait(tester);
    expect(_ops().last, {'op': 'mute', 'on': true});
    await _finish(tester);
  });

  testWidgets('velour: uyku zamanlayıcısı — kur, PC uyusun (onaylı), kapat', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await _openPlayer(tester);
    await tester.tap(find.text('Uyku'));
    await _wait(tester);
    await tester.tap(find.text('30 dk'));
    await _wait(tester);
    List<Object?> sleeps() => [for (final c in FakeAgent.calls) if (c.$2 == '/v1/velour/sleep') c.$3];
    expect(sleeps().last, {'minutes': 30, 'then': 'none'});
    expect(find.text('Duraklama saati: 14:35'), findsOneWidget);
    await golden('png/velour_sleep_dark_tr.png');

    await tester.tap(find.text("PC'yi uyut"));
    await _wait(tester);
    await tester.tap(find.text('Şarkı bitince'));
    await _wait(tester);
    // Confirmation first.
    expect(find.textContaining('PC uyku moduna geçecek'), findsOneWidget);
    await tester.tap(find.text("PC'yi uyut").last);
    await _wait(tester);
    expect(sleeps().last, {'endOfTrack': true, 'then': 'suspend', 'confirm': true});
    expect(find.text('Bu şarkı bitince duraklar'), findsOneWidget);
    expect(find.text("Sonra: PC'yi uyut"), findsOneWidget);

    await tester.tap(find.text('Kapat'));
    await _wait(tester);
    expect(sleeps().last, {'then': 'none'});
    await _finish(tester);
  });

  testWidgets('velour: arama öneri, sonuç ve çalma', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.text('Ara').last);
    await _wait(tester);
    await tester.enterText(find.byType(TextField), 'sezen');
    await tester.pump(const Duration(milliseconds: 400));
    await _wait(tester);
    expect(find.text('sezen aksu gidiyorum'), findsOneWidget);
    await tester.tap(find.text('sezen aksu gidiyorum'));
    await _wait(tester);
    expect(_ops().last, {'op': 'search', 'query': 'sezen aksu gidiyorum'});
    expect(find.text('Songs'.toUpperCase()), findsOneWidget);
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

  testWidgets('velour: keşfet, kütüphane sekmeleri ve albüm sayfası', (tester) async {
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.text('Keşfet'));
    await _wait(tester);
    expect(find.text('Moods & genres'.toUpperCase()), findsOneWidget);
    await tester.tap(find.text('Kütüphane'));
    await _wait(tester);
    expect(find.text('Olds'), findsOneWidget);
    await golden('png/velour_library_light_tr.png');
    await tester.tap(find.text('Albümler'));
    await _wait(tester);
    expect(_ops().where((o) => o['op'] == 'library').map((o) => o['tab']), ['playlists', 'albums']);

    // Search → album card → page with Play / Shuffle / Radio / Save to library.
    await tester.tap(find.text('Ara').last);
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
    await tester.tap(find.text('Kütüphaneye kaydet'));
    await _wait(tester);
    expect(_ops().last, {'op': 'save-to-library', 'playlistId': 'OLAKgulumse', 'save': true});
    await _finish(tester);
  });

  testWidgets('velour: kapalıysa nasıl açılacağını söyler', (tester) async {
    FakeAgent.velour = {'state': const AgentError('agent.velour.unavailable', {}, 503)};
    await Harness().pump(tester, route: _route);
    await _wait(tester);
    expect(find.textContaining('Remote control açık mı'), findsOneWidget);
    // Velour comes up: the stream's state replaces the error without a tap.
    FakeAgent.velourEvents.add(('state', jsonEncode(sampleVelour()['state'])));
    await _wait(tester);
    expect(find.textContaining('Remote control açık mı'), findsNothing);
    expect(find.text('Kaç Kadeh Kırıldı'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('medya: Velour çalıyorsa kumanda oynatıcıyla açılır', (tester) async {
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
    await _wait(tester);
    expect(find.text('ÇALIYOR'), findsOneWidget);
    FakeAgent.media = sampleMedia();
    await _finish(tester);
  });

  test('etkin söz satırı', () {
    final ly = VLyrics(sampleVelour()['lyrics'] as Map);
    expect(ly.activeLine(10), isNull);
    expect(ly.activeLine(61.5), 2);
    expect(ly.activeLine(500), 5);
  });

  test('durum: yeni alanlar, iyimser kopya konumu ileri taşır', () {
    final at = DateTime(2026, 11, 14, 14, 5);
    final s = VState(sampleVelour()['state'] as Map, at);
    expect((s.rev, s.queueRev, s.eq, s.sleep), (7, 1234, 'Flat', null));
    final later = s.copyWith(at.add(const Duration(seconds: 10)), playing: false, like: 'indifferent');
    expect(later.playing, isFalse);
    expect(later.track!.liked, isFalse);
    expect(later.position, closeTo(71.5, 0.01));
    expect(later.rev, 7);
    final sl = VState({...sampleVelour()['state'] as Map, 'sleep': {'endsAt': 1763125800.0, 'endOfTrack': false, 'then': 'screenOff'}}, at).sleep!;
    expect((sl.endsAt!.toUtc(), sl.endOfTrack, sl.then), (DateTime.utc(2025, 11, 14, 13, 10), false, 'screenOff'));
  });

  test('kapak rengi: en renkli sık renk; gri kapakta gri; koyu ton beyaz yazıya uygun', () {
    Uint8List px(List<List<int>> colors) => Uint8List.fromList([for (final c in colors) ...c, 255]);
    // Mostly black with a lot of red and a little blue → red.
    final img = Uint8List.fromList([
      for (var i = 0; i < 40; i++) ...[5, 5, 5, 255],
      for (var i = 0; i < 30; i++) ...[220, 30, 40, 255],
      for (var i = 0; i < 5; i++) ...[20, 40, 230, 255],
    ]);
    final c = dominantColor(img)!;
    expect(HSLColor.fromColor(c).hue, anyOf(lessThan(15), greaterThan(345)));
    expect(dominantColor(px([[128, 128, 128]])), const Color(0xFF808080));
    expect(dominantColor(Uint8List(0)), isNull);
    for (final color in [const Color(0xFFFFF59D), const Color(0xFF00E5FF), c, const Color(0xFF808080)]) {
      final tone = playerTone(color);
      // White on the tone: at least 7:1.
      final contrast = (1.05) / (tone.computeLuminance() + 0.05);
      expect(contrast, greaterThan(7), reason: '$color');
    }
  });
}
