// SSH keys: import (OpenSSH/PEM, passphrase-protected too), ed25519 generation, public key line.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:dartssh2/dartssh2.dart';

class InvalidKey implements Exception {
  const InvalidKey([this.reason]);
  final String? reason;
}

class NeedsPassphrase implements Exception {
  const NeedsPassphrase();
}

class ParsedKey {
  const ParsedKey({required this.type, required this.publicLine, required this.unencryptedPem});
  final String type;

  /// authorized_keys line: "ssh-ed25519 AAAA… label"
  final String publicLine;

  /// Passphrase-less PEM to store in the vault (the vault is already encrypted).
  final String unencryptedPem;
}

String publicLineOf(SSHKeyPair pair, String comment) {
  final pub = pair.toPublicKey();
  return '${pair.type} ${base64.encode(pub.encode())}${comment.isEmpty ? '' : ' $comment'}';
}

/// Reads a private key. Throws [NeedsPassphrase] if it is passphrase-protected and no passphrase was given.
ParsedKey parsePrivateKey(String text, {String? passphrase, String comment = ''}) {
  final pem = text.trim();
  if (!pem.startsWith('-----BEGIN')) throw const InvalidKey('pem');
  try {
    if (SSHKeyPair.isEncryptedPem(pem) && (passphrase == null || passphrase.isEmpty)) throw const NeedsPassphrase();
    final pairs = SSHKeyPair.fromPem(pem, passphrase);
    if (pairs.isEmpty) throw const InvalidKey('empty');
    final pair = pairs.first;
    return ParsedKey(type: pair.type, publicLine: publicLineOf(pair, comment), unencryptedPem: _unencrypted(pair, pem));
  } on NeedsPassphrase {
    rethrow;
  } on InvalidKey {
    rethrow;
  } catch (e) {
    if (passphrase != null) throw const InvalidKey('passphrase');
    throw InvalidKey(e.runtimeType.toString());
  }
}

String _unencrypted(SSHKeyPair pair, String original) {
  // Passphrase-less OpenSSH keys are stored as-is; others are converted to OpenSSH format.
  if (!SSHKeyPair.isEncryptedPem(original)) return original.endsWith('\n') ? original : '$original\n';
  return pair.toPem();
}

/// Generates a new ed25519 key on the phone.
Future<ParsedKey> generateEd25519(String comment) async {
  final algo = c.Ed25519();
  final kp = await algo.newKeyPair();
  final seed = await kp.extractPrivateKeyBytes();
  final pub = (await kp.extractPublicKey()).bytes;
  // OpenSSH ed25519 private key = 32-byte seed + 32-byte public key.
  final pair = OpenSSHEd25519KeyPair(Uint8List.fromList(pub), Uint8List.fromList([...seed, ...pub]), comment);
  return ParsedKey(type: pair.type, publicLine: publicLineOf(pair, comment), unencryptedPem: pair.toPem());
}

/// Shell command to append to authorized_keys (without duplicates). The key is safely escaped in single quotes.
String installKeyCommand(String publicLine) {
  final q = "'${publicLine.replaceAll("'", "'\\''")}'";
  return 'umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && '
      'chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && '
      '(grep -qxF $q ~/.ssh/authorized_keys || printf "%s\\n" $q >> ~/.ssh/authorized_keys) && echo TIPHYS_KEY_OK';
}
