import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/core/profile/merge.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/profile/repository.dart';
import 'package:tiphys/core/secrets/secret_box.dart';
import 'package:tiphys/core/secrets/secret_store.dart';

const fastKdf = Argon2Params(memoryKiB: 8192, iterations: 1, parallelism: 1);

void main() {
  late ProfileCodec codec;
  late String exampleText;

  setUpAll(() {
    codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
    exampleText = File('assets/profile/example.json').readAsStringSync();
  });

  ProfileRepository repo(SecretStore s) =>
      ProfileRepository(file: File('${Directory.systemTemp.createTempSync('tiphys').path}/profile.json'), codec: codec, secrets: s);

  group('çözümleme', () {
    test('örnek profil okunur ve modele dönüşür', () {
      final p = codec.decode(exampleText).toProfile();
      expect(p.hosts.map((h) => h.id), ['argo', 'atlas', 'orion']);
      expect(p.host('argo')!.ssh!.auth, isA<SshKeyAuth>());
      expect(p.integrations.grafana.single.tokenRef, 'secret:grafana-atlas');
      expect(p.integrations.dozzle.single.id, 'dozzle-orion');
      expect(p.app.language, LanguagePref.system);
      expect(p.secretIds, unorderedEquals(['ssh-phone', 'agent-argo', 'agent-atlas', 'grafana-atlas']));
    });

    test('eski dosyadaki kullanılmayan ntfy/Scriberr anahtarları okunur ama eksik sayılmaz', () {
      final j = jsonDecode(exampleText) as Map<String, dynamic>;
      final i = j['integrations'] as Map<String, dynamic>;
      (i['ntfy'] as Map<String, dynamic>)['tokenRef'] = 'secret:ntfy';
      i['scriberr'] = {'url': 'https://atlas.example:8095', 'apiKeyRef': 'secret:scriberr', 'language': 'en', 'model': 'large-v3'};
      final p = codec.decode(jsonEncode(j)).toProfile();
      expect(p.secretIds, isNot(contains('ntfy')));
      expect(p.secretIds, isNot(contains('scriberr')));
      expect(p.integrations.scriberr!.language, 'en');
      expect(p.integrations.scriberr!.model, 'large-v3');
      // they no longer appear in the rewritten file
      expect(codec.encode(p), isNot(contains('apiKeyRef')));
    });

    test('model → dosya → model aynı kalır ve şemaya uyar', () {
      final p = codec.decode(exampleText).toProfile();
      final again = codec.decode(codec.encode(p)).toProfile();
      expect(jsonEncode(again.toJson()), jsonEncode(p.toJson()));
    });

    test('boş profil de geçerli bir dosya üretir', () {
      expect(() => codec.decode(codec.encode(Profile.empty)), returnsNormally);
    });

    test('JSON değilse NotJson', () => expect(() => codec.decode('{oops'), throwsA(isA<NotJson>())));

    test('biçim alanı yoksa NotAProfile', () {
      expect(() => codec.decode('{"hosts": []}'), throwsA(isA<NotAProfile>()));
    });

    test('daha yeni şema reddedilir', () {
      expect(
        () => codec.decode('{"format":"tiphys-profile","schemaVersion":99}'),
        throwsA(isA<NewerSchema>().having((e) => e.version, 'version', 99)),
      );
    });

    test('düz metin token reddedilir', () {
      final bad = jsonEncode({
        'format': 'tiphys-profile',
        'schemaVersion': 1,
        'integrations': {
          'grafana': [
            {'id': 'g', 'name': 'G', 'url': 'https://g', 'auth': {'type': 'token', 'tokenRef': 'glsa_123'}}
          ]
        },
      });
      expect(() => codec.decode(bad), throwsA(isA<InvalidProfile>()));
    });

    test('yinelenen kimlik ve olmayan hosta başvuru yakalanır', () {
      final j = jsonDecode(exampleText) as Map<String, dynamic>;
      (j['hosts'] as List).add((j['hosts'] as List).first);
      (j['quickActions'] as List).first['hostId'] = 'yok';
      try {
        codec.decode(jsonEncode(j));
        fail('hata bekleniyordu');
      } on InvalidProfile catch (e) {
        expect(e.issues.join('\n'), contains('"argo" kimliği birden fazla'));
        expect(e.issues.join('\n'), contains('"yok" adlı host yok'));
      }
    });
  });

  group('içe aktarma', () {
    late Profile current;
    setUp(() => current = codec.decode(exampleText).toProfile());

    test('sadece Grafana içeren kısmi dosya sadece Grafana\'yı değiştirir', () {
      final file = codec.decode(jsonEncode({
        'format': 'tiphys-profile',
        'schemaVersion': 1,
        'integrations': {
          'grafana': [
            {'id': 'grafana-atlas', 'name': 'Grafana', 'url': 'https://yeni-sunucu:3030', 'auth': {'type': 'token', 'tokenRef': 'secret:grafana-atlas'}},
          ],
        },
      }));
      final plan = ImportPlan(current, file, ImportMode.merge);
      expect(plan.changes, [const Change('integrations.grafana', ChangeKind.changed, 'grafana-atlas')]);
      expect(plan.result.integrations.grafana.single.url, 'https://yeni-sunucu:3030');
      expect(plan.result.hosts.length, 3);
      expect(plan.result.integrations.dozzle.single.id, 'dozzle-orion');
    });

    test('birleştirme yeni hostu ekler, hiçbir şeyi silmez', () {
      final file = codec.decode(jsonEncode({
        'format': 'tiphys-profile',
        'schemaVersion': 1,
        'hosts': [
          {'id': 'yeni', 'name': 'Yeni', 'address': 'yeni.ts.net'}
        ],
      }));
      final plan = ImportPlan(current, file, ImportMode.merge);
      expect(plan.changes, [const Change('hosts', ChangeKind.added, 'yeni')]);
      expect(plan.result.hosts.map((h) => h.id), ['argo', 'atlas', 'orion', 'yeni']);
    });

    test('tamamen değiştirme silinecekleri listeler', () {
      final file = codec.decode(jsonEncode({
        'format': 'tiphys-profile',
        'schemaVersion': 1,
        'hosts': [
          {'id': 'atlas', 'name': 'atlas', 'address': 'atlas.example.ts.net'}
        ],
      }));
      final plan = ImportPlan(current, file, ImportMode.replace);
      expect(plan.changes, containsAll([
        const Change('hosts', ChangeKind.removed, 'argo'),
        const Change('hosts', ChangeKind.changed, 'atlas'),
        const Change('integrations.grafana', ChangeKind.removed, 'grafana-atlas'),
      ]));
      expect(plan.result.hosts.single.id, 'atlas');
      expect(plan.result.integrations.grafana, isEmpty);
    });

    test('aynı dosya değişiklik üretmez', () {
      final plan = ImportPlan(current, codec.decode(codec.encode(current)), ImportMode.merge);
      expect(plan.changes, isEmpty);
    });
  });

  group('şifreli yedek', () {
    test('doğru parolayla gizli bilgiler geri gelir', () async {
      final source = MemorySecretStore({'ssh-phone': '-----BEGIN OPENSSH PRIVATE KEY-----\nabc', 'grafana-atlas': 'glsa_x', 'alakasiz': 'y'});
      final p = codec.decode(exampleText).toProfile();
      final text = await repo(source).exportEncrypted(p, 'uzun-bir-parola', params: fastKdf);
      expect(text, isNot(contains('glsa_x')));
      expect(text, isNot(contains('BEGIN OPENSSH')));

      final target = MemorySecretStore();
      final r = repo(target);
      final prepared = await r.prepare(Profile.empty, text, ImportMode.replace, passphrase: 'uzun-bir-parola');
      expect(prepared.encrypted, isTrue);
      expect(prepared.incomingSecrets.keys, unorderedEquals(['ssh-phone', 'grafana-atlas']));
      expect(prepared.missingSecrets, unorderedEquals(['agent-argo', 'agent-atlas']));
      await r.apply(prepared);
      expect(await target.read('grafana-atlas'), 'glsa_x');
      expect(await target.read('alakasiz'), isNull);
      expect((await r.load()).hosts.length, 3);
    });

    test('yanlış parola WrongPassphrase', () async {
      final p = codec.decode(exampleText).toProfile();
      final text = await repo(MemorySecretStore({'ntfy': 'tk'})).exportEncrypted(p, 'dogru-parola-1', params: fastKdf);
      expect(
        () => repo(MemorySecretStore()).prepare(Profile.empty, text, ImportMode.merge, passphrase: 'yanlis-parola'),
        throwsA(isA<WrongPassphrase>()),
      );
    });

    test('gizlisiz dışa aktarmada gizli bölüm yoktur', () {
      final text = repo(MemorySecretStore()).exportPlain(codec.decode(exampleText).toProfile());
      expect(jsonDecode(text)['encryptedSecrets'], isNull);
    });
  });
}
