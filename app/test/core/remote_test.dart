// 11.1 Smart toolbar: shortcut text (same rules as the agent's key table), class → profile mapping (including flatpak
// classes), matching of user remotes, action → WS event sequence, profile JSON (schema + model).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/desktop/remote.dart';

Map<String, Object> key(String k, [List<String> mods = const []]) => {'type': 'key', 'key': k, 'mods': mods};

void main() {
  group('kısayol metni', () {
    test('ajanın tuş tablosuyla aynı adlar (agent/src/desktop_input.ts KEYS)', () {
      final src = File('../agent/src/desktop_input.ts').readAsStringSync();
      final table = RegExp(r'export const KEYS[^{]*\{([\s\S]*?)\};').firstMatch(src)!.group(1)!;
      final names = RegExp(r'"?([A-Za-z0-9]+)"?:\s*\d+').allMatches(table).map((m) => m.group(1)!).toSet();
      final named = names.where((n) => !RegExp(r'^[A-Z0-9]$').hasMatch(n)).toSet();
      expect(named, liveKeyNames);
      expect(names.where((n) => RegExp(r'^[A-Z0-9]$').hasMatch(n)), hasLength(36));
    });

    test('ayrıştırma, değiştirici sırası, etiket', () {
      expect(parseCombo('ctrl+shift+t')!.event, key('T', ['ctrl', 'shift']));
      expect(parseCombo('Shift + Ctrl + T')!.mods, ['ctrl', 'shift']);
      expect(parseCombo('alt+Left')!.event, key('Left', ['alt']));
      expect(parseCombo('F5')!.event, key('F5'));
      expect(parseCombo('f11')!.key, 'F11');
      expect(parseCombo('ctrl+alt+r')!.label, 'Ctrl+Alt+R');
      expect(parseCombo('ctrl+KPPlus')!.label, 'Ctrl+Num +');
      expect(parseCombo('ctrl+PageDown')!.label, 'Ctrl+PgDn');
      expect(parseCombo('super')!.event, key('Super'));
      expect(parseCombo('super+e')!.event, key('E', ['super']));
      expect(parseCombo('Space')!.event, key('Space'));
      expect(parseCombo('esc')!.key, 'Esc');
      expect(parseCombo('ctrl+0')!.event, key('0', ['ctrl']));
    });

    test('ajanın reddedeceği kısayollar geçersiz', () {
      for (final bad in ['', 't', 'shift+t', '5', 'ctrl+', '+', 'ctrl+`', 'ctrl+/', 'ctrl+-', 'ctrl+=', 'ctrl+ğ', 'hyper+a', 'ctrl+a+b', 'F13', 'rm -rf', 'ctrl+shift+alt+super+ctrl+t']) {
        expect(parseCombo(bad), isNull, reason: bad);
      }
    });
  });

  group('profil eşleme', () {
    test('sınıf → profil (büyük/küçük harf, flatpak, initialClass, genel)', () {
      final cases = {
        'firefox': 'firefox',
        'firefox-esr': 'firefox',
        'org.mozilla.firefox': 'firefox',
        'code': 'vscode',
        'Code': 'vscode',
        'com.visualstudio.code': 'vscode',
        'code-oss': 'vscode',
        'dev.zed.Zed': 'zed',
        'kitty': 'kitty',
        'org.gnome.Nautilus': 'nautilus',
        'org.kde.dolphin': 'dolphin',
        'mpv': 'mpv',
        'vlc': 'vlc',
        'org.xfce.mousepad': 'mousepad',
        'steam': 'generic',
        'org.example.unknown': 'generic',
        '': 'generic',
      };
      for (final e in cases.entries) {
        expect(remoteProfileFor(e.key).id, e.value, reason: e.key);
      }
      expect(remoteProfileFor('', 'firefox').id, 'firefox'); // initialClass if class is empty
      expect(remoteProfileFor('Bilinmeyen', 'kitty').id, 'kitty');
      expect(remoteProfileFor('com.example.kitty').id, 'kitty'); // last segment of the reverse domain name
    });

    test('her hazır düğme ajanın kabul edeceği olaylara dönüşür; kimlikler profilde tekil', () {
      for (final p in [...remoteProfiles, genericRemote]) {
        expect(p.buttons, isNotEmpty, reason: p.id);
        expect(p.buttons.map((b) => b.id).toSet(), hasLength(p.buttons.length), reason: p.id);
        for (final b in p.buttons) {
          final ev = remoteEvents(b.action, text: 'örnek metin');
          expect(ev, isNotNull, reason: '${p.id}/${b.id}');
          for (final e in ev!) {
            if (e['type'] == 'key') expect(parseCombo([...(e['mods'] as List), e['key']].join('+')), isNotNull, reason: '${p.id}/${b.id}');
          }
        }
      }
    });

    test('kapatma/silme düğmeleri onaylı', () {
      final confirmed = {
        for (final p in [...remoteProfiles, genericRemote])
          for (final b in p.buttons)
            if (b.confirm) '${p.id}/${b.id}',
      };
      expect(confirmed, {'firefox/closeTab', 'nautilus/delete', 'dolphin/delete', 'generic/closeWindow'});
    });

    test('kullanıcı kumandaları: aynı sınıf ya da aynı hazır profil', () {
      const a = DesktopRemote(id: 'a', windowClass: 'firefox', name: 'A', action: RemoteAction.combo('ctrl+t'));
      const b = DesktopRemote(id: 'b', windowClass: 'Steam', name: 'B', action: RemoteAction.combo('F5'));
      const c = DesktopRemote(id: 'c', windowClass: 'kitty', name: 'C', action: RemoteAction.combo('ctrl+t'));
      final all = [a, b, c];
      expect(remotesFor(all, 'firefox-esr').map((r) => r.id), ['a']);
      expect(remotesFor(all, 'steam').map((r) => r.id), ['b']);
      expect(remotesFor(all, 'other', 'kitty').map((r) => r.id), ['c']);
      expect(remotesFor(all, ''), isEmpty);
      // A remote with an invalid action does not become a button (hand-edited profile).
      expect(userButton(const DesktopRemote(id: 'x', windowClass: 'x', name: 'X', action: RemoteAction.combo('t'))), isNull);
      expect(userButton(a)!.label, 'A');
    });
  });

  group('eylem → WS olayları', () {
    RemoteButton btn(String profile, String id) => [...remoteProfiles, genericRemote].firstWhere((p) => p.id == profile).buttons.firstWhere((b) => b.id == id);

    test('Firefox', () {
      expect(remoteEvents(btn('firefox', 'address').action, text: 'tiphys.dev'), [
        key('L', ['ctrl']),
        {'type': 'text', 'text': 'tiphys.dev'},
        key('Enter'),
      ]);
      expect(remoteEvents(btn('firefox', 'reader').action), [key('R', ['ctrl', 'alt'])]);
      expect(remoteEvents(btn('firefox', 'zoomIn').action), [key('KPPlus', ['ctrl'])]);
      expect(remoteEvents(btn('firefox', 'scrollDown').action), [{'type': 'scroll', 'dx': 0, 'dy': 5}]);
      expect(remoteEvents(btn('firefox', 'reopenTab').action), [key('T', ['ctrl', 'shift'])]);
    });

    test('VS Code paleti dizisi, kitty, mpv düz harfi metin olarak', () {
      expect(remoteEvents(btn('vscode', 'terminal').action), [
        key('P', ['ctrl', 'shift']),
        {'type': 'text', 'text': 'View: Toggle Terminal'},
        key('Enter'),
      ]);
      expect(remoteEvents(btn('kitty', 'copy').action), [key('C', ['ctrl', 'shift'])]);
      expect(remoteEvents(btn('mpv', 'mute').action), [{'type': 'text', 'text': 'm'}]);
      expect(remoteEvents(btn('mpv', 'playPause').action), [key('Space')]);
      expect(remoteEvents(btn('vlc', 'seekForward').action), [key('Right', ['alt'])]);
    });

    test('prompt: kısayolsuz ve Enter\'sız; geçersiz metin/kısayol/teker', () {
      expect(remoteEvents(const RemoteAction.prompt(submit: false), text: 'merhaba'), [{'type': 'text', 'text': 'merhaba'}]);
      expect(remoteEvents(const RemoteAction.prompt(combo: 'ctrl+f'), text: 'a\u001bb'), isNull);
      expect(remoteEvents(const RemoteAction.combo('ctrl+`')), isNull);
      expect(remoteEvents(const RemoteAction.sequence([])), isNull);
      expect(remoteEvents(const RemoteAction.scroll(0)), isNull);
      expect(remoteEvents(const RemoteAction.scroll(21)), isNull);
    });

    test('açıklama metni', () {
      expect(remoteHint(btn('firefox', 'closeTab').action), 'Ctrl+W');
      expect(remoteHint(btn('firefox', 'address').action), 'Ctrl+L → …');
      expect(remoteHint(btn('vscode', 'terminal').action), 'Ctrl+Shift+P → … → Enter');
      expect(remoteHint(btn('mpv', 'mute').action), 'm');
      expect(remoteHint(btn('firefox', 'scrollDown').action), isNull);
    });
  });

  group('profil dosyası', () {
    final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
    Map<String, dynamic> file(List<Object> remotes) => {'format': 'tiphys-profile', 'schemaVersion': 1, 'desktopRemotes': remotes};

    test('örnek profilde kumanda var; model ↔ JSON aynı', () {
      final p = codec.decode(File('assets/profile/example.json').readAsStringSync()).toProfile();
      final r = p.desktopRemotes.single;
      expect(r.windowClass, 'firefox');
      expect(r.action.kind, RemoteKind.sequence);
      expect(remoteEvents(r.action), [key('L', ['ctrl']), {'type': 'text', 'text': 'github.com'}, key('Enter')]);
      const all = [
        DesktopRemote(id: 'a', windowClass: 'kitty', name: 'A', icon: 'terminal', action: RemoteAction.prompt(combo: 'ctrl+shift+t', submit: false), confirm: true),
        DesktopRemote(id: 'b', windowClass: 'mpv', name: 'B', action: RemoteAction.scroll(-3)),
        DesktopRemote(id: 'c', windowClass: 'mpv', name: 'C', action: RemoteAction.prompt()),
      ];
      final again = codec.decode(codec.encode(p.copyWith(desktopRemotes: all))).toProfile();
      expect(jsonEncode(again.desktopRemotes.map((r) => r.toJson()).toList()), jsonEncode(all.map((r) => r.toJson()).toList()));
    });

    test('sürüm: 1 dosyası (kumandalı da) taşınıp okunur, 2 olarak yazılır; daha yenisi NewerSchema', () {
      expect(schemaVersion, 2);
      final ok = {'id': 'a', 'windowClass': 'firefox', 'name': 'A', 'action': {'kind': 'combo', 'combo': 'ctrl+t'}};
      final v1 = codec.decode(jsonEncode(file([ok])));
      expect(v1.json['schemaVersion'], 2);
      expect(v1.toProfile().desktopRemotes.single.id, 'a');
      expect(codec.decode(jsonEncode({'format': 'tiphys-profile', 'schemaVersion': 1})).json['schemaVersion'], 2);
      expect(jsonDecode(codec.encode(v1.toProfile()))['schemaVersion'], 2);
      // The version limit is checked before the schema: a newer file with unknown sections counts as "newer", not
      // "invalid".
      expect(() => codec.decode(jsonEncode({...file([ok]), 'schemaVersion': 3})), throwsA(isA<NewerSchema>()));
    });

    test('şema: bilinmeyen eylem/simge, fazla alan, yinelenen kimlik reddedilir', () {
      final ok = {'id': 'a', 'windowClass': 'firefox', 'name': 'A', 'action': {'kind': 'combo', 'combo': 'ctrl+t'}};
      expect(codec.decode(jsonEncode(file([ok]))).toProfile().desktopRemotes.single.icon, 'zap');
      for (final bad in [
        {...ok, 'action': {'kind': 'shell', 'command': 'rm'}},
        {...ok, 'icon': 'rocket'},
        {...ok, 'fazla': 1},
        {...ok, 'action': {'kind': 'scroll', 'dy': 50}},
        {...ok, 'name': ''},
        {...ok, 'action': {'kind': 'combo', 'combo': 'control + shift + super + alt + printscreen'}}, // > 40
      ]) {
        expect(() => codec.decode(jsonEncode(file([bad]))), throwsA(isA<InvalidProfile>()), reason: '$bad');
      }
      expect(() => codec.decode(jsonEncode(file([ok, ok]))), throwsA(isA<InvalidProfile>()));
    });
  });
}
