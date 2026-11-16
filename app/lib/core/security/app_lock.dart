// App lock: PIN (Argon2id hash in Keystore) + fingerprint. Increasing delay after wrong attempts.
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

abstract class KeyValueVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureVault implements KeyValueVault {
  const SecureVault([this._s = const FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false))]);
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemoryVault implements KeyValueVault {
  final Map<String, String> m = {};
  @override
  Future<String?> read(String key) async => m[key];
  @override
  Future<void> write(String key, String value) async => m[key] = value;
  @override
  Future<void> delete(String key) async => m.remove(key);
}

abstract class Biometrics {
  Future<bool> available();
  Future<bool> authenticate(String reason);
}

class DeviceBiometrics implements Biometrics {
  final _auth = LocalAuthentication();
  @override
  Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }
}

class PinCheck {
  const PinCheck({required this.ok, this.waitSeconds = 0});
  final bool ok;
  final int waitSeconds;
}

class AppLock {
  AppLock(this._vault, {this.kdfMemoryKiB = 12288});
  final KeyValueVault _vault;
  final int kdfMemoryKiB;

  static const _pinKey = 'app:pin';
  static const _failKey = 'app:pinFailures';
  static const _untilKey = 'app:pinLockedUntil';

  Future<bool> hasPin() async => await _vault.read(_pinKey) != null;

  Future<List<int>> _hash(String pin, List<int> salt) async {
    final kdf = Argon2id(memory: kdfMemoryKiB, iterations: 2, parallelism: 1, hashLength: 32);
    final key = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
    return key.extractBytes();
  }

  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin)) throw ArgumentError('PIN 6–12 hane olmalı');
    final r = Random.secure();
    final salt = List<int>.generate(16, (_) => r.nextInt(256));
    final hash = await _hash(pin, salt);
    await _vault.write(_pinKey, jsonEncode({'salt': base64.encode(salt), 'hash': base64.encode(hash), 'm': kdfMemoryKiB}));
    await _vault.delete(_failKey);
    await _vault.delete(_untilKey);
  }

  Future<void> clearPin() async {
    await _vault.delete(_pinKey);
    await _vault.delete(_failKey);
    await _vault.delete(_untilKey);
  }

  /// Checks the PIN. After 5 wrong attempts, the delay doubles on each wrong attempt (starting at 30 s).
  Future<PinCheck> verify(String pin, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final until = int.tryParse(await _vault.read(_untilKey) ?? '');
    if (until != null && t.millisecondsSinceEpoch < until) {
      return PinCheck(ok: false, waitSeconds: ((until - t.millisecondsSinceEpoch) / 1000).ceil());
    }
    final stored = await _vault.read(_pinKey);
    if (stored == null) return const PinCheck(ok: false);
    final j = jsonDecode(stored) as Map<String, dynamic>;
    final hash = await AppLock(_vault, kdfMemoryKiB: j['m'] as int)._hash(pin, base64.decode(j['salt'] as String));
    final expected = base64.decode(j['hash'] as String);
    var diff = hash.length ^ expected.length;
    for (var i = 0; i < min(hash.length, expected.length); i++) {
      diff |= hash[i] ^ expected[i];
    }
    if (diff == 0) {
      await _vault.delete(_failKey);
      await _vault.delete(_untilKey);
      return const PinCheck(ok: true);
    }
    final fails = (int.tryParse(await _vault.read(_failKey) ?? '') ?? 0) + 1;
    await _vault.write(_failKey, '$fails');
    if (fails >= 5) {
      final wait = 30 * (1 << min(fails - 5, 8));
      await _vault.write(_untilKey, '${t.millisecondsSinceEpoch + wait * 1000}');
      return PinCheck(ok: false, waitSeconds: wait);
    }
    return const PinCheck(ok: false);
  }
}
