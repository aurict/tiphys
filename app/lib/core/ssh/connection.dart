// SSH connection: host from the profile + key/password from the vault; provides shell, commands and SFTP.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../profile/model.dart';
import '../secrets/secret_store.dart';

class SshFailure implements Exception {
  const SshFailure(this.code, [this.detail]);

  /// noSsh | missingSecret | unreachable | auth | timeout | hostKeyChanged | other
  final String code;
  final String? detail;
  @override
  String toString() => 'SshFailure($code${detail == null ? '' : ': $detail'})';
}

/// Server keys are saved on first connection (TOFU); if they change later the connection is refused.
abstract class KnownHosts {
  Future<String?> fingerprint(String hostPort);
  Future<void> remember(String hostPort, String fingerprint);
}

class SecretKnownHosts implements KnownHosts {
  SecretKnownHosts(this.store);
  final SecretStore store;
  String _id(String hp) => 'knownhost-${hp.replaceAll(RegExp(r'[^a-z0-9]+'), '-')}';
  @override
  Future<String?> fingerprint(String hostPort) => store.read(_id(hostPort.toLowerCase()));
  @override
  Future<void> remember(String hostPort, String fingerprint) => store.write(_id(hostPort.toLowerCase()), fingerprint);
}

class MemoryKnownHosts implements KnownHosts {
  final m = <String, String>{};
  @override
  Future<String?> fingerprint(String hostPort) async => m[hostPort];
  @override
  Future<void> remember(String hostPort, String fingerprint) async => m[hostPort] = fingerprint;
}

/// Remote command runner (compose screen; tests supply a fake).
abstract interface class RemoteShell {
  Future<({String stdout, String stderr, int? code})> exec(String command, {Duration timeout});

  /// Output (stdout and stderr) is passed to [onOutput] as it arrives; returns the exit code.
  Future<int?> execStreaming(String command, void Function(String chunk) onOutput, {Duration timeout});

  void close();
}

class SshConnection implements RemoteShell {
  SshConnection._(this.host, this.client);
  final Host host;
  final SSHClient client;

  static Future<SshConnection> open(
    Host host,
    SecretStore secrets, {
    KnownHosts? knownHosts,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final ssh = host.ssh;
    if (ssh == null) throw const SshFailure('noSsh');
    final secret = await secrets.read(secretIdOf(ssh.auth.ref));
    if (secret == null) throw SshFailure('missingSecret', secretIdOf(ssh.auth.ref));

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host.address, ssh.port, timeout: timeout);
    } on TimeoutException {
      throw const SshFailure('timeout');
    } catch (e) {
      throw SshFailure('unreachable', e.toString());
    }

    final hostPort = '${host.address}:${ssh.port}';
    var hostKeyChanged = false;
    final client = SSHClient(
      socket,
      username: ssh.user,
      identities: switch (ssh.auth) {
        SshKeyAuth() => SSHKeyPair.fromPem(secret),
        SshPasswordAuth() => null,
      },
      onPasswordRequest: switch (ssh.auth) {
        SshPasswordAuth() => () => secret,
        SshKeyAuth() => null,
      },
      onVerifyHostKey: (type, fp) async {
        if (knownHosts == null) return true;
        final hex = fp.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
        final known = await knownHosts.fingerprint(hostPort);
        if (known == null) {
          await knownHosts.remember(hostPort, '$type $hex');
          return true;
        }
        if (known == '$type $hex') return true;
        hostKeyChanged = true;
        return false;
      },
      keepAliveInterval: const Duration(seconds: 20),
    );
    try {
      await client.authenticated.timeout(timeout);
    } on TimeoutException {
      client.close();
      throw const SshFailure('timeout');
    } on SSHAuthFailError catch (e) {
      client.close();
      throw SshFailure('auth', e.message);
    } catch (e) {
      client.close();
      if (hostKeyChanged) throw const SshFailure('hostKeyChanged');
      throw SshFailure('other', e.toString());
    }
    return SshConnection._(host, client);
  }

  /// Runs a command; returns stdout, stderr and the exit code.
  @override
  Future<({String stdout, String stderr, int? code})> exec(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    final session = await client.execute(command);
    final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
    final a = session.stdout.listen(out.add).asFuture<void>();
    final b = session.stderr.listen(err.add).asFuture<void>();
    await Future.wait([a, b, session.done]).timeout(timeout);
    return (
      stdout: utf8.decode(out.takeBytes(), allowMalformed: true),
      stderr: utf8.decode(err.takeBytes(), allowMalformed: true),
      code: session.exitCode,
    );
  }

  /// Long-running command (e.g. docker compose pull): output is delivered in chunks, preserving UTF-8 boundaries.
  /// On timeout the session is closed and a TimeoutException is thrown.
  @override
  Future<int?> execStreaming(String command, void Function(String chunk) onOutput, {Duration timeout = const Duration(minutes: 20)}) async {
    final session = await client.execute(command);
    const dec = Utf8Decoder(allowMalformed: true);
    final a = dec.bind(session.stdout).listen(onOutput).asFuture<void>();
    final b = dec.bind(session.stderr).listen(onOutput).asFuture<void>();
    try {
      await Future.wait([a, b, session.done]).timeout(timeout);
    } on TimeoutException {
      session.close();
      rethrow;
    }
    return session.exitCode;
  }

  /// Interactive shell: attaches to the named tmux session if tmux exists (creating it if needed), else a login shell.
  Future<SSHSession> shell({required int cols, required int rows, String? startDir}) {
    final name = host.ssh!.tmuxSession;
    final cd = startDir == null ? '' : 'cd ${shellQuote(startDir)} 2>/dev/null; ';
    final cmd = "${cd}if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s ${shellQuote(name)}; "
        'else exec "\${SHELL:-/bin/sh}" -l; fi';
    return client.execute(cmd, pty: SSHPtyConfig(type: 'xterm-256color', width: cols, height: rows));
  }

  Future<SftpClient> sftp() => client.sftp();

  @override
  void close() => client.close();
}

/// Safe single-quote escaping for the shell. Paths starting with "~/" are handled separately so they expand to home.
String shellQuote(String s) {
  if (s == '~') return r'"$HOME"';
  if (s.startsWith('~/')) return '"\$HOME"/${shellQuote(s.substring(2))}';
  return "'${s.replaceAll("'", "'\\''")}'";
}
