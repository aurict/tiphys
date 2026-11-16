// Secret store. Android Keystore (flutter_secure_storage) in production, in-memory in tests.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SecretStore {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
  Future<Set<String>> ids();
  Future<void> clear();

  Future<Map<String, String>> readAll(Iterable<String> ids) async {
    final out = <String, String>{};
    for (final id in ids) {
      final v = await read(id);
      if (v != null) out[id] = v;
    }
    return out;
  }
}

class MemorySecretStore extends SecretStore {
  MemorySecretStore([Map<String, String>? initial]) : _m = {...?initial};
  final Map<String, String> _m;
  @override
  Future<String?> read(String id) async => _m[id];
  @override
  Future<void> write(String id, String value) async => _m[id] = value;
  @override
  Future<void> delete(String id) async => _m.remove(id);
  @override
  Future<Set<String>> ids() async => _m.keys.toSet();
  @override
  Future<void> clear() async => _m.clear();
}

class KeystoreSecretStore extends SecretStore {
  KeystoreSecretStore([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;

  // The app's own entries (PIN hash etc.) start with "app:", profile secrets with "secret:".
  static const _prefix = 'secret:';

  @override
  Future<String?> read(String id) => _s.read(key: '$_prefix$id');
  @override
  Future<void> write(String id, String value) => _s.write(key: '$_prefix$id', value: value);
  @override
  Future<void> delete(String id) => _s.delete(key: '$_prefix$id');
  @override
  Future<Set<String>> ids() async =>
      (await _s.readAll()).keys.where((k) => k.startsWith(_prefix)).map((k) => k.substring(_prefix.length)).toSet();
  @override
  Future<void> clear() async {
    for (final id in await ids()) {
      await delete(id);
    }
  }
}
