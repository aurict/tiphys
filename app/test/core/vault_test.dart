// Password vault: store round-trip, search, password generator, Markdown import (SYNTHETIC sample; no real file
// is used), merge, sensitive clipboard timer, clipboard sync skipping vault copies, encrypted profile backup.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/merge.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/profile/repository.dart';
import 'package:tiphys/core/push/clipboard.dart';
import 'package:tiphys/core/secrets/secret_box.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
import 'package:tiphys/core/vault/markdown_import.dart';
import 'package:tiphys/core/vault/sensitive_clipboard.dart';
import 'package:tiphys/core/vault/vault.dart';
import 'package:tiphys/features/system/clipboard_sync.dart';
import 'package:tiphys/features/vault/vault_state.dart';
import 'package:tiphys/state/providers.dart';

import '../helpers/harness.dart' show codec, exampleProfile;

VaultEntry entry(String id, String title, {String user = '', String pass = 'p', List<String> tags = const [], String url = '', int day = 1}) =>
    VaultEntry(id: id, title: title, username: user, password: pass, url: url, tags: tags, updatedAt: DateTime.utc(2026, 11, day));

/// SYNTHETIC sample mimicking the structure of ~/SIFRELER.md (values are made up).
const fixture = '''
# Şifreler ve Adresler

_Güncellendi: 2026-01-01 · Bu dosyayı kimseyle paylaşma._

Tüm adresler sadece Tailscale ağından açılır (`*.example.ts.net`).

## PC (masaustu) — yerel ağ, Tailscale
| Sunucu | Komut |
|---|---|
| masaustu | `ssh kisi@masaustu` |
| yedek-disk | — |

## sunucu1 (100.64.0.1)
| Servis | Adres | Kullanıcı | Şifre |
|---|---|---|---|
| Grafana | http://100.64.0.1:3000 | `admin` | `Graf-Sifre_1` |
| Uptime Kuma | http://100.64.0.1:3001/dashboard | kuma | `kuma|boru` (kurulumda verildi) |
| Postgres (n8n) | `db.local:5432` | `n8n` | — |
| Eski panel | — | — | okunamaz (tek yönlü özet) |
| Ntfy ×2 (web + uygulama) | http://100.64.0.1:8080 | Web: `telefon` · Uygulama: `ntfy-app` | `NtfyPar0la` |
| Tek kelime | https://tek.example.com | tek@example.com (kurtarma e-postası) | DuzSifre99 |

Teknik (kurtarma için):
- JWT_SECRET: `cok-gizli-jwt`

## Notlar
- **Eski kasa** kaldırıldı (`eski-token`).
''';

class FakeNative implements SensitiveClipboardNative {
  String? clip;
  String? label;
  final calls = <String>[];
  @override
  Future<void> setSensitive(String text, String label) async {
    calls.add('set:$label');
    clip = text;
    this.label = label;
  }

  @override
  Future<bool> clearIfLabel(String label) async {
    calls.add('clear:$label');
    if (this.label != label) return false;
    clip = null;
    this.label = null;
    return true;
  }
}

/// Manually triggered timers.
class FakeTimers {
  final pending = <(Duration, void Function(), _FakeTimer)>[];
  Timer call(Duration d, void Function() f) {
    final t = _FakeTimer();
    pending.add((d, f, t));
    return t;
  }

  void fireAll() {
    final list = [...pending];
    pending.clear();
    for (final (_, f, t) in list) {
      if (t.isActive) {
        t.isActive = false;
        f();
      }
    }
  }
}

class _FakeTimer implements Timer {
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
  @override
  int get tick => 0;
}

void main() {
  group('kasa deposu', () {
    test('tek gizli kayıt olarak gidiş-dönüş; toString şifre sızdırmaz', () async {
      final store = MemorySecretStore();
      final vs = VaultStore(store);
      expect(await vs.load(), isEmpty);
      final e = VaultEntry(id: 'x1', title: 'Grafana', username: 'admin', password: 'çok-gizli ş', url: 'https://g', notes: 'n', tags: const ['atlas'], updatedAt: DateTime.utc(2026, 11, 14, 10));
      await vs.save([e]);
      expect(await store.ids(), {vaultSecretId});
      final back = (await vs.load()).single;
      expect(back.toJson(), e.toJson());
      expect('$back', isNot(contains('gizli')));
      expect(await store.read(vaultSecretId), contains('"v":1'));
    });

    test('kilitliyken silme/kaydetme hata verir, kasa boşaltılmaz (açık kalan onay penceresi senaryosu)', () async {
      final store = MemorySecretStore();
      final e = VaultEntry(id: 'x1', title: 'Grafana', username: 'admin', password: 'p', url: '', notes: '', tags: const [], updatedAt: DateTime.utc(2026));
      await VaultStore(store).save([e]);
      final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(store)]);
      addTearDown(c.dispose);
      final vault = c.read(vaultProvider.notifier);
      await vault.open();
      expect(c.read(vaultProvider).entries, hasLength(1));
      // The vault locked (background / idle) while the delete confirmation was open, then it was confirmed
      await vault.lock(clearClipboard: false);
      await expectLater(vault.delete('x1'), throwsA(isA<VaultLockedError>()));
      await expectLater(vault.upsert(e), throwsA(isA<VaultLockedError>()));
      await expectLater(vault.replaceAll(const []), throwsA(isA<VaultLockedError>()));
      expect((await VaultStore(store).load()).single.id, 'x1');
      expect(c.read(vaultProvider).unlocked, isFalse);
    });

    test('bozuk içerik VaultFormatError', () {
      expect(() => decodeVault('{"v":2,"entries":[]}'), throwsA(isA<VaultFormatError>()));
      expect(() => decodeVault('düz metin'), throwsA(isA<VaultFormatError>()));
    });

    test('arama: başlık/kullanıcı/adres/etiket, şifrede aranmaz, sözcüklerin hepsi', () {
      final list = [entry('1', 'Grafana', user: 'admin', tags: ['atlas']), entry('2', 'n8n', url: 'https://n8n.example', pass: 'grafana'), entry('3', 'Ntfy', user: 'telefon')];
      expect(searchVault(list, '').map((e) => e.id), ['1', '2', '3']);
      expect(searchVault(list, 'GRAF').map((e) => e.id), ['1']);
      expect(searchVault(list, 'example').map((e) => e.id), ['2']);
      expect(searchVault(list, 'atlas admin').map((e) => e.id), ['1']);
      expect(searchVault(list, 'atlas telefon'), isEmpty);
    });

    test('birleştirme: kimliğe göre, yeni olan kazanır', () {
      final a = [entry('1', 'A', day: 5), entry('2', 'B', day: 1)];
      final b = [entry('1', 'A-eski', day: 2), entry('2', 'B-yeni', day: 9), entry('3', 'C')];
      expect({for (final e in mergeVaults(a, b)) e.id: e.title}, {'1': 'A', '2': 'B-yeni', '3': 'C'});
    });
  });

  group('şifre üretici', () {
    test('uzunluk, her sınıftan en az bir, simgesiz seçenek, karışık harf yok', () {
      for (var seed = 0; seed < 50; seed++) {
        final p = generatePassword(length: 12, random: Random(seed));
        expect(p.length, 12);
        expect(p, matches(RegExp(r'[a-z]')));
        expect(p, matches(RegExp(r'[A-Z]')));
        expect(p, matches(RegExp(r'[0-9]')));
        expect(p, matches(RegExp(r'[^A-Za-z0-9]')));
        expect(p, isNot(matches(RegExp(r'[lIO01]'))));
        final n = generatePassword(length: 30, symbols: false, random: Random(seed));
        expect(n, matches(RegExp(r'^[A-Za-z0-9]{30}$')));
      }
      expect(generatePassword(length: 2).length, 4); // cannot be shorter than the number of classes
      expect(generatePassword(), isNot(generatePassword()));
    });
  });

  group('Markdown içe aktarma', () {
    test('hücre bölme: ters tırnak ve \\| içindeki çizgi bölmez', () {
      expect(splitTableRow(r'| a | `b|c` | d\|e |'), ['a', '`b|c`', 'd|e']);
    });

    test('sentetik örnek: başlıklar etiket, 2 ve 4 sütun, ters tırnak, —, açıklamalar nota, liste satırları atlanır', () {
      final c = parsePasswordMarkdown(fixture);
      expect(c.map((e) => e.title), ['masaustu', 'Grafana', 'Uptime Kuma', 'Postgres (n8n)', 'Eski panel', 'Ntfy ×2 (web + uygulama)', 'Tek kelime']);
      final pc = c[0];
      expect((pc.tags.join(), pc.password, pc.notes), ('PC', '', 'Komut: ssh kisi@masaustu'));
      final g = c[1];
      expect((g.tags.join(), g.url, g.username, g.password, g.notes), ('sunucu1', 'http://100.64.0.1:3000', 'admin', 'Graf-Sifre_1', ''));
      final k = c[2];
      expect((k.url, k.username, k.password, k.notes), ('http://100.64.0.1:3001/dashboard', 'kuma', 'kuma|boru', 'Şifre: (kurulumda verildi)'));
      final pg = c[3];
      expect((pg.url, pg.username, pg.password), ('db.local:5432', 'n8n', ''));
      final old = c[4];
      expect((old.password, old.notes), ('', 'Şifre: okunamaz (tek yönlü özet)'));
      final ntfy = c[5];
      expect((ntfy.username, ntfy.password, ntfy.notes), ('telefon', 'NtfyPar0la', 'Kullanıcı: Web: telefon · Uygulama: ntfy-app'));
      final tek = c[6];
      expect((tek.username, tek.password), ('tek@example.com (kurtarma e-postası)', 'DuzSifre99'));
      expect(c.any((e) => e.password.contains('jwt') || e.password.contains('eski')), isFalse);
      expect('$g', isNot(contains('Graf-Sifre')));
    });

    test('başlıksız tablo: sütun sayısına göre; tanınmayan başlık ilk sütunu başlık yapar', () {
      final c = parsePasswordMarkdown('''
## Grup
| a | b | c |
|---|---|---|
| Wiki | `ali` | `w1` |

| Kullanıcı | Parola |
| :-- | --: |
| `veli` | `p2` |
''');
      expect([for (final e in c) (e.title, e.username, e.password, e.tags.join())], [
        ('Wiki', 'ali', 'w1', 'Grup'),
        ('veli', 'veli', 'p2', 'Grup'),
      ]);
    });

    test('kasaya ekleme: başlık + kullanıcı eşleşirse güncellenir, yinelenmez', () {
      var n = 0;
      final current = [entry('old', 'grafana', user: 'ADMIN', pass: 'eski', tags: ['mevcut'])];
      final c = parsePasswordMarkdown(fixture);
      final r = mergeImported(current, c, DateTime.utc(2026, 11, 14), newId: () => 'id${n++}');
      expect(r.added, c.length - 1);
      expect(r.updated, 1);
      final g = r.entries.firstWhere((e) => e.id == 'old');
      expect((g.password, g.url, g.updatedAt), ('Graf-Sifre_1', 'http://100.64.0.1:3000', DateTime.utc(2026, 11, 14)));
      expect(g.tags, ['mevcut', 'sunucu1']);
      // Same import a second time: nothing is added/changed.
      final again = mergeImported(r.entries, c, DateTime.utc(2026, 11, 15), newId: () => 'yeni${n++}');
      expect((again.added, again.updated, again.entries.length), (0, 0, r.entries.length));
    });
  });

  group('hassas pano', () {
    test('30 sn sonra yalnız kendi kopyası temizlenir; yeni kopya eskisinin sayacını geçersiz kılar; kilitte hemen', () async {
      final native = FakeNative();
      final timers = FakeTimers();
      final cb = SensitiveClipboard(native, timer: timers.call, random: Random(1));
      await cb.copy('şifre-1');
      expect(native.clip, 'şifre-1');
      expect(timers.pending.single.$1, const Duration(seconds: 30));
      expect(cb.isGuarded('şifre-1'), isTrue);
      expect(cb.pending, isTrue);
      timers.fireAll();
      await Future<void>.delayed(Duration.zero);
      expect(native.clip, isNull);
      expect(cb.isGuarded('şifre-1'), isFalse);
      expect(cb.pending, isFalse);

      // Two copies: the first timer is cancelled, only the second one's label is cleared.
      await cb.copy('a');
      final firstLabel = native.label;
      await cb.copy('b');
      expect(native.label, isNot(firstLabel));
      timers.fireAll();
      await Future<void>.delayed(Duration.zero);
      expect(native.calls.where((c) => c == 'clear:$firstLabel'), isEmpty);
      expect(native.clip, isNull);

      // If the user copied something else in the meantime (different label), it is left alone.
      await cb.copy('c');
      native.label = 'başka uygulama';
      native.clip = 'kullanıcının metni';
      await cb.clearNow();
      expect(native.clip, 'kullanıcının metni');
      expect(cb.pending, isFalse);
      await cb.clearNow(); // does nothing when nothing is pending
    });

    test('pano eşitleme kasadan kopyalanan şifreyi PC\'ye göndermez', () async {
      final native = FakeNative();
      final cb = SensitiveClipboard(native, timer: FakeTimers().call);
      await cb.copy('gizli');
      final p = exampleProfile();
      final profile = p.copyWith(notifications: p.notifications.copyWith(clipboardToPc: true));
      final sent = <String>[];
      Future<bool> run(String text) => syncClipboardToPc(
            profile: profile,
            read: () async => text,
            seen: ClipboardSeen(() async => null),
            send: (h, t) async => sent.add(t),
            skip: cb.isGuarded,
          );
      expect(await run('gizli'), isFalse);
      expect(await run('normal metin'), isTrue);
      expect(sent, ['normal metin']);
    });

    test('başka uygulamanın "hassas" işaretlediği kopya (parola yöneticisi) okunmaz, PC\'ye gitmez', () async {
      final p = exampleProfile();
      final profile = p.copyWith(notifications: p.notifications.copyWith(clipboardToPc: true));
      var reads = 0;
      final sent = <String>[];
      Future<bool> run({required bool sensitive}) => syncClipboardToPc(
            profile: profile,
            read: () async {
              reads++;
              return 'bitwarden-şifresi';
            },
            seen: ClipboardSeen(() async => null),
            send: (h, t) async => sent.add(t),
            isSensitive: () async => sensitive,
          );
      expect(await run(sensitive: true), isFalse);
      expect(reads, 0); // the sensitive copy was never read
      expect(sent, isEmpty);
      expect(await run(sensitive: false), isTrue);
      expect(sent, ['bitwarden-şifresi']);
    });
  });

  group('profil yedeği', () {
    const fast = Argon2Params(memoryKiB: 8192, iterations: 1); // schema's lower bound
    ProfileRepository repo(MemorySecretStore s) =>
        ProfileRepository(file: File('${Directory.systemTemp.createTempSync('tiphys-vault').path}/profile.json'), codec: codec, secrets: s);

    test('şifreli yedekte kasa var (mühürlü), gizlisizde yok; içe aktarınca geri gelir ve birleşir', () async {
      final p = exampleProfile();
      final src = MemorySecretStore({'ssh-phone': 'k', vaultSecretId: encodeVault([entry('1', 'Grafana', pass: 'G-1', day: 10), entry('2', 'Ntfy', pass: 'N-1', day: 1)])});
      final r = repo(src);

      final plain = r.exportPlain(p);
      expect(plain, isNot(contains('G-1')));
      expect(plain, isNot(contains(vaultSecretId)));
      expect(jsonDecode(plain)['encryptedSecrets'], isNull);

      final enc = await r.exportEncrypted(p, 'parola', params: fast);
      expect(enc, isNot(contains('G-1')));
      expect(enc, isNot(contains(vaultSecretId)));
      final opened = await SecretSeal.open(Map<String, dynamic>.from(jsonDecode(enc)['encryptedSecrets'] as Map), 'parola');
      expect(opened.keys, contains(vaultSecretId));

      // No vault on the target device: arrives as is.
      final empty = MemorySecretStore();
      final r2 = repo(empty);
      await r2.apply(await r2.prepare(Profile.empty, enc, ImportMode.merge, passphrase: 'parola'));
      expect((await VaultStore(empty).load()).map((e) => (e.id, e.password)), [('1', 'G-1'), ('2', 'N-1')]);

      // Newer entries on the target and entries not in the backup are kept.
      final dst = MemorySecretStore({vaultSecretId: encodeVault([entry('2', 'Ntfy', pass: 'N-yeni', day: 20), entry('3', 'Yerel', pass: 'L')])});
      final r3 = repo(dst);
      await r3.apply(await r3.prepare(Profile.empty, enc, ImportMode.merge, passphrase: 'parola'));
      expect({for (final e in await VaultStore(dst).load()) e.id: e.password}, {'1': 'G-1', '2': 'N-yeni', '3': 'L'});
    });
  });
}
