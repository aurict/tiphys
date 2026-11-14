// Şifreli başlangıç profili üretir (telefonda "İçe aktar" ile tek seferde kurulum için).
// Kullanım: dart run tool/make_profile.dart <profil.json> <gizliler.json> <çıktı.tiphys.json>
// Parola TIPHYS_PASSPHRASE ortam değişkeninden okunur. Gizli bilgiler dosyaya sadece şifreli girer.
import 'dart:convert';
import 'dart:io';

import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/core/secrets/secret_box.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('kullanım: dart run tool/make_profile.dart <profil.json> <gizliler.json> <çıktı>');
    exit(2);
  }
  final pass = Platform.environment['TIPHYS_PASSPHRASE'];
  if (pass == null || pass.length < 10) {
    stderr.writeln('TIPHYS_PASSPHRASE en az 10 karakter olmalı');
    exit(2);
  }
  final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
  final profile = codec.decode(File(args[0]).readAsStringSync()).toProfile();
  final secrets = Map<String, String>.from(jsonDecode(File(args[1]).readAsStringSync()) as Map);
  final missing = profile.secretIds.difference(secrets.keys.toSet());
  if (missing.isNotEmpty) stderr.writeln('uyarı: dosyada olmayan gizli bilgiler (telefonda girilecek): ${missing.join(', ')}');
  final needed = {for (final id in profile.secretIds) if (secrets[id] != null) id: secrets[id]!};
  final sealed = await SecretSeal.seal(needed, pass);
  final text = codec.encode(profile, encryptedSecrets: sealed, exportedFrom: 'kurulum aracı');
  // Doğrulama: dosya okunabiliyor ve parolayla açılıyor mu?
  final back = codec.decode(text);
  final opened = await SecretSeal.open(back.encryptedSecrets!, pass);
  if (opened.length != needed.length) throw StateError('doğrulama başarısız');
  File(args[2]).writeAsStringSync(text);
  stdout.writeln('yazıldı: ${args[2]} (${profile.hosts.length} host, ${opened.length} gizli bilgi şifreli)');
}
