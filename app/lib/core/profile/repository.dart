// Profilin telefonda saklanması (gizli bilgiler hariç) ve içe/dışa aktarma işlemleri.
import 'dart:convert';
import 'dart:io';

import '../secrets/secret_box.dart';
import '../secrets/secret_store.dart';
import 'codec.dart';
import 'merge.dart';
import 'model.dart';

class ProfileRepository {
  ProfileRepository({required this.file, required this.codec, required this.secrets});

  /// Uygulama belgeleri klasöründeki profile.json
  final File file;
  final ProfileCodec codec;
  final SecretStore secrets;

  Future<Profile> load() async {
    if (!await file.exists()) return Profile.empty;
    return codec.decode(await file.readAsString()).toProfile();
  }

  Future<void> save(Profile p) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(codec.encode(p), flush: true);
    await tmp.rename(file.path);
  }

  /// Gizlisiz dışa aktarma.
  String exportPlain(Profile p, {String? deviceName}) => codec.encode(p, exportedFrom: deviceName);

  /// Şifreli yedek: profilin başvurduğu gizli bilgiler parolayla şifrelenip eklenir.
  Future<String> exportEncrypted(Profile p, String passphrase, {String? deviceName, Argon2Params params = Argon2Params.standard}) async {
    final values = await secrets.readAll(p.secretIds);
    final sealed = await SecretSeal.seal(values, passphrase, params: params);
    return codec.encode(p, encryptedSecrets: sealed, exportedFrom: deviceName);
  }

  /// İçe aktarma planı (önizleme). Dosya şifreliyse ve parola verilmişse gizli bilgiler de açılır.
  Future<PreparedImport> prepare(Profile current, String text, ImportMode mode, {String? passphrase}) async {
    final file = codec.decode(text);
    Map<String, String> incoming = const {};
    final sealed = file.encryptedSecrets;
    if (sealed != null && passphrase != null) incoming = await SecretSeal.open(sealed, passphrase);
    final plan = ImportPlan(current, file, mode);
    final available = {...await secrets.ids(), ...incoming.keys};
    return PreparedImport(plan, incoming, plan.missingSecrets(available), encrypted: sealed != null);
  }

  /// Planı uygular: gizli bilgileri kasaya yazar, profili kaydeder.
  Future<Profile> apply(PreparedImport prepared) async {
    for (final e in prepared.incomingSecrets.entries) {
      await secrets.write(e.key, e.value);
    }
    final result = prepared.plan.result;
    await save(result);
    return result;
  }

  Future<void> reset() async {
    await secrets.clear();
    if (await file.exists()) await file.delete();
  }
}

class PreparedImport {
  PreparedImport(this.plan, this.incomingSecrets, this.missingSecrets, {required this.encrypted});
  final ImportPlan plan;
  final Map<String, String> incomingSecrets;
  final Set<String> missingSecrets;
  final bool encrypted;
}

String prettyJson(Object o) => const JsonEncoder.withIndent('  ').convert(o);
