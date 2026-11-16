// Storing the profile on the phone (excluding secrets) and import/export operations.
import 'dart:convert';
import 'dart:io';

import '../secrets/secret_box.dart';
import '../secrets/secret_store.dart';
import '../vault/vault.dart';
import 'codec.dart';
import 'merge.dart';
import 'model.dart';

class ProfileRepository {
  ProfileRepository({required this.file, required this.codec, required this.secrets});

  /// profile.json in the app documents folder
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

  /// Export without secrets.
  String exportPlain(Profile p, {String? deviceName}) => codec.encode(p, exportedFrom: deviceName);

  /// Encrypted backup: the secrets referenced by the profile and the password vault are encrypted with a password and
  /// added. (Neither is included in an export without secrets.)
  Future<String> exportEncrypted(Profile p, String passphrase, {String? deviceName, Argon2Params params = Argon2Params.standard}) async {
    final values = await secrets.readAll({...p.secretIds, vaultSecretId});
    final sealed = await SecretSeal.seal(values, passphrase, params: params);
    return codec.encode(p, encryptedSecrets: sealed, exportedFrom: deviceName);
  }

  /// Import plan (preview). If the file is encrypted and a password is given, the secrets are decrypted too.
  Future<PreparedImport> prepare(Profile current, String text, ImportMode mode, {String? passphrase}) async {
    final file = codec.decode(text);
    Map<String, String> incoming = const {};
    final sealed = file.encryptedSecrets;
    if (sealed != null && passphrase != null) incoming = await SecretSeal.open(sealed, passphrase);
    final plan = ImportPlan(current, file, mode);
    final available = {...await secrets.ids(), ...incoming.keys};
    return PreparedImport(plan, incoming, plan.missingSecrets(available), encrypted: sealed != null);
  }

  /// Applies the plan: writes secrets to the store and saves the profile. The password vault isn't overwritten but
  /// merged (for the same entry the one updated more recently wins; entries added after the backup aren't lost).
  Future<Profile> apply(PreparedImport prepared) async {
    for (final e in prepared.incomingSecrets.entries) {
      var value = e.value;
      if (e.key == vaultSecretId) {
        final current = await secrets.read(vaultSecretId);
        if (current != null) value = encodeVault(mergeVaults(decodeVault(current), decodeVault(value)));
      }
      await secrets.write(e.key, value);
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
