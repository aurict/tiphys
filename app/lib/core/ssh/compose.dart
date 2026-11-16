// Compose stacks (SSH; no agent needed, works on all hosts). Subfolders of the host's compose roots are searched for
// compose.yaml / compose.yml / docker-compose.yaml / docker-compose.yml (docker's own precedence order;
// the first one found in a folder is used). Commands run in the stack's folder with `docker compose -f <file>`
// (.env and project name as when run by hand).
//
// Update: image IDs are compared before/after pull ("new image pulled"); also, if a running container's image
// differs from the tag's current image, the service counts as "running an old image" (so update also catches a
// previous check-only pull). Only these services are recreated with `up -d`;
// the force option runs `up -d` on the whole stack.
import 'dart:async';
import 'dart:convert';

import 'connection.dart';

class ComposeContainer {
  ComposeContainer(Map j)
      : service = '${j['Service'] ?? ''}',
        name = '${j['Name'] ?? j['Names'] ?? ''}',
        state = '${j['State'] ?? ''}',
        status = '${j['Status'] ?? ''}',
        health = '${j['Health'] ?? ''}',
        image = '${j['Image'] ?? ''}',
        exitCode = (j['ExitCode'] as num?)?.toInt() ?? 0;
  final String service;
  final String name;

  /// running | exited | restarting | paused | created | dead
  final String state;
  final String status;

  /// healthy | unhealthy | starting | "" (no health check)
  final String health;
  final String image;
  final int exitCode;
}

class ComposeStack {
  ComposeStack({required this.dir, required this.file, required this.containers, this.error, this.warnings = ''});

  /// Absolute folder of the stack and name of the compose file.
  final String dir;
  final String file;
  final List<ComposeContainer> containers;

  /// Output of `docker compose ps` if it failed (e.g. missing env variable, docker permission).
  final String? error;
  final String warnings;

  String get name => dir.substring(dir.lastIndexOf('/') + 1);
  int get running => containers.where((c) => c.state == 'running').length;

  /// running | partial | stopped | down (no containers) | error
  String get state => error != null
      ? 'error'
      : containers.isEmpty
          ? 'down'
          : running == containers.length
              ? 'running'
              : running == 0
                  ? 'stopped'
                  : 'partial';
}

class ComposeListing {
  const ComposeListing(this.home, this.stacks);
  final String home;
  final List<ComposeStack> stacks;

  /// Paths under the home directory shown as "~/…".
  String pretty(String path) => home.isNotEmpty && path.startsWith('$home/') ? '~/${path.substring(home.length + 1)}' : path;
}

const composeFileNames = ['compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml'];

/// Script that lists all stacks and container states with a single SSH command.
String composeListScript(List<String> roots) {
  final globs = [
    for (final r in roots)
      for (final f in composeFileNames) '${shellQuote(r.length > 1 && r.endsWith('/') ? r.substring(0, r.length - 1) : r)}/*/$f',
  ];
  return [
    r'''printf '@@home %s\n' "$HOME"''',
    'seen=""',
    'for f in ${globs.join(' ')}; do',
    r'  [ -f "$f" ] || continue',
    r'  d=${f%/*}',
    r'  case "$seen" in *"|$d|"*) continue;; esac',
    r'  seen="$seen|$d|"',
    r'''  printf '@@stack %s\n' "$f"''',
    r'  (cd "$d" && docker compose -f "${f##*/}" ps -a --format json 2>&1)',
    r'''  printf '\n@@exit %s\n' "$?"''',
    'done',
  ].join('\n');
}

/// Parses [composeListScript] output. `ps --format json` gives one object per line in newer versions and
/// a single array in older ones; both are read. Non-JSON lines (warnings, errors) are kept separately.
ComposeListing parseComposeList(String out) {
  var home = '';
  final stacks = <ComposeStack>[];
  String? file;
  var containers = <ComposeContainer>[];
  var text = StringBuffer();
  for (final raw in const LineSplitter().convert(out)) {
    final line = raw.trimRight();
    if (line.startsWith('@@home ')) {
      home = line.substring(7);
    } else if (line.startsWith('@@stack ')) {
      file = line.substring(8);
      containers = [];
      text = StringBuffer();
    } else if (line.startsWith('@@exit ') && file != null) {
      final code = int.tryParse(line.substring(7)) ?? 1;
      final slash = file.lastIndexOf('/');
      final msg = text.toString().trim();
      stacks.add(ComposeStack(
        dir: file.substring(0, slash),
        file: file.substring(slash + 1),
        containers: containers,
        error: code == 0 ? null : (msg.isEmpty ? 'exit $code' : msg),
        warnings: code == 0 ? msg : '',
      ));
      file = null;
    } else if (file != null && line.trim().isNotEmpty) {
      final t = line.trim();
      Object? j;
      if (t.startsWith('{') || t.startsWith('[')) {
        try {
          j = jsonDecode(t);
        } catch (_) {}
      }
      if (j is Map) {
        containers.add(ComposeContainer(j));
      } else if (j is List) {
        containers.addAll(j.whereType<Map>().map(ComposeContainer.new));
      } else {
        text.writeln(t);
      }
    }
  }
  stacks.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return ComposeListing(home, stacks);
}

Future<ComposeListing> listComposeStacks(RemoteShell shell, List<String> roots) async {
  final r = await shell.exec(composeListScript(roots.isEmpty ? const ['~/stack'] : roots), timeout: const Duration(seconds: 90));
  return parseComposeList(r.stdout);
}

class ComposeFailure implements Exception {
  const ComposeFailure(this.step, this.code, [this.detail = '']);

  /// config | pull | up | restart | stop | start | logs
  final String step;
  final int? code;
  final String detail;
  @override
  String toString() => 'ComposeFailure($step, $code${detail.isEmpty ? '' : ': $detail'})';
}

/// Image state: service → tag, the tag's current image ID, the running container's image ID.
class ImageSnapshot {
  const ImageSnapshot(this.imageIds, this.containerImages);

  /// image tag → ID (absent if not present locally).
  final Map<String, String> imageIds;

  /// service → container's image ID (absent if no container).
  final Map<String, String> containerImages;
}

class ComposeCheckResult {
  const ComposeCheckResult({required this.pulled, required this.outdated});

  /// Image tags whose ID changed with pull.
  final List<String> pulled;

  /// Services whose container runs an image different from the tag's current image.
  final List<String> outdated;
}

class ComposeUpdateResult {
  const ComposeUpdateResult({required this.check, required this.recreated, required this.forced});
  final ComposeCheckResult check;

  /// Whether `up -d` ran (recreated services are check.outdated; the whole stack if forced).
  final bool recreated;
  final bool forced;
}

/// Operations on a stack. Output of each long command streams to [onOutput].
class ComposeOps {
  ComposeOps(this.shell, this.stack);
  final RemoteShell shell;
  final ComposeStack stack;

  String get _cd => 'cd ${shellQuote(stack.dir)} && docker compose -f ${shellQuote(stack.file)}';

  /// service → image tag (only services with an image; `build`-only services are not updated).
  Future<Map<String, String>> serviceImages() async {
    final r = await shell.exec('$_cd config --format json', timeout: const Duration(seconds: 60));
    if (r.code != 0) throw ComposeFailure('config', r.code, r.stderr.trim());
    final j = jsonDecode(r.stdout) as Map;
    return {
      for (final MapEntry(:key, :value) in ((j['services'] as Map?) ?? const {}).entries)
        if (value is Map && value['image'] is String && value['build'] == null) '$key': value['image'] as String,
    };
  }

  Future<ImageSnapshot> snapshot(Iterable<String> images) async {
    final script = [
      'cd ${shellQuote(stack.dir)} || exit 1',
      for (final i in images.toSet()) "printf '@@img %s %s\\n' \"\$(docker image inspect --format '{{.Id}}' ${shellQuote(i)} 2>/dev/null || echo -)\" ${shellQuote(i)}",
      'ids=\$(docker compose -f ${shellQuote(stack.file)} ps -a -q 2>/dev/null)',
      '[ -n "\$ids" ] && docker inspect --format \'@@ctr {{index .Config.Labels "com.docker.compose.service"}} {{.Image}}\' \$ids',
      'true',
    ].join('\n');
    final r = await shell.exec(script, timeout: const Duration(seconds: 60));
    final ids = <String, String>{}, ctr = <String, String>{};
    for (final line in const LineSplitter().convert(r.stdout)) {
      final p = line.trim().split(' ');
      if (p.length == 3 && p[0] == '@@img' && p[1] != '-') ids[p[2]] = p[1];
      if (p.length == 3 && p[0] == '@@ctr') ctr[p[1]] = p[2];
    }
    return ImageSnapshot(ids, ctr);
  }

  static ComposeCheckResult compare(Map<String, String> services, ImageSnapshot before, ImageSnapshot after) {
    final pulled = [
      for (final i in services.values.toSet())
        if (after.imageIds[i] != null && before.imageIds[i] != after.imageIds[i]) i,
    ]..sort();
    final outdated = [
      for (final MapEntry(key: svc, value: img) in services.entries)
        if (after.containerImages[svc] != null && after.imageIds[img] != null && after.containerImages[svc] != after.imageIds[img]) svc,
    ]..sort();
    return ComposeCheckResult(pulled: pulled, outdated: outdated);
  }

  Future<int?> _stream(String args, void Function(String) onOutput, {Duration timeout = const Duration(minutes: 20)}) {
    onOutput('\$ docker compose $args\n');
    return shell.execStreaming('$_cd $args', onOutput, timeout: timeout);
  }

  /// pull + compare (does not restart).
  Future<(Map<String, String>, ComposeCheckResult)> check(void Function(String) onOutput) async {
    final services = await serviceImages();
    final before = await snapshot(services.values);
    final code = await _stream('pull --ignore-buildable', onOutput);
    if (code != 0) throw ComposeFailure('pull', code);
    final after = await snapshot(services.values);
    return (services, compare(services, before, after));
  }

  /// pull; `up -d` if any service runs an old image (or [force]).
  Future<ComposeUpdateResult> update(void Function(String) onOutput, {bool force = false}) async {
    final (_, c) = await check(onOutput);
    if (c.outdated.isEmpty && !force) return ComposeUpdateResult(check: c, recreated: false, forced: false);
    final code = await _stream(force ? 'up -d' : 'up -d ${c.outdated.map(shellQuote).join(' ')}', onOutput);
    if (code != 0) throw ComposeFailure('up', code);
    return ComposeUpdateResult(check: c, recreated: true, forced: force);
  }

  Future<void> simple(String step, void Function(String) onOutput) async {
    final args = switch (step) {
      'restart' => 'restart',
      'stop' => 'stop',
      'start' => 'up -d',
      _ => throw ArgumentError(step),
    };
    final code = await _stream(args, onOutput, timeout: const Duration(minutes: 10));
    if (code != 0) throw ComposeFailure(step, code);
  }

  Future<String> logs({int tail = 200}) async {
    final r = await shell.exec('$_cd logs --no-color --tail $tail', timeout: const Duration(seconds: 45));
    if (r.code != 0) throw ComposeFailure('logs', r.code, r.stderr.trim());
    return r.stdout.isEmpty ? r.stderr : r.stdout;
  }
}
