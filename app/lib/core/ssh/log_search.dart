// Cross-server log search (SSH; no agent needed, works on all hosts). A single script per host:
// - systemd journal: `journalctl -g <PCRE> -o json -n N --since` (system + `--user`). The pattern is plain text:
//   PCRE special characters are escaped and it is searched case-insensitively with `(?i)`.
// - Running containers: `docker logs --since --timestamps` → `grep -i -F -m M` (fixed string), with the container
//   name prefixed to each line.
// If the user can't read the system journal (not in the adm/systemd-journal group), journalctl returns only the
// user's entries: this is detected from the hint printed with `-n 0` and noted in the result. Output is capped per
// host at [LogQuery.maxBytes]; the script runs via `sh -c` (the PC's login shell may be zsh).
import 'dart:convert';

import 'connection.dart';

class LogQuery {
  const LogQuery({required this.pattern, required this.since, this.journalLimit = 200, this.dockerLimit = 50, this.maxBytes = 2000000});

  /// Plain text (not a regex). Must be cleaned with [normalizeLogPattern].
  final String pattern;
  final Duration since;

  /// Max entries per journalctl (system and user separately).
  final int journalLimit;

  /// Max matching lines per container.
  final int dockerLimit;

  /// Total output limit per host (bytes).
  final int maxBytes;
}

class LogHit {
  const LogHit({required this.hostId, required this.kind, required this.source, required this.time, required this.message, this.priority, this.seq = 0});
  final String hostId;

  /// journal | docker
  final String kind;

  /// systemd unit / identifier or container name.
  final String source;
  final DateTime? time;
  final String message;

  /// syslog priority (0 emergency … 7 debug); journal only.
  final int? priority;

  /// Output order on the host (so lines with the same time keep their order).
  final int seq;
}

class LogSearchResult {
  const LogSearchResult({
    required this.hostId,
    required this.hits,
    this.userOnly = false,
    this.journalErrors = const [],
    this.dockerError,
    this.dockerMissing = false,
    this.truncated = false,
  });
  final String hostId;
  final List<LogHit> hits;

  /// System journal is unreadable; only the user journal was searched.
  final bool userOnly;

  /// Non-JSON output of journalctl (e.g. no pattern support, invalid option).
  final List<String> journalErrors;

  /// `docker ps` failed (e.g. no permission).
  final String? dockerError;
  final bool dockerMissing;

  /// Output reached the [LogQuery.maxBytes] limit; results may be incomplete.
  final bool truncated;
}

/// Turns the user's pattern into single-line plain text (line breaks and NUL become spaces, edges trimmed).
String normalizeLogPattern(String s) => s.replaceAll(RegExp(r'[\r\n\t\x00]+'), ' ').trim();

/// Escapes plain text so it matches literally inside PCRE (journalctl -g).
String pcreEscape(String s) => s.replaceAllMapped(RegExp(r'[\\^$.|?*+()\[\]{}/#\-]'), (m) => '\\${m[0]}');

/// Literal single-quote escaping. Unlike [shellQuote], a pattern starting with "~/" is not expanded to home.
String _lit(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// Search script to run on a host (full command wrapped in `sh -c`).
String logSearchCommand(LogQuery q) {
  final s = q.since.inSeconds.clamp(60, 7 * 24 * 3600);
  final script = [
    'P=${_lit(q.pattern)}',
    'R=${_lit('(?i)${pcreEscape(q.pattern)}')}',
    '{',
    "echo '@@j system'",
    'timeout 25 journalctl --no-pager --since=-${s}s -g "\$R" -o json -n ${q.journalLimit} 2>&1',
    "echo '@@j user'",
    'timeout 25 journalctl --user --no-pager --since=-${s}s -g "\$R" -o json -n ${q.journalLimit} 2>&1',
    // Without permission to read the system journal, journalctl prints a hint in short output (not in JSON output).
    "if { timeout 10 journalctl --no-pager -n 0 >/dev/null; } 2>&1 | grep -q 'not seeing messages from other users'; then echo '@@useronly'; fi",
    'if command -v docker >/dev/null 2>&1; then',
    "  if names=\$(timeout 10 docker ps --format '{{.Names}}' 2>&1); then",
    '    for c in \$names; do',
    '      timeout 15 docker logs --since ${s}s --timestamps "\$c" 2>&1 | grep -i -F -m ${q.dockerLimit} -e "\$P" | awk -v c="\$c" \'{print "@@d " c " " \$0}\'',
    '    done',
    '  else',
    "    printf '@@dockererr %s\\n' \"\$(printf '%s' \"\$names\" | head -n 1)\"",
    '  fi',
    'else',
    "  echo '@@nodocker'",
    'fi',
    '} | head -c ${q.maxBytes}',
  ].join('\n');
  return 'sh -c ${shellQuote(script)}';
}

String _journalSource(Map j) {
  String? s(String k) => j[k] is String && (j[k] as String).isNotEmpty ? j[k] as String : null;
  var unit = s('_SYSTEMD_USER_UNIT') ?? s('_SYSTEMD_UNIT');
  if (unit != null && (unit.endsWith('.scope') || unit.startsWith('user@') || unit.endsWith('.slice'))) unit = null;
  final name = unit ?? s('SYSLOG_IDENTIFIER') ?? s('_COMM') ?? 'journal';
  return name.endsWith('.service') ? name.substring(0, name.length - 8) : name;
}

String _journalMessage(Object? m) => switch (m) {
      String() => m,
      List() => utf8.decode(m.whereType<int>().toList(), allowMalformed: true),
      _ => '',
    };

/// RFC 3339 timestamp (docker: nanoseconds) → DateTime. Dart reads at most microseconds.
DateTime? parseLogTime(String s) {
  final m = RegExp(r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$').firstMatch(s);
  if (m == null) return null;
  final frac = m[2] == null ? '' : '.${m[2]!.length > 6 ? m[2]!.substring(0, 6) : m[2]}';
  return DateTime.tryParse('${m[1]}$frac${m[3]}');
}

/// Parses [logSearchCommand] output.
LogSearchResult parseLogSearch(String hostId, String out, LogQuery q) {
  final hits = <LogHit>[];
  final cursors = <String>{};
  final journalErrors = <String>[];
  var userOnly = false, dockerMissing = false;
  String? dockerError;
  var section = '';
  var seq = 0;
  final needle = RegExp(RegExp.escape(q.pattern), caseSensitive: false, unicode: true);
  for (final line in const LineSplitter().convert(out)) {
    if (line.startsWith('@@j ')) {
      section = 'journal';
    } else if (line == '@@useronly') {
      userOnly = true;
    } else if (line == '@@nodocker') {
      dockerMissing = true;
    } else if (line.startsWith('@@dockererr ')) {
      dockerError = line.substring(12).trim();
    } else if (line.startsWith('@@d ')) {
      section = 'docker';
      final rest = line.substring(4);
      final sp = rest.indexOf(' ');
      if (sp <= 0) continue;
      final name = rest.substring(0, sp);
      var msg = rest.substring(sp + 1);
      final sp2 = msg.indexOf(' ');
      final time = sp2 > 0 ? parseLogTime(msg.substring(0, sp2)) : parseLogTime(msg);
      if (time != null) msg = sp2 > 0 ? msg.substring(sp2 + 1) : '';
      // grep may also match in the timestamp (e.g. searching "18:20"): keep only matches in the message.
      if (!needle.hasMatch(msg)) continue;
      hits.add(LogHit(hostId: hostId, kind: 'docker', source: name, time: time?.toLocal(), message: msg, seq: seq++));
    } else if (section == 'journal') {
      final t = line.trim();
      if (t.startsWith('{')) {
        Object? j;
        try {
          j = jsonDecode(t);
        } catch (_) {
          continue; // last line cut at the limit
        }
        if (j is! Map) continue;
        final cursor = j['__CURSOR'];
        if (cursor is String && !cursors.add(cursor)) continue; // system + user overlap
        final us = int.tryParse('${j['__REALTIME_TIMESTAMP']}');
        hits.add(LogHit(
          hostId: hostId,
          kind: 'journal',
          source: _journalSource(j),
          time: us == null ? null : DateTime.fromMicrosecondsSinceEpoch(us),
          message: _journalMessage(j['MESSAGE']),
          priority: int.tryParse('${j['PRIORITY']}'),
          seq: seq++,
        ));
      } else if (t.isNotEmpty && !t.startsWith('-- ') && journalErrors.length < 3 && !journalErrors.contains(t)) {
        journalErrors.add(t);
      }
    }
  }
  return LogSearchResult(
    hostId: hostId,
    hits: hits,
    userOnly: userOnly,
    journalErrors: journalErrors,
    dockerError: dockerError,
    dockerMissing: dockerMissing,
    truncated: utf8.encode(out).length >= q.maxBytes, // head -c cuts exactly at the limit
  );
}

Future<LogSearchResult> searchHostLogs(RemoteShell shell, String hostId, LogQuery q, {Duration timeout = const Duration(seconds: 75)}) async {
  final r = await shell.exec(logSearchCommand(q), timeout: timeout);
  return parseLogSearch(hostId, r.stdout, q);
}

/// Merges hosts' results newest to oldest. Entries without a time go last; ties keep host and output order.
List<LogHit> mergeLogHits(Iterable<LogSearchResult> results) {
  final all = [for (final r in results) ...r.hits];
  all.sort((a, b) {
    final ta = a.time, tb = b.time;
    if (ta != null && tb != null && ta != tb) return tb.compareTo(ta);
    if ((ta == null) != (tb == null)) return ta == null ? 1 : -1;
    final h = a.hostId.compareTo(b.hostId);
    return h != 0 ? h : b.seq.compareTo(a.seq);
  });
  return all;
}

/// Ranges where the pattern occurs in the text (case-insensitive); for highlighting.
List<(int, int)> logMatchRanges(String text, String pattern) {
  if (pattern.isEmpty) return const [];
  return [for (final m in RegExp(RegExp.escape(pattern), caseSensitive: false, unicode: true).allMatches(text)) (m.start, m.end)];
}
