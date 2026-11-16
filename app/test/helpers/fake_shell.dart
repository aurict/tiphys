// Fake SSH shell for compose tests: records commands and replies with docker compose's real output formats
// (taken from Docker Compose 2.40 on atlas). No network access.
import 'dart:convert';

import 'package:tiphys/core/ssh/connection.dart';

typedef ShellReply = ({String stdout, String stderr, int code});

class FakeShell implements RemoteShell {
  FakeShell(this.handler);
  final ShellReply Function(String command) handler;
  final commands = <String>[];
  bool closed = false;

  @override
  Future<({String stdout, String stderr, int? code})> exec(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    commands.add(command);
    final r = handler(command);
    return (stdout: r.stdout, stderr: r.stderr, code: r.code);
  }

  @override
  Future<int?> execStreaming(String command, void Function(String chunk) onOutput, {Duration timeout = const Duration(minutes: 20)}) async {
    commands.add(command);
    final r = handler(command);
    for (final line in const LineSplitter().convert('${r.stdout}${r.stderr}')) {
      onOutput('$line\n');
    }
    return r.code;
  }

  @override
  void close() => closed = true;
}

String _ps(String project, String service, String state, String status, {String health = '', String image = 'img', int exit = 0}) => jsonEncode({
      'Command': '"/entrypoint.sh"',
      'CreatedAt': '2026-11-01 10:00:00 +0000 UTC',
      'ExitCode': exit,
      'Health': health,
      'ID': '6e669fb1b994',
      'Image': image,
      'Labels': 'com.docker.compose.project=$project,com.docker.compose.service=$service',
      'Name': '$project-$service-1',
      'Names': '$project-$service-1',
      'Project': project,
      'RunningFor': '2 weeks ago',
      'Service': service,
      'State': state,
      'Status': status,
    });

/// A host's stacks: web (running), monitoring (one down, one unhealthy), aurict (missing environment
/// variable), yedek (never started). Image IDs for `web` can change with pull.
class FakeComposeHost {
  /// image tag → ID; [afterPull] is applied after a pull.
  final ids = <String, String>{'nginx:1.27-alpine': 'sha256:aaa', 'redis:7': 'sha256:bbb'};
  final afterPull = <String, String>{};

  /// service → the container's image ID.
  final containers = <String, String>{'nginx': 'sha256:aaa', 'cache': 'sha256:bbb'};
  int pullCode = 0;
  int upCode = 0;
  late final shell = FakeShell(handle);

  static const home = '/home/ubuntu';

  String get listing => [
        '@@home $home',
        '@@stack $home/stack/web/compose.yaml',
        _ps('web', 'nginx', 'running', 'Up 2 weeks', image: 'nginx:1.27-alpine'),
        _ps('web', 'cache', 'running', 'Up 2 weeks', image: 'redis:7'),
        '',
        '@@exit 0',
        '@@stack $home/stack/monitoring/compose.yaml',
        'time="2026-11-14T10:00:00Z" level=warning msg="/home/ubuntu/stack/monitoring/compose.yaml: the attribute `version` is obsolete"',
        _ps('monitoring', 'grafana', 'running', 'Up 3 days (healthy)', health: 'healthy', image: 'grafana/grafana:12.1'),
        _ps('monitoring', 'prometheus', 'running', 'Up 3 days (unhealthy)', health: 'unhealthy', image: 'prom/prometheus:v3'),
        _ps('monitoring', 'node-exporter', 'exited', 'Exited (1) 2 hours ago', image: 'prom/node-exporter:v1', exit: 1),
        '',
        '@@exit 0',
        '@@stack $home/stack/aurict/compose.yml',
        'error while interpolating services.web.image: required variable AURICT_IMAGE_WEB is missing a value: run bin/aurict-deploy',
        '',
        '@@exit 15',
        '@@stack $home/stack/yedek/docker-compose.yml',
        '',
        '@@exit 0',
      ].join('\n');

  ShellReply handle(String cmd) {
    ShellReply ok(String out) => (stdout: out, stderr: '', code: 0);
    if (cmd.contains('@@home')) return ok('$listing\n');
    if (cmd.contains('config --format json')) {
      return ok(jsonEncode({
        'name': 'web',
        'services': {
          'nginx': {'image': 'nginx:1.27-alpine', 'restart': 'unless-stopped'},
          'cache': {'image': 'redis:7'},
          'builder': {'build': {'context': '.'}},
        },
      }));
    }
    if (cmd.contains('@@img')) {
      return ok([
        for (final i in ['nginx:1.27-alpine', 'redis:7']) '@@img ${ids[i] ?? '-'} $i',
        for (final MapEntry(:key, :value) in containers.entries) '@@ctr $key $value',
      ].join('\n'));
    }
    if (cmd.contains(' pull ')) {
      if (pullCode != 0) return (stdout: '', stderr: 'Error response from daemon: manifest unknown\n', code: pullCode);
      ids.addAll(afterPull);
      return (stdout: '', stderr: ' nginx Pulling \n cache Pulling \n nginx Pulled \n cache Pulled \n', code: 0);
    }
    if (cmd.contains(' up -d')) {
      if (upCode != 0) return (stdout: '', stderr: 'Error: port is already allocated\n', code: upCode);
      for (final s in containers.keys.toList()) {
        if (cmd.endsWith(' up -d') || cmd.contains("'$s'")) containers[s] = ids[s == 'nginx' ? 'nginx:1.27-alpine' : 'redis:7']!;
      }
      return (stdout: '', stderr: ' Container web-nginx-1 Recreate \n Container web-nginx-1 Recreated \n Container web-nginx-1 Started \n', code: 0);
    }
    if (cmd.contains(' logs ')) return ok('web-nginx-1  | 10.0.0.2 - - "GET / HTTP/1.1" 200\nweb-cache-1  | Ready to accept connections tcp\n');
    if (cmd.endsWith(' restart') || cmd.endsWith(' stop')) return (stdout: '', stderr: ' Container web-nginx-1 Restarting \n Container web-nginx-1 Started \n', code: 0);
    return (stdout: '', stderr: 'unexpected: $cmd', code: 127);
  }
}
