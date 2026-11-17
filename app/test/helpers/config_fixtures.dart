// Sample config-file data and the fake agent's /v1/config-files + /v1/secrets/meta routes (agent/src/configfiles/*).
// Every secret value here is an obviously fake placeholder.
import 'package:tiphys/core/agent/agent_client.dart';

final _clock = DateTime(2026, 11, 14, 14, 5);
String _at(int daysAgo) => _clock.subtract(Duration(days: daysAgo)).toUtc().toIso8601String();

/// A fake value that must be the only secret text a golden may ever show.
const fakeSecretValue = 'EXAMPLE-NOT-A-REAL-SECRET-0001';

class FakeEntry {
  FakeEntry(this.key, this.value, {this.secret = false, this.inherited = false, this.duplicate = false, this.ageDays, this.maxAgeDays, this.mark});
  String key;
  String value;
  bool secret;
  bool inherited;
  bool duplicate;
  int? ageDays;
  int? maxAgeDays;
  bool? mark;

  FakeEntry copy() => FakeEntry(key, value, secret: secret, inherited: inherited, duplicate: duplicate, ageDays: ageDays, maxAgeDays: maxAgeDays, mark: mark);
}

class FakeConfigFile {
  FakeConfigFile(this.fileId, this.file, this.stack, this.entries, {this.worldReadable = false, this.source = 'stack', this.issues = const []});
  final String fileId;
  final String file;
  final String? stack;
  final String source;
  final bool worldReadable;
  final List<Map<String, dynamic>> issues;
  List<FakeEntry> entries;
  int version = 1;
  final backups = <(String id, List<FakeEntry> entries)>[];
  String get hash => 'h$version';
}

String _mask(String v) => '••••${v.length}';

/// Mutable state of the fake config routes (tests reset it).
class FakeConfigState {
  FakeConfigState() {
    files = {
      'argo': [
        FakeConfigFile('cf-aaaaaaaaaaaaaaaaaaaaaaaa', 'shop/.env', 'shop', [
          FakeEntry('DB_HOST', 'db'),
          FakeEntry('DB_PORT', '5432'),
          FakeEntry('DB_PASSWORD', fakeSecretValue, secret: true, ageDays: 12, maxAgeDays: 90),
          FakeEntry('API_TOKEN', 'EXAMPLE-NOT-A-REAL-TOKEN-0002', secret: true, ageDays: 120, maxAgeDays: 90),
          FakeEntry('SESSION_SECRET', 'EXAMPLE-NOT-A-REAL-SESSION-0003', secret: true, ageDays: 40),
          FakeEntry('LOG_LEVEL', 'debug', duplicate: true),
          FakeEntry('LOG_LEVEL', 'info'),
          FakeEntry('APP_URL', 'https://shop.example.org'),
          FakeEntry('TZ', '', inherited: true),
        ]),
        FakeConfigFile('cf-bbbbbbbbbbbbbbbbbbbbbbbb', 'shop/api.env', 'shop', [FakeEntry('STRIPE_KEY', 'EXAMPLE-NOT-A-REAL-KEY-0004', secret: true, ageDays: 3), FakeEntry('WORKERS', '4')], worldReadable: true),
        FakeConfigFile('cf-cccccccccccccccccccccccc', 'notes/app.env', null, [FakeEntry('MODE', 'prod')], source: 'extra'),
      ],
      'atlas': [
        FakeConfigFile('cf-dddddddddddddddddddddddd', 'blog/.env', 'blog', [FakeEntry('WP_DB_PASSWORD', 'EXAMPLE-NOT-A-REAL-PASSWORD-0005', secret: true, ageDays: 5), FakeEntry('WP_DEBUG', 'false')]),
      ],
    };
  }

  /// Files per host id.
  late final Map<String, List<FakeConfigFile>> files;

  /// Skipped files (reason codes of the agent) of argo.
  final skipped = [
    {'fileId': 'cf-111111111111111111111111', 'file': 'shop/notes.txt', 'reason': 'badName'},
    {'fileId': 'cf-222222222222222222222222', 'file': 'shop/old.env', 'reason': 'notOwner'},
    {'fileId': 'cf-333333333333333333333333', 'file': 'archive/.env', 'reason': 'outsideRoot'},
  ];

  /// Services that use the changed keys (every preview answers it).
  List<Map<String, dynamic>> affected = [
    {'stack': 'shop', 'project': 'shop', 'services': ['web', 'worker']},
  ];

  /// Thrown by the next reveal / save call, if set.
  AgentError? revealError;
  AgentError? saveError;

  /// Key lists of the reveal calls and bodies of the meta updates, for tests.
  final revealCalls = <List<String>>[];
  final metaCalls = <Object?>[];

  /// The token the fake issued and the ops it carries (null = none / spent).
  String? issued;
  List<Map<String, dynamic>>? issuedOps;
  String? issuedBackup;
  String? issuedBase;
  int tokens = 0;
  Duration previewTtl = const Duration(seconds: 118);

  /// restart: "affected" bookkeeping: the choice the token was issued for, and whether the recreate fails.
  String issuedRestart = 'none';
  bool recreateFails = false;

  FakeConfigFile? find(String hostId, String id) => (files[hostId] ?? const []).where((f) => f.fileId == id).firstOrNull;
}

bool _looksSecret(String key) => RegExp(r'PASS|PWD|SECRET|TOKEN|KEY|PRIVATE|CREDENTIAL|DSN', caseSensitive: false).hasMatch(key);

/// The ops applied to entries (set changes the last occurrence or appends, unset removes all, rename moves).
List<FakeEntry> applyFakeOps(List<FakeEntry> before, List<Map<String, dynamic>> ops) {
  final out = [for (final e in before) e.copy()];
  for (final op in ops) {
    final key = op['key'] as String;
    switch (op['op']) {
      case 'set':
        final i = out.lastIndexWhere((e) => e.key == key);
        if (i >= 0) {
          out[i].value = op['value'] as String;
          out[i].inherited = false;
        } else {
          out.add(FakeEntry(key, op['value'] as String, secret: _looksSecret(key)));
        }
      case 'unset':
        if (!out.any((e) => e.key == key)) throw AgentError('agent.configfiles.keyNotFound', {'key': key}, 404);
        out.removeWhere((e) => e.key == key);
      case 'rename':
        final i = out.lastIndexWhere((e) => e.key == key);
        if (i < 0) throw AgentError('agent.configfiles.keyNotFound', {'key': key}, 404);
        if (out.any((e) => e.key == op['newKey'])) throw AgentError('agent.configfiles.keyExists', {'key': op['newKey']}, 409);
        out[i].key = op['newKey'] as String;
    }
  }
  return out;
}

Map<String, dynamic> _side(FakeEntry e) => {'length': e.value.length, if (!e.secret) 'value': e.value, if (e.inherited) 'inherited': true};

List<Map<String, dynamic>> fakeChanges(List<FakeEntry> before, List<FakeEntry> after, List<Map<String, dynamic>> ops) {
  final renames = {for (final op in ops) if (op['op'] == 'rename') op['newKey'] as String: op['key'] as String};
  Map<String, FakeEntry> eff(List<FakeEntry> l) => {for (final e in l) e.key: e};
  final a = eff(before), b = eff(after);
  final out = <Map<String, dynamic>>[];
  for (final MapEntry(key: k, value: n) in b.entries) {
    final from = renames[k];
    final o = a[from ?? k];
    if (o == null) {
      out.add({'key': k, 'change': 'added', 'secret': n.secret, 'after': _side(n)});
    } else if (from != null) {
      out.add({'key': k, 'change': 'renamed', 'from': from, 'secret': n.secret, 'before': _side(o), 'after': _side(n)});
    } else if (o.value != n.value) {
      out.add({'key': k, 'change': 'changed', 'secret': n.secret, 'before': _side(o), 'after': _side(n)});
    }
  }
  for (final MapEntry(key: k, value: o) in a.entries) {
    if (!b.containsKey(k) && !renames.containsValue(k)) out.add({'key': k, 'change': 'removed', 'secret': o.secret, 'before': _side(o)});
  }
  return out;
}

/// GET/POST/PUT /v1/config-files* and /v1/secrets/meta of the fake agent. Returns null when the path isn't one of them.
dynamic fakeConfigRoute(String hostId, String method, String path, Object? body, FakeConfigState st) {
  if (path == '/v1/secrets/meta') {
    if (method == 'PUT') {
      st.metaCalls.add(body);
      for (final u in (body as Map)['updates'] as List) {
        final f = st.find(hostId, u['fileId'] as String);
        final e = f?.entries.where((e) => e.key == u['key']).firstOrNull;
        if (e == null) throw AgentError('agent.configfiles.keyNotFound', {'key': u['key']}, 404);
        if (u.containsKey('secret')) {
          e.mark = u['secret'] as bool?;
          e.secret = e.mark ?? _looksSecret(e.key);
        }
        if (u.containsKey('maxAgeDays')) e.maxAgeDays = u['maxAgeDays'] as int?;
        e.ageDays ??= 0;
      }
    }
    return {'files': <Map<String, dynamic>>[]};
  }
  if (!path.startsWith('/v1/config-files')) return null;
  final list = st.files[hostId] ?? [];
  if (path == '/v1/config-files' && method == 'GET') {
    return {
      'files': [
        for (final f in list)
          {
            'fileId': f.fileId,
            'file': f.file,
            'source': f.source,
            'stack': f.stack,
            'size': 120 + f.entries.length * 30,
            'modifiedAt': _at(2),
            'keys': f.entries.where((e) => !e.duplicate).length,
            'secrets': f.entries.where((e) => e.secret).length,
            'worldReadable': f.worldReadable,
          }
      ],
      'skipped': hostId == 'argo' ? st.skipped : <Map<String, dynamic>>[],
    };
  }
  final m = RegExp(r'^/v1/config-files/(cf-[a-f0-9]{24})(?:/(\w+))?$').firstMatch(path);
  if (m == null) throw const AgentError('agent.route.notFound');
  final f = st.find(hostId, m.group(1)!);
  if (f == null) throw const AgentError('agent.configfiles.notFound', {}, 404);
  final op = m.group(2);
  Map<String, dynamic> detail() => {
        'fileId': f.fileId,
        'file': f.file,
        'source': f.source,
        'stack': f.stack,
        'hash': f.hash,
        'size': 120 + f.entries.length * 30,
        'modifiedAt': _at(2),
        'mode': f.worldReadable ? '0644' : '0600',
        'warnings': [if (f.worldReadable) 'worldReadable'],
        'entries': [
          for (var i = 0; i < f.entries.length; i++)
            {
              'key': f.entries[i].key,
              'line': i + 1,
              'secret': f.entries[i].secret,
              'reason': f.entries[i].secret ? (f.entries[i].mark == true ? 'mark' : 'name') : null,
              'masked': _mask(f.entries[i].value),
              'length': f.entries[i].value.length,
              if (!f.entries[i].secret) 'value': f.entries[i].value,
              'inherited': f.entries[i].inherited,
              'quote': '',
              'duplicate': f.entries[i].duplicate,
              if (f.entries[i].secret && f.entries[i].ageDays != null) 'ageDays': f.entries[i].ageDays,
              if (f.entries[i].secret && f.entries[i].ageDays != null) 'lastChangedAt': _at(f.entries[i].ageDays!),
              if (f.entries[i].maxAgeDays != null) 'maxAgeDays': f.entries[i].maxAgeDays,
              if (f.entries[i].secret && f.entries[i].maxAgeDays != null && f.entries[i].ageDays != null) 'due': f.entries[i].ageDays! >= f.entries[i].maxAgeDays!,
              if (f.entries[i].mark != null) 'mark': f.entries[i].mark,
            }
        ],
        'issues': f.issues,
      };
  if (op == null && method == 'GET') return detail();
  Map<String, dynamic> previewOf(List<FakeEntry> after, List<Map<String, dynamic>> ops, String restart) {
    if (restart == 'affected' && st.affected.isEmpty) throw const AgentError('agent.configfiles.nothingToRestart', {}, 409);
    st.issuedRestart = restart;
    st.issued = 'tpc_${++st.tokens}';
    st.issuedOps = ops;
    return {
      'fileId': f.fileId,
      'file': f.file,
      'baseHash': f.hash,
      'changes': fakeChanges(f.entries, after, ops),
      'otherLinesChanged': false,
      'affected': st.affected,
      'keys': [for (final c in fakeChanges(f.entries, after, ops)) c['key']],
      'restart': restart,
      if (restart == 'affected')
        'restartPlan': [
          for (final a in st.affected) {...a, 'argv': ['docker', 'compose', '-f', '/home/user/stack/${a['stack']}/compose.yaml', 'up', '-d', '--no-deps', ...(a['services'] as List).cast<String>()]},
        ],
      'previewToken': st.issued,
      'expiresAt': _clock.add(st.previewTtl).toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> commit(List<FakeEntry> after, String key) {
    final id = 'b${f.backups.length + 1}';
    f.backups.insert(0, (id, f.entries));
    f.entries = after;
    f.version++;
    final restart = st.issuedRestart;
    final services = [for (final a in st.affected) ...(a['services'] as List).cast<String>()];
    return {
      'fileId': f.fileId,
      'file': f.file,
      'hash': f.hash,
      'backupId': id,
      'warnings': [if (f.worldReadable) 'worldReadable'],
      'restart': restart == 'affected' ? (st.recreateFails ? 'failed' : 'ok') : 'none',
      'affected': st.affected,
      'keys': <String>[],
      if (restart == 'affected')
        'recreate': {
          'ok': !st.recreateFails,
          if (st.recreateFails) 'stage': 'postCheck',
          'stacks': [
            {'stack': 'shop', 'project': 'shop', 'services': services, 'ok': true, 'code': 0},
          ],
          'services': [
            for (final sv in services) {'stack': 'shop', 'service': sv, 'ok': !(st.recreateFails && sv == 'worker'), 'state': st.recreateFails && sv == 'worker' ? 'exited' : 'running/healthy'},
          ],
        },
      if (restart == 'affected' && st.recreateFails) 'restore': {'route': '/v1/config-files/${f.fileId}/restore', 'backupId': id},
    };
  }

  switch ((method, op)) {
    case ('POST', 'reveal'):
      if (st.revealError != null) throw st.revealError!;
      final keys = [for (final k in (body as Map)['keys'] as List) '$k'];
      st.revealCalls.add(keys);
      if (keys.isEmpty || keys.length > 10) throw const AgentError('agent.validation.invalid', {}, 400);
      return {
        'fileId': f.fileId,
        'file': f.file,
        'values': {for (final k in keys) if (f.entries.any((e) => e.key == k)) k: f.entries.lastWhere((e) => e.key == k).value},
        'missing': [for (final k in keys) if (!f.entries.any((e) => e.key == k)) k],
      };
    case ('POST', 'preview'):
      final b = body as Map;
      if (b['baseHash'] != f.hash) throw AgentError('agent.configfiles.conflict', {'hash': f.hash}, 409);
      final ops = [for (final o in b['ops'] as List) Map<String, dynamic>.from(o as Map)];
      st.issuedBase = f.hash;
      final after = applyFakeOps(f.entries, ops);
      if (fakeChanges(f.entries, after, ops).isEmpty) throw const AgentError('agent.configfiles.noChange', {}, 400);
      st.issuedBackup = null;
      return previewOf(after, ops, (b['restart'] as String?) ?? 'none');
    case ('PUT', null):
      final b = body as Map;
      if (b['confirm'] != true) throw const AgentError('agent.configfiles.confirmRequired', {}, 400);
      if (b['previewToken'] != st.issued || st.issued == null || st.issuedBackup != null) throw const AgentError('agent.preview.invalid', {}, 409);
      if ((b['restart'] ?? 'none') != st.issuedRestart) {
        st.issued = null;
        throw const AgentError('agent.preview.invalid', {}, 409);
      }
      st.issued = null;
      if (st.saveError != null) throw st.saveError!;
      if (st.issuedBase != f.hash) throw AgentError('agent.configfiles.conflict', {'hash': f.hash}, 409);
      return commit(applyFakeOps(f.entries, st.issuedOps!), '');
    case ('GET', 'backups'):
      return {
        'fileId': f.fileId,
        'file': f.file,
        'backups': [
          for (var i = 0; i < f.backups.length; i++) {'id': f.backups[i].$1, 'at': _clock.subtract(Duration(hours: 3 + i * 5)).toUtc().toIso8601String(), 'size': 300 + i},
          if (f.backups.isEmpty) ...[
            {'id': 'b-old2', 'at': _clock.subtract(const Duration(days: 3)).toUtc().toIso8601String(), 'size': 412},
            {'id': 'b-old1', 'at': _clock.subtract(const Duration(days: 9)).toUtc().toIso8601String(), 'size': 398},
          ],
        ],
      };
    case ('POST', 'restore'):
      final b = body as Map;
      final id = b['backupId'] as String;
      final backup = f.backups.where((x) => x.$1 == id).firstOrNull?.$2 ?? (id.startsWith('b-old') ? [FakeEntry('DB_HOST', 'db-old'), FakeEntry('DB_PORT', '5432')] : null);
      if (backup == null) throw const AgentError('agent.configfiles.backupNotFound', {}, 404);
      if (b['confirm'] == true) {
        if (b['previewToken'] != st.issued || st.issued == null) throw const AgentError('agent.preview.invalid', {}, 409);
        if ((b['restart'] ?? 'none') != st.issuedRestart) {
          st.issued = null;
          throw const AgentError('agent.preview.invalid', {}, 409);
        }
        st.issued = null;
        final r = commit([for (final e in backup) e.copy()], id);
        return {...r, 'restoredFrom': id};
      }
      st.issuedBackup = id;
      final p = previewOf(backup, const [], (b['restart'] as String?) ?? 'none');
      st.issuedBackup = id;
      return {...p, 'backupId': id};
  }
  throw const AgentError('agent.route.notFound');
}
