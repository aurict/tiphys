// İçe aktarma: değişiklik önizlemesi ve birleştir / tamamen değiştir.
import 'dart:convert';

import 'codec.dart';
import 'model.dart';

enum ChangeKind { added, changed, removed }

class Change {
  const Change(this.section, this.kind, [this.id]);

  /// ör. "hosts", "integrations.grafana", "app"
  final String section;
  final ChangeKind kind;

  /// Liste öğeleri için kimlik; tekil bölümler için null.
  final String? id;

  @override
  bool operator ==(Object other) => other is Change && other.section == section && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(section, kind, id);
  @override
  String toString() => '$kind $section${id == null ? '' : '/$id'}';
}

enum ImportMode { merge, replace }

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

/// Kimlikli listeler: (bölüm adı, profilden okuma, profile yazma, öğe kimliği, JSON'a çevirme)
class _ListSection<T> {
  const _ListSection(this.name, this.read, this.write, this.idOf, this.toJson);
  final String name;
  final List<T> Function(Profile) read;
  final Profile Function(Profile, List<T>) write;
  final String Function(T) idOf;
  final Json Function(T) toJson;

  List<Change> diff(Profile cur, Profile inc, ImportMode mode) {
    final a = {for (final e in read(cur)) idOf(e): toJson(e)};
    final b = {for (final e in read(inc)) idOf(e): toJson(e)};
    return [
      for (final id in b.keys)
        if (!a.containsKey(id)) Change(name, ChangeKind.added, id) else if (!_same(a[id], b[id])) Change(name, ChangeKind.changed, id),
      if (mode == ImportMode.replace)
        for (final id in a.keys)
          if (!b.containsKey(id)) Change(name, ChangeKind.removed, id),
    ];
  }

  Profile merge(Profile cur, Profile inc) {
    var list = read(cur);
    for (final e in read(inc)) {
      list = upsertBy(list, e, idOf);
    }
    return write(cur, list);
  }
}

class _ObjSection {
  const _ObjSection(this.name, this.fileKey, this.read, this.write);
  final String name;

  /// Bu bölümün dosyada var olup olmadığını anlamak için JSON yolu.
  final List<String> fileKey;
  final Object? Function(Profile) read;
  final Profile Function(Profile cur, Profile inc) write;
}

final _lists = <_ListSection>[
  _ListSection<Host>('hosts', (p) => p.hosts, (p, l) => p.copyWith(hosts: l), (e) => e.id, (e) => e.toJson()),
  _ListSection<KeyInfo>('keys', (p) => p.keys, (p, l) => p.copyWith(keys: l), (e) => e.id, (e) => e.toJson()),
  _ListSection<QuickAction>('quickActions', (p) => p.quickActions, (p, l) => p.copyWith(quickActions: l), (e) => e.id, (e) => e.toJson()),
  _ListSection<GrafanaConfig>('integrations.grafana', (p) => p.integrations.grafana,
      (p, l) => p.copyWith(integrations: p.integrations.copyWith(grafana: l)), (e) => e.id, (e) => e.toJson()),
  _ListSection<DozzleConfig>('integrations.dozzle', (p) => p.integrations.dozzle,
      (p, l) => p.copyWith(integrations: p.integrations.copyWith(dozzle: l)), (e) => e.id, (e) => e.toJson()),
];

final _objects = <_ObjSection>[
  _ObjSection('app', ['app'], (p) => p.app.toJson(), (c, i) => c.copyWith(app: i.app)),
  _ObjSection('claude', ['claude'], (p) => p.claude.toJson(), (c, i) => c.copyWith(claude: i.claude)),
  _ObjSection('terminal', ['terminal'], (p) => p.terminal.toJson(), (c, i) => c.copyWith(terminal: i.terminal)),
  _ObjSection('files', ['files'], (p) => p.files.toJson(), (c, i) => c.copyWith(files: i.files)),
  _ObjSection('notifications', ['notifications'], (p) => p.notifications.toJson(), (c, i) => c.copyWith(notifications: i.notifications)),
  _ObjSection('integrations.homepage', ['integrations', 'homepage'], (p) => p.integrations.homepage?.toJson(),
      (c, i) => c.copyWith(integrations: c.integrations.copyWith(homepage: () => i.integrations.homepage))),
  _ObjSection('integrations.uptimeKuma', ['integrations', 'uptimeKuma'], (p) => p.integrations.uptimeKuma?.toJson(),
      (c, i) => c.copyWith(integrations: c.integrations.copyWith(uptimeKuma: () => i.integrations.uptimeKuma))),
  _ObjSection('integrations.ntfy', ['integrations', 'ntfy'], (p) => p.integrations.ntfy?.toJson(),
      (c, i) => c.copyWith(integrations: c.integrations.copyWith(ntfy: () => i.integrations.ntfy))),
  _ObjSection('integrations.scriberr', ['integrations', 'scriberr'], (p) => p.integrations.scriberr?.toJson(),
      (c, i) => c.copyWith(integrations: c.integrations.copyWith(scriberr: () => i.integrations.scriberr))),
];

bool _fileHas(Json json, List<String> path) {
  Object? cur = json;
  for (final k in path) {
    if (cur is! Map || !cur.containsKey(k)) return false;
    cur = cur[k];
  }
  return true;
}

class ImportPlan {
  ImportPlan(this.current, this.file, this.mode);
  final Profile current;
  final ProfileFile file;
  final ImportMode mode;

  late final Profile result = _apply();
  late final List<Change> changes = _diff();

  Profile _apply() {
    final inc = file.toProfile();
    if (mode == ImportMode.replace) return inc;
    var out = current;
    for (final s in _lists) {
      final path = s.name.split('.');
      if (_fileHas(file.json, path)) out = s.merge(out, inc);
    }
    for (final s in _objects) {
      if (_fileHas(file.json, s.fileKey)) out = s.write(out, inc);
    }
    if (file.has('agentConfigs')) {
      out = out.copyWith(agentConfigs: {...out.agentConfigs, ...inc.agentConfigs});
    }
    return out;
  }

  List<Change> _diff() {
    final out = <Change>[];
    final inc = file.toProfile();
    for (final s in _lists) {
      final inFile = _fileHas(file.json, s.name.split('.'));
      if (inFile || mode == ImportMode.replace) out.addAll(s.diff(current, inc, mode));
    }
    for (final s in _objects) {
      final inFile = _fileHas(file.json, s.fileKey);
      if (!inFile && mode == ImportMode.merge) continue;
      final a = s.read(current);
      final b = s.read(mode == ImportMode.replace ? inc : result);
      if (_same(a, b)) continue;
      out.add(Change(s.name, a == null ? ChangeKind.added : (b == null ? ChangeKind.removed : ChangeKind.changed)));
    }
    final agentKeys = {...current.agentConfigs.keys, ...result.agentConfigs.keys};
    for (final k in agentKeys) {
      final a = current.agentConfigs[k];
      final b = result.agentConfigs[k];
      if (_same(a, b)) continue;
      out.add(Change('agentConfigs', a == null ? ChangeKind.added : (b == null ? ChangeKind.removed : ChangeKind.changed), k));
    }
    return out;
  }

  /// Sonuç profilin ihtiyaç duyup elde olmayan gizli bilgileri.
  Set<String> missingSecrets(Set<String> available) => result.secretIds.difference(available);
}
