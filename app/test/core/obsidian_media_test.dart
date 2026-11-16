// 9.7 Obsidian link (encoding: Turkish characters, spaces, "/"), 9.8 media helpers, 9.9 link detection.
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/notes/obsidian.dart';
import 'package:tiphys/features/system/media.dart';
import 'package:tiphys/features/system/open_on_pc.dart';
import 'package:tiphys/features/terminal/terminal_screen.dart';
import 'package:xterm/xterm.dart';

void main() {
  final now = DateTime(2026, 11, 4, 9, 5);

  group('Obsidian bağlantısı', () {
    const cfg = ObsidianConfig(vault: 'Notlar Kasası', folder: 'Gelen kutusu/Tiphys');

    test('yeni not: değerler tam kodlanır ("/" → %2F, boşluk → %20, "+" yok), silent', () {
      final uri = obsidianUri(cfg, text: 'Şu işi çöz: ağ & DNS\n2. satır + 100%', now: now);
      final s = uri.toString();
      expect(s, startsWith('obsidian://new?'));
      expect(s, contains('vault=Notlar%20Kasas%C4%B1'));
      expect(s, contains('file=Gelen%20kutusu%2FTiphys%2F%C5%9Eu%20i%C5%9Fi%20%C3%A7%C3%B6z%20a%C4%9F%20%26%20DNS'));
      expect(s, contains('content=%C5%9Eu%20i%C5%9Fi%20%C3%A7%C3%B6z%3A%20a%C4%9F%20%26%20DNS%0A2.%20sat%C4%B1r%20%2B%20100%25'));
      expect(s, endsWith('&silent=true'));
      expect(s, isNot(contains('append')));
      expect(s, isNot(contains('+')));
      // Obsidian decodes back to the same values.
      final q = Uri.splitQueryString(uri.query);
      expect(q['file'], 'Gelen kutusu/Tiphys/Şu işi çöz ağ & DNS');
      expect(q['content'], 'Şu işi çöz: ağ & DNS\n2. satır + 100%');
      expect(q['vault'], 'Notlar Kasası');
    });

    test('günlük not: tarih deseni, append', () {
      const daily = ObsidianConfig(vault: 'Notlar', mode: 'dailyNote', dailyNotePath: 'Günlük/YYYY/YYYY-MM-DD');
      final uri = obsidianUri(daily, text: 'toplantı notu', now: now);
      expect(Uri.splitQueryString(uri.query)['file'], 'Günlük/2026/2026-11-04');
      expect(uri.toString(), contains('&append=true&silent=true'));
      // The on-screen selection can switch to a new note.
      expect(Uri.splitQueryString(obsidianUri(daily, text: 'x', now: now, daily: false).query)['file'], 'Gelen kutusu/x');
    });

    test('başlık: verilen başlık, ilk dolu satır ya da zaman damgası; yasak karakterler atılır', () {
      expect(noteTitle('\n\n# Başlık: [önemli] a/b\nikinci', now), 'Başlık önemli a b');
      expect(noteTitle('metin', now, title: '  Claude · Yayın? '), 'Claude · Yayın');
      expect(noteTitle('   \n', now), 'Not 2026-11-04 09.05');
      expect(noteTitle('...gizli', now), 'gizli');
      expect(noteTitle('a' * 100, now).length, 60);
      const root = ObsidianConfig(vault: 'v', folder: ' / ');
      expect(obsidianNotePath(root, text: 'kök', now: now), 'kök');
    });

    test('profil: obsidian ayarı JSON gidiş-dönüş, varsayılanlar', () {
      final o = ObsidianConfig.fromJson({'vault': 'Notlar'});
      expect(o.toJson(), {'vault': 'Notlar', 'folder': 'Gelen kutusu', 'mode': 'newNote', 'dailyNotePath': 'Günlük/YYYY-MM-DD'});
      final i = Integrations.fromJson({'obsidian': o.toJson()});
      expect(i.obsidian!.vault, 'Notlar');
      expect(i.toJson()['obsidian'], o.toJson());
      expect(i.copyWith(obsidian: () => null).obsidian, isNull);
    });
  });

  group('medya', () {
    test('oynatıcı adı, süre biçimi', () {
      expect(playerLabel('firefox.instance_1_42'), 'Firefox');
      expect(playerLabel('vlc'), 'VLC');
      expect(playerLabel('spotify'), 'Spotify');
      expect(mediaTime(75.4), '1:15');
      expect(mediaTime(3725), '1:02:05');
      expect(mediaTime(null), '–:––');
    });

    test('çalarken konum son sorgudan bu yana ilerler, süreyi geçmez', () {
      final at = DateTime(2026, 11, 14, 14, 5);
      MediaState st(String status) => MediaState(
            players: const [],
            player: MediaPlayer({'name': 'spotify', 'status': status, 'length': 100.0, 'position': 98.0}),
            volume: null,
            fetchedAt: at,
          );
      expect(st('Playing').positionAt(at.add(const Duration(seconds: 1))), 99.0);
      expect(st('Playing').positionAt(at.add(const Duration(seconds: 30))), 100.0);
      expect(st('Paused').positionAt(at.add(const Duration(seconds: 30))), 98.0);
    });
  });

  group("PC'de aç", () {
    test('metindeki ilk bağlantı; sondaki noktalama ve eşleşmeyen parantez atılır', () {
      expect(findUrl('Şuna bak: https://example.com/a?b=1&c=ç. Güzel'), 'https://example.com/a?b=1&c=ç');
      expect(findUrl('(bkz. https://tr.wikipedia.org/wiki/Argo_(gemi))'), 'https://tr.wikipedia.org/wiki/Argo_(gemi)');
      expect(findUrl('HTTP://EXAMPLE.COM'), 'HTTP://EXAMPLE.COM');
      expect(findUrl('ssh user@100.64.0.2'), isNull);
      expect(findUrl('file:///etc/passwd ftp://x'), isNull);
      expect(findUrl('https://'), isNull);
    });
  });

  test('terminal notu: seçim yoksa görünen ekran', () {
    final t = Terminal();
    t.write('merhaba dünya   \r\n\$ ls\r\n');
    expect(terminalNoteText(t, null), 'merhaba dünya\n\$ ls');
  });
}
