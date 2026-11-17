// Config files and secrets (PLAN.md §13.3, phase C-1): models of the agent's /v1/config-files responses, the providers
// that read them, the locally staged edits (and how they become API ops) and the masked line diff of a preview.
// Secret values never appear here: the read routes only return masked text and lengths, and revealed values live in
// config_reveal.dart for 30 seconds.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../state/providers.dart';
import '../incidents/incidents_data.dart' show previewDeadline;
import '../system/agent_providers.dart';

/// No hidden retry loop: the screens have their own refresh.
Duration? _noRetry(int retryCount, Object error) => null;

DateTime? _timeOrNull(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? v) => v is List ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)] : const [];
int? _int(Object? v) => v is num ? v.toInt() : null;

/// Suggested rotation age (days) offered in the secret settings; there is no default policy on the agent.
const suggestedMaxAgeDays = 90;

/// At most this many keys per reveal call (the agent's limit).
const maxRevealKeys = 10;

/// At most this many ops per preview (the agent's limit).
const maxConfigOps = 100;

/// `^[A-Za-z_][A-Za-z0-9_.]*$`, the key syntax of the agent.
final _keyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_.]*$');
bool validConfigKey(String key) => _keyPattern.hasMatch(key);

/// One file of the list.
class ConfigFileInfo {
  ConfigFileInfo(this.host, Map<String, dynamic> j)
      : fileId = '${j['fileId']}',
        file = '${j['file']}',
        source = '${j['source']}',
        stack = j['stack'] as String?,
        size = _int(j['size']) ?? 0,
        modifiedAt = _timeOrNull(j['modifiedAt']),
        keys = _int(j['keys']) ?? 0,
        secrets = _int(j['secrets']) ?? 0,
        worldReadable = j['worldReadable'] == true;
  final Host host;
  final String fileId;

  /// Path relative to its root, as the agent shows it.
  final String file;

  /// stack | extra
  final String source;
  final String? stack;
  final int size;
  final DateTime? modifiedAt;
  final int keys;
  final int secrets;
  final bool worldReadable;
}

/// A file the agent found but doesn't offer, with the reason (badName, notOwner, tooLarge, …).
class SkippedFile {
  SkippedFile(Map<String, dynamic> j)
      : fileId = '${j['fileId']}',
        file = '${j['file']}',
        reason = '${j['reason']}';
  final String fileId;
  final String file;
  final String reason;
}

class ConfigHostFiles {
  ConfigHostFiles(this.host, Map<String, dynamic> j)
      : files = [for (final e in _maps(j['files'])) ConfigFileInfo(host, e)],
        skipped = [for (final e in _maps(j['skipped'])) SkippedFile(e)];
  final Host host;
  final List<ConfigFileInfo> files;
  final List<SkippedFile> skipped;
}

/// Files grouped by stack id (stack order of first appearance); files without a stack (extra paths) come last under null.
List<(String?, List<ConfigFileInfo>)> groupFilesByStack(List<ConfigFileInfo> files) {
  final by = <String?, List<ConfigFileInfo>>{};
  for (final f in files) {
    (by[f.stack] ??= []).add(f);
  }
  final keys = [...by.keys.whereType<String>(), if (by.containsKey(null)) null];
  return [for (final k in keys) (k, by[k]!)];
}

/// One entry of a file: masked unless it is not a secret.
class ConfigEntry {
  ConfigEntry(Map<String, dynamic> j)
      : key = '${j['key']}',
        line = _int(j['line']) ?? 0,
        secret = j['secret'] == true,
        reason = j['reason'] as String?,
        masked = '${j['masked'] ?? ''}',
        length = _int(j['length']) ?? 0,
        value = j['value'] as String?,
        inherited = j['inherited'] == true,
        quote = '${j['quote'] ?? ''}',
        duplicate = j['duplicate'] == true,
        ageDays = _int(j['ageDays']),
        due = j['due'] == true,
        maxAgeDays = _int(j['maxAgeDays']),
        mark = j['mark'] as bool?,
        changedBy = j['changedBy'] as String?;
  final String key;
  final int line;
  final bool secret;

  /// name | uriPassword | entropy | mark | null
  final String? reason;

  /// "••••32"
  final String masked;
  final int length;

  /// Only for non-secrets.
  final String? value;

  /// A bare `KEY` line (taken from the environment).
  final bool inherited;
  final String quote;

  /// An earlier occurrence; the last one wins (it can't be edited from here).
  final bool duplicate;
  final int? ageDays;
  final bool due;
  final int? maxAgeDays;

  /// The user's mark: true = secret, false = not a secret, null = automatic.
  final bool? mark;
  final String? changedBy;
}

class ConfigIssue {
  ConfigIssue(Map<String, dynamic> j)
      : line = _int(j['line']) ?? 0,
        reason = '${j['reason']}';
  final int line;

  /// syntax | unterminatedQuote | trailingText
  final String reason;
}

class ConfigFileDetail {
  ConfigFileDetail(this.host, Map<String, dynamic> j)
      : fileId = '${j['fileId']}',
        file = '${j['file']}',
        source = '${j['source']}',
        stack = j['stack'] as String?,
        hash = '${j['hash']}',
        size = _int(j['size']) ?? 0,
        modifiedAt = _timeOrNull(j['modifiedAt']),
        mode = '${j['mode'] ?? ''}',
        warnings = [for (final w in (j['warnings'] as List? ?? const [])) '$w'],
        entries = [for (final e in _maps(j['entries'])) ConfigEntry(e)],
        issues = [for (final e in _maps(j['issues'])) ConfigIssue(e)];
  final Host host;
  final String fileId;
  final String file;
  final String source;
  final String? stack;

  /// Sent back as `baseHash`; the agent refuses (409 conflict) when the file changed since.
  final String hash;
  final int size;
  final DateTime? modifiedAt;
  final String mode;
  final List<String> warnings;
  final List<ConfigEntry> entries;
  final List<ConfigIssue> issues;

  /// An unterminated quote makes the agent refuse edits (compose would read the lines below into the value).
  ConfigIssue? get unterminatedQuote => issues.where((i) => i.reason == 'unterminatedQuote').firstOrNull;
  bool get readOnly => unterminatedQuote != null;
  List<ConfigIssue> get otherIssues => [for (final i in issues) if (i.reason != 'unterminatedQuote') i];

  ConfigEntry? entry(String key) => entries.where((e) => e.key == key && !e.duplicate).firstOrNull;
}

/// Agent hosts whose health response lists the `configfiles` feature.
final configHostsProvider = FutureProvider.autoDispose<List<Host>>(retry: _noRetry, (ref) async {
  final hosts = ref.watch(profileProvider).hosts.where((h) => h.agent != null).toList();
  final checked = await Future.wait(hosts.map((h) async {
    try {
      final j = await ref.watch(healthProvider(h.id).future);
      return (j['features'] as Map?)?['configfiles'] == true ? h : null;
    } catch (_) {
      return null;
    }
  }));
  return [...checked.nonNulls];
});

final configFilesProvider = FutureProvider.autoDispose.family<ConfigHostFiles, String>(retry: _noRetry, (ref, hostId) async {
  final host = ref.watch(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/config-files')).timeout(const Duration(seconds: 20));
  return ConfigHostFiles(host, _map(j));
});

/// Family key: (host id, file id).
typedef ConfigFileRef = (String, String);

final configFileProvider = FutureProvider.autoDispose.family<ConfigFileDetail, ConfigFileRef>(retry: _noRetry, (ref, key) async {
  final (hostId, fileId) = key;
  final host = ref.watch(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/config-files/$fileId')).timeout(const Duration(seconds: 20));
  return ConfigFileDetail(host, _map(j));
});

class ConfigBackup {
  ConfigBackup(Map<String, dynamic> j)
      : id = '${j['id']}',
        at = _timeOrNull(j['at']),
        size = _int(j['size']) ?? 0;
  final String id;
  final DateTime? at;
  final int size;
}

final configBackupsProvider = FutureProvider.autoDispose.family<List<ConfigBackup>, ConfigFileRef>(retry: _noRetry, (ref, key) async {
  final (hostId, fileId) = key;
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/config-files/$fileId/backups')).timeout(const Duration(seconds: 20));
  return [for (final e in _maps(_map(j)['backups'])) ConfigBackup(e)];
});

// ---------------------------------------------------------------------------------------------------------------------
// Staged edits

/// How a row of the file screen looks after the staged edits.
enum EditState { none, added, changed, renamed, deleted }

/// A row of the file screen: an entry of the file (null for a new key) with its staged state.
class EditRow {
  const EditRow({required this.key, this.entry, this.state = EditState.none, this.newLength, this.newValue});

  /// The key as it will be after saving.
  final String key;
  final ConfigEntry? entry;
  final EditState state;

  /// Length of the staged value (shown masked for secrets and for new keys).
  final int? newLength;

  /// The staged value, only for existing non-secret entries (shown as is).
  final String? newValue;
}

/// The edits staged on the phone before "Save". Each existing key (by its original name) can be deleted, renamed and/or
/// get a new value; new keys are added. [toOps] turns them into the agent's ops. Values live only here, in memory.
class ConfigEdits {
  final _values = <String, String>{};
  final _renames = <String, String>{};
  final _deleted = <String>{};
  final _added = <String, String>{};

  bool get isEmpty => _values.isEmpty && _renames.isEmpty && _deleted.isEmpty && _added.isEmpty;

  /// Number of changed rows.
  int get count => _deleted.length + _added.length + {..._values.keys, ..._renames.keys}.difference(_deleted).length;

  bool isDeleted(String key) => _deleted.contains(key);
  bool isAdded(String key) => _added.containsKey(key);

  /// Is [key] used by a row other than [except] (an original name, a rename target or a new key)? A deleted row frees its
  /// name: the delete goes first when the ops are sent.
  bool nameTaken(String key, List<ConfigEntry> entries, {String? except}) {
    if (key == except) return false;
    for (final e in entries) {
      if (e.key == key && !_deleted.contains(e.key) && !e.duplicate) return true;
    }
    for (final MapEntry(key: orig, value: to) in _renames.entries) {
      if (to == key && orig != except) return true;
    }
    return _added.containsKey(key);
  }

  void setValue(String key, String value, ConfigEntry entry) {
    _deleted.remove(key);
    if (!entry.secret && value == entry.value) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  void rename(String key, String newKey) {
    _deleted.remove(key);
    if (newKey == key) {
      _renames.remove(key);
    } else {
      _renames[key] = newKey;
    }
  }

  void delete(String key) {
    _values.remove(key);
    _renames.remove(key);
    _deleted.add(key);
  }

  /// Drops every staged change of an existing key.
  void undo(String key) {
    _values.remove(key);
    _renames.remove(key);
    _deleted.remove(key);
  }

  void add(String key, String value) => _added[key] = value;
  void removeAdded(String key) => _added.remove(key);

  /// The staged value of a new key (for the edit dialog).
  String? addedValue(String key) => _added[key];

  /// Changes a new key's name and value (the order in the file stays).
  void editAdded(String oldKey, String newKey, String value) {
    final next = <String, String>{};
    for (final MapEntry(:key, value: v) in _added.entries) {
      if (key == oldKey) {
        next[newKey] = value;
      } else {
        next[key] = v;
      }
    }
    _added
      ..clear()
      ..addAll(next);
  }

  void clear() {
    _values.clear();
    _renames.clear();
    _deleted.clear();
    _added.clear();
  }

  /// After the file was reloaded: drops the staged changes whose key is gone (or a new key that exists now). Returns how
  /// many were dropped.
  int reconcile(List<ConfigEntry> entries) {
    final keys = {for (final e in entries) if (!e.duplicate) e.key};
    var dropped = 0;
    for (final k in {..._values.keys, ..._renames.keys, ..._deleted}) {
      if (!keys.contains(k)) {
        undo(k);
        dropped++;
      }
    }
    for (final k in [..._added.keys]) {
      if (keys.contains(k)) {
        _added.remove(k);
        dropped++;
      }
    }
    for (final MapEntry(key: orig, value: to) in [..._renames.entries]) {
      if (keys.contains(to)) {
        _renames.remove(orig);
        dropped++;
      }
    }
    return dropped;
  }

  /// The ops for POST …/preview: deletes, then renames, then value changes (under the new name) and new keys.
  List<Map<String, dynamic>> toOps() => [
        for (final k in _deleted) {'op': 'unset', 'key': k},
        for (final MapEntry(key: k, value: to) in _renames.entries) if (!_deleted.contains(k)) {'op': 'rename', 'key': k, 'newKey': to},
        for (final MapEntry(key: k, value: v) in _values.entries) if (!_deleted.contains(k)) {'op': 'set', 'key': _renames[k] ?? k, 'value': v},
        for (final MapEntry(key: k, value: v) in _added.entries) {'op': 'set', 'key': k, 'value': v},
      ];

  /// The file's entries in order with their staged state, then the new keys.
  List<EditRow> rows(List<ConfigEntry> entries) => [
        for (final e in entries)
          if (e.duplicate)
            EditRow(key: e.key, entry: e)
          else if (_deleted.contains(e.key))
            EditRow(key: e.key, entry: e, state: EditState.deleted)
          else
            EditRow(
              key: _renames[e.key] ?? e.key,
              entry: e,
              state: _values.containsKey(e.key) ? EditState.changed : (_renames.containsKey(e.key) ? EditState.renamed : EditState.none),
              newLength: _values[e.key]?.length,
              newValue: e.secret ? null : _values[e.key],
            ),
        for (final MapEntry(key: k, value: v) in _added.entries) EditRow(key: k, state: EditState.added, newLength: v.length),
      ];
}

// ---------------------------------------------------------------------------------------------------------------------
// Preview

/// One side of a change (the line before or after): its length, and its value only for non-secrets.
class ConfigSide {
  ConfigSide(Map<String, dynamic> j)
      : length = _int(j['length']) ?? 0,
        value = j['value'] as String?,
        inherited = j['inherited'] == true;
  final int length;
  final String? value;
  final bool inherited;
}

class ConfigChange {
  ConfigChange(Map<String, dynamic> j)
      : key = '${j['key']}',
        kind = '${j['change']}',
        from = j['from'] as String?,
        secret = j['secret'] == true,
        before = j['before'] is Map ? ConfigSide(_map(j['before'])) : null,
        after = j['after'] is Map ? ConfigSide(_map(j['after'])) : null;
  final String key;

  /// added | removed | changed | renamed
  final String kind;

  /// The old name of a renamed key.
  final String? from;
  final bool secret;
  final ConfigSide? before;
  final ConfigSide? after;
}

class AffectedServices {
  AffectedServices(Map<String, dynamic> j)
      : stack = '${j['stack'] ?? ''}',
        project = '${j['project'] ?? ''}',
        services = [for (final s in (j['services'] as List? ?? const [])) '$s'];
  final String stack;
  final String project;
  final List<String> services;
}

/// One `docker compose up -d --no-deps` of the restart plan.
class RestartPlanItem {
  RestartPlanItem(Map<String, dynamic> j)
      : stack = '${j['stack'] ?? ''}',
        project = '${j['project'] ?? ''}',
        services = [for (final s in (j['services'] as List? ?? const [])) '$s'],
        argv = [for (final a in (j['argv'] as List? ?? const [])) '$a'];
  final String stack;
  final String project;
  final List<String> services;
  final List<String> argv;
}

/// Result of recreating the affected services after a save.
class RecreateResult {
  RecreateResult(Map<String, dynamic> j)
      : ok = j['ok'] == true,
        stage = j['stage'] as String?,
        stacks = [for (final e in _maps(j['stacks'])) RecreateStack(e)],
        services = [for (final e in _maps(j['services'])) RecreateService(e)],
        skipped = [for (final e in _maps(j['skipped'])) AffectedServices(e)];
  final bool ok;

  /// command | postCheck, on failure.
  final String? stage;
  final List<RecreateStack> stacks;
  final List<RecreateService> services;
  final List<AffectedServices> skipped;
}

class RecreateStack {
  RecreateStack(Map<String, dynamic> j)
      : stack = '${j['stack'] ?? ''}',
        services = [for (final s in (j['services'] as List? ?? const [])) '$s'],
        ok = j['ok'] == true,
        code = _int(j['code']),
        stderr = j['stderr'] as String?;
  final String stack;
  final List<String> services;
  final bool ok;
  final int? code;

  /// Last lines of the command's error output (redacted by the agent).
  final String? stderr;
}

class RecreateService {
  RecreateService(Map<String, dynamic> j)
      : stack = '${j['stack'] ?? ''}',
        service = '${j['service'] ?? ''}',
        ok = j['ok'] == true,
        state = '${j['state'] ?? ''}';
  final String stack;
  final String service;
  final bool ok;
  final String state;
}

/// POST with a long timeout (save/restore with a restart waits for docker compose and the post-check, up to ~3.5 min).
Future<dynamic> configRequest(WidgetRef ref, String hostId, String method, String path, Object? body, {Duration? timeout}) async {
  final host = ref.read(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final c = await ref.read(agentClientFactoryProvider)(host);
  try {
    return await c.request(method, path, body: body, timeout: timeout);
  } finally {
    c.close();
  }
}

/// Timeout of a save/restore with `restart: "affected"`.
const restartTimeout = Duration(seconds: 270);

/// The answer of POST …/preview and of the restore preview.
class ConfigPreview {
  ConfigPreview(Map<String, dynamic> j, DateTime receivedAt)
      : changes = [for (final e in _maps(j['changes'])) ConfigChange(e)],
        otherLinesChanged = j['otherLinesChanged'] == true,
        affected = [for (final e in _maps(j['affected'])) AffectedServices(e)],
        restart = '${j['restart'] ?? 'none'}',
        restartPlan = [for (final e in _maps(j['restartPlan'])) RestartPlanItem(e)],
        token = '${j['previewToken']}',
        deadline = previewDeadline(_timeOrNull(j['expiresAt']), receivedAt);
  final List<ConfigChange> changes;
  final bool otherLinesChanged;
  final List<AffectedServices> affected;

  /// none | affected: the token is bound to this choice.
  final String restart;

  /// With restart "affected": the exact commands that will run, per stack.
  final List<RestartPlanItem> restartPlan;
  final String token;
  final DateTime deadline;

  Duration remaining(DateTime now) {
    final d = deadline.difference(now);
    return d.isNegative ? Duration.zero : d;
  }

  bool expired(DateTime now) => remaining(now) == Duration.zero;
}

/// The answer of PUT …/ and of the confirmed restore.
class ConfigSaveResult {
  ConfigSaveResult(Map<String, dynamic> j)
      : hash = '${j['hash']}',
        backupId = j['backupId'] as String?,
        warnings = [for (final w in (j['warnings'] as List? ?? const [])) '$w'],
        restart = '${j['restart'] ?? 'none'}',
        recreate = j['recreate'] is Map ? RecreateResult(_map(j['recreate'])) : null,
        restoreBackupId = _map(j['restore'])['backupId'] as String?;
  final String hash;
  final String? backupId;
  final List<String> warnings;
  final String restart;

  /// Set when the services were recreated (ok or not).
  final RecreateResult? recreate;

  /// The backup that undoes the save, offered when the recreate failed (the file stays saved).
  final String? restoreBackupId;
}

final _emptySide = ConfigSide(<String, dynamic>{});

/// "••••32": a secret value as the agent masks it.
String maskedText(int length) => '••••$length';

/// A line of the masked diff.
class DiffLine {
  const DiffLine(this.added, this.text);

  /// true: "+" line, false: "-" line.
  final bool added;
  final String text;
}

String _side(String key, ConfigSide s, bool secret) => s.inherited ? key : '$key=${secret ? maskedText(s.length) : (s.value ?? '')}';

/// The "-"/"+" lines of a change: values of secrets are masked, a bare `KEY` line stays bare.
List<DiffLine> changeDiff(ConfigChange c) => switch (c.kind) {
      'added' => [DiffLine(true, _side(c.key, c.after ?? _emptySide, c.secret))],
      'removed' => [DiffLine(false, _side(c.key, c.before ?? _emptySide, c.secret))],
      'renamed' => [
          DiffLine(false, _side(c.from ?? c.key, c.before ?? _emptySide, c.secret)),
          DiffLine(true, _side(c.key, c.after ?? _emptySide, c.secret)),
        ],
      _ => [
          DiffLine(false, _side(c.key, c.before ?? _emptySide, c.secret)),
          DiffLine(true, _side(c.key, c.after ?? _emptySide, c.secret)),
        ],
    };

/// (before, after) lengths of a secret that changed ("changed, 32 → 40 characters"); null otherwise.
(int, int)? secretLengthChange(ConfigChange c) {
  final b = c.before, a = c.after;
  return c.secret && b != null && a != null ? (b.length, a.length) : null;
}
