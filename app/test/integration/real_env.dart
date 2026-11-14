// Gerçek sunucu testlerinin hedefleri (yalnız `--tags real`): ~/.config/tiphys/real-test.json — repoda değil.
// Biçim için bkz. real-test.example.json. Dosya yoksa bu testler hata verir (varsayılan test koşusunda çalışmazlar).
import 'dart:convert';
import 'dart:io';

final _home = Platform.environment['HOME']!;

class RealEnv {
  RealEnv(this._j);
  final Map<String, dynamic> _j;

  static RealEnv load() {
    final f = File(Platform.environment['TIPHYS_REAL_TEST'] ?? '$_home/.config/tiphys/real-test.json');
    return RealEnv(f.existsSync() ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic> : const {});
  }

  String _s(String k) => _j[k] as String? ?? (throw StateError('real-test.json: "$k" eksik'));
  String _path(String k) => _s(k).replaceFirst('~', _home);

  /// Tailnet alan adı, ör. example.ts.net
  String get tailnet => _s('tailnet');

  /// Ajanlı PC, ajanlı sunucu, ajansız sunucu (yalnız SSH).
  String get pc => _s('pc');
  String get server => _s('server');
  String get server2 => _s('server2');

  String host(String name) => '$name.$tailnet';
  String agent(String name) => 'https://$name.$tailnet:7443';

  String get sshUser => _s('sshUser');
  String get sshKey => _path('sshKey');
  String get pcToken => _path('pcTokenFile');
  String get serverToken => _path('serverTokenFile');
  String get grafanaToken => _path('grafanaTokenFile');

  /// Uptime Kuma'da bulunması beklenen bir site adı.
  String get uptimeSite => _s('uptimeSite');
}

final real = RealEnv.load();
