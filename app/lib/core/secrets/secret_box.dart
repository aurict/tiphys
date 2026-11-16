// Encrypted backup: password → Argon2id → key; secrets are encrypted with XChaCha20-Poly1305.
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart' as c;

class Argon2Params {
  const Argon2Params({this.memoryKiB = 19456, this.iterations = 2, this.parallelism = 1});

  /// OWASP recommendation: m=19 MiB, t=2, p=1.
  static const standard = Argon2Params();
  final int memoryKiB;
  final int iterations;
  final int parallelism;
}

class WrongPassphrase implements Exception {
  const WrongPassphrase();
}

class SecretSeal {
  static final _cipher = c.Xchacha20.poly1305Aead();
  static const _macLength = 16;

  static List<int> _random(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  static Future<c.SecretKey> _derive(String passphrase, List<int> salt, Argon2Params p) {
    final kdf = c.Argon2id(memory: p.memoryKiB, iterations: p.iterations, parallelism: p.parallelism, hashLength: 32);
    return kdf.deriveKey(secretKey: c.SecretKey(utf8.encode(passphrase)), nonce: salt);
  }

  /// Encrypts secrets ({id: value}) and returns the `encryptedSecrets` object for the profile file.
  static Future<Map<String, dynamic>> seal(
    Map<String, String> secrets,
    String passphrase, {
    Argon2Params params = Argon2Params.standard,
  }) async {
    final salt = _random(16);
    final key = await _derive(passphrase, salt, params);
    final nonce = _random(24);
    final box = await _cipher.encrypt(utf8.encode(jsonEncode({'secrets': secrets})), secretKey: key, nonce: nonce);
    return {
      'v': 1,
      'kdf': {
        'name': 'argon2id',
        'memoryKiB': params.memoryKiB,
        'iterations': params.iterations,
        'parallelism': params.parallelism,
        'salt': base64.encode(salt),
      },
      'cipher': 'xchacha20-poly1305',
      'nonce': base64.encode(nonce),
      'ciphertext': base64.encode([...box.cipherText, ...box.mac.bytes]),
    };
  }

  static Future<Map<String, String>> open(Map<String, dynamic> sealed, String passphrase) async {
    final kdf = Map<String, dynamic>.from(sealed['kdf'] as Map);
    final params = Argon2Params(
      memoryKiB: kdf['memoryKiB'] as int,
      iterations: kdf['iterations'] as int,
      parallelism: kdf['parallelism'] as int,
    );
    final key = await _derive(passphrase, base64.decode(kdf['salt'] as String), params);
    final all = base64.decode(sealed['ciphertext'] as String);
    if (all.length < _macLength) throw const WrongPassphrase();
    final box = c.SecretBox(
      all.sublist(0, all.length - _macLength),
      nonce: base64.decode(sealed['nonce'] as String),
      mac: c.Mac(all.sublist(all.length - _macLength)),
    );
    try {
      final clear = await _cipher.decrypt(box, secretKey: key);
      final json = jsonDecode(utf8.decode(clear)) as Map;
      return Map<String, String>.from(json['secrets'] as Map);
    } on c.SecretBoxAuthenticationError {
      throw const WrongPassphrase();
    }
  }
}
