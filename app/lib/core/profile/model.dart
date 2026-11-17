// Dart model of the .tiphys.json profile. Single source of truth: agent/src/profile/schema.ts
// (JSON Schema: schema/tiphys.schema.json). Defaults match the schema exactly.
//
// Secrets are never held in the model; only "secret:<id>" references are.

typedef Json = Map<String, dynamic>;

/// 2: root-level `desktopRemotes` (11.1). Since the root has `additionalProperties: false`, an old version that knows
/// 1 would consider the new file "invalid"; with the version bump it says "newer schema". The 1 → 2 migration only
/// bumps the number.
const schemaVersion = 2;
const profileFormat = 'tiphys-profile';

final idPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');
final secretRefPattern = RegExp(r'^secret:[a-z0-9][a-z0-9-]{0,62}$');

String secretIdOf(String ref) => ref.substring('secret:'.length);
String refOf(String secretId) => 'secret:$secretId';

T _get<T>(Json j, String k, T def) => j.containsKey(k) && j[k] != null ? j[k] as T : def;
List<T> _list<T>(Json j, String k, T Function(dynamic) f) => ((j[k] as List?) ?? const []).map(f).toList();
Json? _obj(Json j, String k) => j[k] == null ? null : Map<String, dynamic>.from(j[k] as Map);
List<String> _strings(Json j, String k, [List<String> def = const []]) =>
    j[k] == null ? List.of(def) : (j[k] as List).map((e) => e as String).toList();

// ───────────────────────── App ─────────────────────────

enum ThemePref { system, light, dark }

enum LanguagePref { system, tr, en }

/// Default home screen cards; "Recent events" (events) and "Now playing" (nowPlaying) are optional,
/// enabled from Settings › Home screen.
const defaultHomeCards = ['infra', 'claude', 'system', 'grafana', 'dozzle', 'quickAccess'];
const allHomeCards = [...defaultHomeCards, 'events', 'nowPlaying'];
const allTabs = ['home', 'claude', 'terminal', 'files', 'system'];

/// Home screen layout: cards (default bento), shortcut grid, focus (large status card + shortcut list).
enum HomeLayout { cards, grid, focus }

/// Home screen shortcuts (Settings › Home screen › Shortcuts). The default set matches the rows of the old
/// "Quick access" card: in existing profiles the Cards layout looks exactly the same.
const defaultShortcuts = ['terminal', 'files', 'quickNote', 'homepage'];
const allShortcuts = [
  ...defaultShortcuts,
  'vault',
  'desktop',
  'liveScreen',
  'media',
  'openOnPc',
  'newClaude',
  'schedules',
  'events',
  'compose',
  'logs',
  'backups',
  'dozzle',
  'grafana',
  'sites',
  'wake',
];

class LockSettings {
  const LockSettings({this.biometric = true, this.pin = true, this.autoLockSeconds = 60});
  final bool biometric;
  final bool pin;
  final int autoLockSeconds;

  factory LockSettings.fromJson(Json j) => LockSettings(
        biometric: _get(j, 'biometric', true),
        pin: _get(j, 'pin', true),
        autoLockSeconds: _get(j, 'autoLockSeconds', 60),
      );
  Json toJson() => {'biometric': biometric, 'pin': pin, 'autoLockSeconds': autoLockSeconds};
  LockSettings copyWith({bool? biometric, bool? pin, int? autoLockSeconds}) => LockSettings(
        biometric: biometric ?? this.biometric,
        pin: pin ?? this.pin,
        autoLockSeconds: autoLockSeconds ?? this.autoLockSeconds,
      );
}

class AppSettings {
  const AppSettings({
    this.theme = ThemePref.system,
    this.language = LanguagePref.system,
    this.lock = const LockSettings(),
    this.cards = defaultHomeCards,
    this.tabs = allTabs,
    this.layout = HomeLayout.cards,
    this.shortcuts = defaultShortcuts,
  });
  final ThemePref theme;
  final LanguagePref language;
  final LockSettings lock;
  final List<String> cards;
  final List<String> tabs;
  final HomeLayout layout;

  /// Enabled shortcuts, in display order.
  final List<String> shortcuts;

  factory AppSettings.fromJson(Json j) {
    final home = _obj(j, 'home') ?? {};
    return AppSettings(
      theme: ThemePref.values.byName(_get(j, 'theme', 'system')),
      language: LanguagePref.values.byName(_get(j, 'language', 'system')),
      lock: LockSettings.fromJson(_obj(j, 'lock') ?? {}),
      cards: _strings(home, 'cards', defaultHomeCards),
      tabs: _strings(home, 'tabs', allTabs),
      layout: HomeLayout.values.byName(_get(home, 'layout', 'cards')),
      shortcuts: _strings(home, 'shortcuts', defaultShortcuts),
    );
  }
  Json toJson() => {
        'theme': theme.name,
        'language': language.name,
        'lock': lock.toJson(),
        'home': {'cards': cards, 'tabs': tabs, 'layout': layout.name, 'shortcuts': shortcuts},
      };
  AppSettings copyWith({
    ThemePref? theme,
    LanguagePref? language,
    LockSettings? lock,
    List<String>? cards,
    List<String>? tabs,
    HomeLayout? layout,
    List<String>? shortcuts,
  }) =>
      AppSettings(
        theme: theme ?? this.theme,
        language: language ?? this.language,
        lock: lock ?? this.lock,
        cards: cards ?? this.cards,
        tabs: tabs ?? this.tabs,
        layout: layout ?? this.layout,
        shortcuts: shortcuts ?? this.shortcuts,
      );
}

// ───────────────────────── Hosts ─────────────────────────

sealed class SshAuth {
  const SshAuth();
  String get ref;
  factory SshAuth.fromJson(Json j) => switch (j['type']) {
        'key' => SshKeyAuth(j['keyRef'] as String),
        'password' => SshPasswordAuth(j['passwordRef'] as String),
        _ => throw FormatException('ssh.auth.type: ${j['type']}'),
      };
  Json toJson();
}

class SshKeyAuth extends SshAuth {
  const SshKeyAuth(this.keyRef);
  final String keyRef;
  @override
  String get ref => keyRef;
  @override
  Json toJson() => {'type': 'key', 'keyRef': keyRef};
}

class SshPasswordAuth extends SshAuth {
  const SshPasswordAuth(this.passwordRef);
  final String passwordRef;
  @override
  String get ref => passwordRef;
  @override
  Json toJson() => {'type': 'password', 'passwordRef': passwordRef};
}

class SshConfig {
  const SshConfig({this.port = 22, required this.user, required this.auth, this.tmuxSession = 'tiphys'});
  final int port;
  final String user;
  final SshAuth auth;
  final String tmuxSession;

  factory SshConfig.fromJson(Json j) => SshConfig(
        port: _get(j, 'port', 22),
        user: j['user'] as String,
        auth: SshAuth.fromJson(Map<String, dynamic>.from(j['auth'] as Map)),
        tmuxSession: _get(j, 'tmuxSession', 'tiphys'),
      );
  Json toJson() => {'port': port, 'user': user, 'auth': auth.toJson(), 'tmuxSession': tmuxSession};
}

class AgentRef {
  const AgentRef({required this.url, required this.tokenRef});
  final String url;
  final String tokenRef;
  factory AgentRef.fromJson(Json j) => AgentRef(url: j['url'] as String, tokenRef: j['tokenRef'] as String);
  Json toJson() => {'url': url, 'tokenRef': tokenRef};
}

class WakeConfig {
  const WakeConfig({required this.mac, this.viaHostId});
  final String mac;

  /// null: the phone sends the packet itself if it is on the same local network.
  final String? viaHostId;
  factory WakeConfig.fromJson(Json j) => WakeConfig(mac: j['mac'] as String, viaHostId: j['viaHostId'] as String?);
  Json toJson() => {'mac': mac, 'viaHostId': viaHostId};
}

class Host {
  const Host({
    required this.id,
    required this.name,
    this.color = '#8F88EE',
    required this.address,
    this.ssh,
    this.agent,
    this.wake,
    this.tags = const [],
    this.composeRoots = const ['~/stack'],
  });
  final String id;
  final String name;
  final String color;
  final String address;
  final SshConfig? ssh;
  final AgentRef? agent;
  final WakeConfig? wake;
  final List<String> tags;

  /// Root folders searched for Compose stacks (over SSH; compose files in each root's subfolders).
  final List<String> composeRoots;

  factory Host.fromJson(Json j) => Host(
        id: j['id'] as String,
        name: j['name'] as String,
        color: _get(j, 'color', '#8F88EE'),
        address: j['address'] as String,
        ssh: _obj(j, 'ssh') == null ? null : SshConfig.fromJson(_obj(j, 'ssh')!),
        agent: _obj(j, 'agent') == null ? null : AgentRef.fromJson(_obj(j, 'agent')!),
        wake: _obj(j, 'wake') == null ? null : WakeConfig.fromJson(_obj(j, 'wake')!),
        tags: _strings(j, 'tags'),
        composeRoots: _strings(j, 'composeRoots', const ['~/stack']),
      );
  Json toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'address': address,
        'ssh': ssh?.toJson(),
        'agent': agent?.toJson(),
        'wake': wake?.toJson(),
        'tags': tags,
        'composeRoots': composeRoots,
      };
}

class KeyInfo {
  const KeyInfo({required this.id, required this.label, required this.type, required this.publicKey});
  final String id;
  final String label;
  final String type;
  final String publicKey;
  factory KeyInfo.fromJson(Json j) =>
      KeyInfo(id: j['id'] as String, label: j['label'] as String, type: j['type'] as String, publicKey: j['publicKey'] as String);
  Json toJson() => {'id': id, 'label': label, 'type': type, 'publicKey': publicKey};
}

// ───────────────────────── Claude ─────────────────────────

const claudeEfforts = ['low', 'medium', 'high', 'xhigh', 'max'];
const claudePermissionModes = ['default', 'acceptEdits', 'plan', 'bypassPermissions'];

class ClaudeProfile {
  const ClaudeProfile({required this.id, required this.name, required this.configDir});
  final String id;
  final String name;
  final String configDir;
  factory ClaudeProfile.fromJson(Json j) =>
      ClaudeProfile(id: j['id'] as String, name: j['name'] as String, configDir: j['configDir'] as String);
  Json toJson() => {'id': id, 'name': name, 'configDir': configDir};
}

class ClaudeSettings {
  const ClaudeSettings({
    this.agentHostId,
    this.model = 'claude-opus-5-5',
    this.effort = 'high',
    this.permissionMode = 'bypassPermissions',
    this.profileId = 'personal',
    this.profiles = const [],
    this.favoriteFolders = const [],
    this.pinnedCommands = const [],
    this.notifyDone = true,
    this.notifyWaiting = true,
    this.notifyError = true,
  });
  final String? agentHostId;
  final String model;
  final String effort;
  final String permissionMode;
  final String profileId;
  final List<ClaudeProfile> profiles;
  final List<String> favoriteFolders;
  final List<String> pinnedCommands;
  final bool notifyDone;
  final bool notifyWaiting;
  final bool notifyError;

  factory ClaudeSettings.fromJson(Json j) {
    final d = _obj(j, 'defaults') ?? {};
    final n = _obj(j, 'notify') ?? {};
    return ClaudeSettings(
      agentHostId: j['agentHostId'] as String?,
      model: _get(d, 'model', 'claude-opus-5-5'),
      effort: _get(d, 'effort', 'high'),
      permissionMode: _get(d, 'permissionMode', 'bypassPermissions'),
      profileId: _get(d, 'profileId', 'personal'),
      profiles: _list(j, 'profiles', (e) => ClaudeProfile.fromJson(Map<String, dynamic>.from(e as Map))),
      favoriteFolders: _strings(j, 'favoriteFolders'),
      pinnedCommands: _strings(j, 'pinnedCommands'),
      notifyDone: _get(n, 'done', true),
      notifyWaiting: _get(n, 'waiting', true),
      notifyError: _get(n, 'error', true),
    );
  }
  Json toJson() => {
        'agentHostId': agentHostId,
        'defaults': {'model': model, 'effort': effort, 'permissionMode': permissionMode, 'profileId': profileId},
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'favoriteFolders': favoriteFolders,
        'pinnedCommands': pinnedCommands,
        'notify': {'done': notifyDone, 'waiting': notifyWaiting, 'error': notifyError},
      };
  ClaudeSettings copyWith({
    String? Function()? agentHostId,
    String? model,
    String? effort,
    String? permissionMode,
    String? profileId,
    List<ClaudeProfile>? profiles,
    List<String>? favoriteFolders,
    List<String>? pinnedCommands,
    bool? notifyDone,
    bool? notifyWaiting,
    bool? notifyError,
  }) =>
      ClaudeSettings(
        agentHostId: agentHostId != null ? agentHostId() : this.agentHostId,
        model: model ?? this.model,
        effort: effort ?? this.effort,
        permissionMode: permissionMode ?? this.permissionMode,
        profileId: profileId ?? this.profileId,
        profiles: profiles ?? this.profiles,
        favoriteFolders: favoriteFolders ?? this.favoriteFolders,
        pinnedCommands: pinnedCommands ?? this.pinnedCommands,
        notifyDone: notifyDone ?? this.notifyDone,
        notifyWaiting: notifyWaiting ?? this.notifyWaiting,
        notifyError: notifyError ?? this.notifyError,
      );
}

// ───────────────────────── Integrations ─────────────────────────

class GrafanaConfig {
  const GrafanaConfig({
    required this.id,
    required this.name,
    required this.url,
    this.tokenRef,
    this.defaultDashboardUid,
    this.favorites = const [],
    this.refreshSeconds = 30,
    this.defaultRange = 'now-1h',
  });
  final String id;
  final String name;
  final String url;

  /// null: no authentication.
  final String? tokenRef;
  final String? defaultDashboardUid;
  final List<String> favorites;
  final int refreshSeconds;
  final String defaultRange;

  factory GrafanaConfig.fromJson(Json j) {
    final auth = _obj(j, 'auth') ?? {'type': 'none'};
    return GrafanaConfig(
      id: j['id'] as String,
      name: j['name'] as String,
      url: j['url'] as String,
      tokenRef: auth['type'] == 'token' ? auth['tokenRef'] as String : null,
      defaultDashboardUid: j['defaultDashboardUid'] as String?,
      favorites: _strings(j, 'favorites'),
      refreshSeconds: _get(j, 'refreshSeconds', 30),
      defaultRange: _get(j, 'defaultRange', 'now-1h'),
    );
  }
  Json toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'auth': tokenRef == null ? {'type': 'none'} : {'type': 'token', 'tokenRef': tokenRef},
        'defaultDashboardUid': defaultDashboardUid,
        'favorites': favorites,
        'refreshSeconds': refreshSeconds,
        'defaultRange': defaultRange,
      };
}

class DozzleConfig {
  const DozzleConfig({required this.id, required this.name, required this.url, this.username, this.passwordRef});
  final String id;
  final String name;
  final String url;
  final String? username;
  final String? passwordRef;

  factory DozzleConfig.fromJson(Json j) {
    final auth = _obj(j, 'auth') ?? {'type': 'none'};
    final basic = auth['type'] == 'basic';
    return DozzleConfig(
      id: j['id'] as String,
      name: j['name'] as String,
      url: j['url'] as String,
      username: basic ? auth['username'] as String : null,
      passwordRef: basic ? auth['passwordRef'] as String : null,
    );
  }
  Json toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'auth': passwordRef == null ? {'type': 'none'} : {'type': 'basic', 'username': username, 'passwordRef': passwordRef},
      };
}

class HomepageConfig {
  const HomepageConfig({required this.browserUrl, required this.hostId, required this.path, this.openInApp = false});
  final String browserUrl;
  final String hostId;
  final String path;
  final bool openInApp;
  factory HomepageConfig.fromJson(Json j) {
    final s = _obj(j, 'source')!;
    return HomepageConfig(
      browserUrl: j['browserUrl'] as String,
      hostId: s['hostId'] as String,
      path: s['path'] as String,
      openInApp: _get(j, 'openIn', 'external') == 'inApp',
    );
  }
  Json toJson() => {
        'browserUrl': browserUrl,
        'source': {'type': 'agentFile', 'hostId': hostId, 'path': path},
        'openIn': openInApp ? 'inApp' : 'external',
      };
}

class UptimeKumaConfig {
  const UptimeKumaConfig({
    required this.viaHostId,
    required this.url,
    this.intervalSeconds = 60,
    this.alertAfterSeconds = 120,
    this.certExpiryDays = 14,
    this.notifyOnRecovery = true,
  });
  final String viaHostId;
  final String url;
  final int intervalSeconds;
  final int alertAfterSeconds;
  final int certExpiryDays;
  final bool notifyOnRecovery;
  factory UptimeKumaConfig.fromJson(Json j) {
    final d = _obj(j, 'defaults') ?? {};
    return UptimeKumaConfig(
      viaHostId: j['viaHostId'] as String,
      url: j['url'] as String,
      intervalSeconds: _get(d, 'intervalSeconds', 60),
      alertAfterSeconds: _get(d, 'alertAfterSeconds', 120),
      certExpiryDays: _get(d, 'certExpiryDays', 14),
      notifyOnRecovery: _get(j, 'notifyOnRecovery', true),
    );
  }
  Json toJson() => {
        'viaHostId': viaHostId,
        'url': url,
        'defaults': {'intervalSeconds': intervalSeconds, 'alertAfterSeconds': alertAfterSeconds, 'certExpiryDays': certExpiryDays},
        'notifyOnRecovery': notifyOnRecovery,
      };
}

/// ntfy: notifications are received by the ntfy app on the phone (credentials live there). Only the server and
/// topics for the "open in ntfy" shortcuts are kept here. `tokenRef` in old files is read but ignored.
class NtfyConfig {
  const NtfyConfig({required this.url, this.topics = const []});
  final String url;
  final List<String> topics;
  factory NtfyConfig.fromJson(Json j) => NtfyConfig(url: j['url'] as String, topics: _strings(j, 'topics'));
  Json toJson() => {'url': url, 'topics': topics};
}

/// Speech-to-text preferences. Transcription is done via the agent on the PC (the Scriberr key is on the agent);
/// `url`/`apiKeyRef` in old files are read but ignored.
class ScriberrConfig {
  const ScriberrConfig({this.language = 'tr', this.model = 'small'});

  /// tr | en | auto
  final String language;

  /// small | large-v3
  final String model;
  factory ScriberrConfig.fromJson(Json j) => ScriberrConfig(language: _get(j, 'language', 'tr'), model: _get(j, 'model', 'small'));
  Json toJson() => {'language': language, 'model': model};
}

/// Quick note to Obsidian: the note is written by the Obsidian app on the phone via an `obsidian://new` link
/// (LiveSync end-to-end encryption is preserved; Tiphys doesn't write to the vault directly).
class ObsidianConfig {
  const ObsidianConfig({required this.vault, this.folder = 'Gelen kutusu', this.mode = 'newNote', this.dailyNotePath = 'Günlük/YYYY-MM-DD'});

  /// Vault name (or id) in Obsidian.
  final String vault;

  /// Folder for new notes (relative to the vault root; empty: root).
  final String folder;

  /// newNote | dailyNote (append to the daily note)
  final String mode;

  /// Daily note path; YYYY, MM, DD are replaced with the date.
  final String dailyNotePath;

  factory ObsidianConfig.fromJson(Json j) => ObsidianConfig(
        vault: j['vault'] as String,
        folder: _get(j, 'folder', 'Gelen kutusu'),
        mode: _get(j, 'mode', 'newNote'),
        dailyNotePath: _get(j, 'dailyNotePath', 'Günlük/YYYY-MM-DD'),
      );
  Json toJson() => {'vault': vault, 'folder': folder, 'mode': mode, 'dailyNotePath': dailyNotePath};
}

class Integrations {
  const Integrations({
    this.grafana = const [],
    this.dozzle = const [],
    this.homepage,
    this.uptimeKuma,
    this.ntfy,
    this.scriberr,
    this.obsidian,
  });
  final List<GrafanaConfig> grafana;
  final List<DozzleConfig> dozzle;
  final HomepageConfig? homepage;
  final UptimeKumaConfig? uptimeKuma;
  final NtfyConfig? ntfy;
  final ScriberrConfig? scriberr;
  final ObsidianConfig? obsidian;

  factory Integrations.fromJson(Json j) => Integrations(
        grafana: _list(j, 'grafana', (e) => GrafanaConfig.fromJson(Map<String, dynamic>.from(e as Map))),
        dozzle: _list(j, 'dozzle', (e) => DozzleConfig.fromJson(Map<String, dynamic>.from(e as Map))),
        homepage: _obj(j, 'homepage') == null ? null : HomepageConfig.fromJson(_obj(j, 'homepage')!),
        uptimeKuma: _obj(j, 'uptimeKuma') == null ? null : UptimeKumaConfig.fromJson(_obj(j, 'uptimeKuma')!),
        ntfy: _obj(j, 'ntfy') == null ? null : NtfyConfig.fromJson(_obj(j, 'ntfy')!),
        scriberr: _obj(j, 'scriberr') == null ? null : ScriberrConfig.fromJson(_obj(j, 'scriberr')!),
        obsidian: _obj(j, 'obsidian') == null ? null : ObsidianConfig.fromJson(_obj(j, 'obsidian')!),
      );
  Json toJson() => {
        'grafana': grafana.map((g) => g.toJson()).toList(),
        'dozzle': dozzle.map((d) => d.toJson()).toList(),
        'homepage': homepage?.toJson(),
        'uptimeKuma': uptimeKuma?.toJson(),
        'ntfy': ntfy?.toJson(),
        'scriberr': scriberr?.toJson(),
        'obsidian': obsidian?.toJson(),
      };
  Integrations copyWith({
    List<GrafanaConfig>? grafana,
    List<DozzleConfig>? dozzle,
    HomepageConfig? Function()? homepage,
    UptimeKumaConfig? Function()? uptimeKuma,
    NtfyConfig? Function()? ntfy,
    ScriberrConfig? Function()? scriberr,
    ObsidianConfig? Function()? obsidian,
  }) =>
      Integrations(
        grafana: grafana ?? this.grafana,
        dozzle: dozzle ?? this.dozzle,
        homepage: homepage != null ? homepage() : this.homepage,
        uptimeKuma: uptimeKuma != null ? uptimeKuma() : this.uptimeKuma,
        ntfy: ntfy != null ? ntfy() : this.ntfy,
        scriberr: scriberr != null ? scriberr() : this.scriberr,
        obsidian: obsidian != null ? obsidian() : this.obsidian,
      );
}

// ───────────────────────── Terminal, files, operations ─────────────────────────

const defaultExtraKeys = ['esc', 'tab', 'ctrl', 'alt', 'up', 'down', 'left', 'right', '|', '~', '/'];

class Snippet {
  const Snippet({required this.name, required this.command, this.hostId});
  final String name;
  final String command;
  final String? hostId;
  factory Snippet.fromJson(Json j) =>
      Snippet(name: j['name'] as String, command: j['command'] as String, hostId: j['hostId'] as String?);
  Json toJson() => {'name': name, 'command': command, 'hostId': hostId};
}

class TerminalSettings {
  const TerminalSettings({this.fontSize = 13, this.theme = 'tiphys', this.extraKeys = defaultExtraKeys, this.snippets = const []});
  final double fontSize;
  final String theme;
  final List<String> extraKeys;
  final List<Snippet> snippets;
  factory TerminalSettings.fromJson(Json j) => TerminalSettings(
        fontSize: (_get<num>(j, 'fontSize', 13)).toDouble(),
        theme: _get(j, 'theme', 'tiphys'),
        extraKeys: _strings(j, 'extraKeys', defaultExtraKeys),
        snippets: _list(j, 'snippets', (e) => Snippet.fromJson(Map<String, dynamic>.from(e as Map))),
      );
  Json toJson() => {
        'fontSize': fontSize == fontSize.roundToDouble() ? fontSize.round() : fontSize,
        'theme': theme,
        'extraKeys': extraKeys,
        'snippets': snippets.map((s) => s.toJson()).toList(),
      };
  TerminalSettings copyWith({double? fontSize, String? theme, List<String>? extraKeys, List<Snippet>? snippets}) => TerminalSettings(
        fontSize: fontSize ?? this.fontSize,
        theme: theme ?? this.theme,
        extraKeys: extraKeys ?? this.extraKeys,
        snippets: snippets ?? this.snippets,
      );
}

class Bookmark {
  const Bookmark({required this.hostId, required this.path});
  final String hostId;
  final String path;
  factory Bookmark.fromJson(Json j) => Bookmark(hostId: j['hostId'] as String, path: j['path'] as String);
  Json toJson() => {'hostId': hostId, 'path': path};
}

class FileSettings {
  const FileSettings({this.bookmarks = const [], this.showHidden = false});
  final List<Bookmark> bookmarks;
  final bool showHidden;
  factory FileSettings.fromJson(Json j) => FileSettings(
        bookmarks: _list(j, 'bookmarks', (e) => Bookmark.fromJson(Map<String, dynamic>.from(e as Map))),
        showHidden: _get(j, 'showHidden', false),
      );
  Json toJson() => {'bookmarks': bookmarks.map((b) => b.toJson()).toList(), 'showHidden': showHidden};
}

class QuickAction {
  const QuickAction({required this.id, required this.name, this.icon = 'zap', required this.hostId, required this.command, this.confirm = true});
  final String id;
  final String name;
  final String icon;
  final String hostId;
  final String command;
  final bool confirm;
  factory QuickAction.fromJson(Json j) => QuickAction(
        id: j['id'] as String,
        name: j['name'] as String,
        icon: _get(j, 'icon', 'zap'),
        hostId: j['hostId'] as String,
        command: j['command'] as String,
        confirm: _get(j, 'confirm', true),
      );
  Json toJson() => {'id': id, 'name': name, 'icon': icon, 'hostId': hostId, 'command': command, 'confirm': confirm};
}

class NotificationSettings {
  const NotificationSettings({
    this.longCommandSeconds = 60,
    this.serviceDown = true,
    this.diskFullPercent = 90,
    this.pcOffline = true,
    this.grafanaAlerts = true,
    this.siteDown = true,
    this.backupAlerts = true,
    this.clipboardFromPc = true,
    this.clipboardToPc = false,
    this.clipboardHostId,
    this.telegramSent = true,
    this.telegramAlerts = true,
    this.incidents = true,
  });
  final int longCommandSeconds;
  final bool serviceDown;
  final int diskFullPercent;
  final bool pcOffline;
  final bool grafanaAlerts;
  final bool siteDown;
  final bool backupAlerts;

  /// Silent "Copy" notification when the PC clipboard changes.
  final bool clipboardFromPc;

  /// When the app comes to the foreground, the phone clipboard is sent to the PC if it changed (off by default).
  final bool clipboardToPc;

  /// PC whose clipboard is synced; null: the Claude host or the first host with an agent ([clipboardHost]).
  final String? clipboardHostId;

  /// Telegram newsletters: "issue sent" (telegram.sent).
  final bool telegramSent;

  /// Telegram newsletters: approval requests, failures and "research PC unreachable".
  final bool telegramAlerts;

  /// Incident room: resolved / failed-action notices, site outages, unhealthy containers and restart loops.
  final bool incidents;
  factory NotificationSettings.fromJson(Json j) => NotificationSettings(
        longCommandSeconds: _get(j, 'longCommandSeconds', 60),
        serviceDown: _get(j, 'serviceDown', true),
        diskFullPercent: _get(j, 'diskFullPercent', 90),
        pcOffline: _get(j, 'pcOffline', true),
        grafanaAlerts: _get(j, 'grafanaAlerts', true),
        siteDown: _get(j, 'siteDown', true),
        backupAlerts: _get(j, 'backupAlerts', true),
        clipboardFromPc: _get(j, 'clipboardFromPc', true),
        clipboardToPc: _get(j, 'clipboardToPc', false),
        clipboardHostId: j['clipboardHostId'] as String?,
        telegramSent: _get(j, 'telegramSent', true),
        telegramAlerts: _get(j, 'telegramAlerts', true),
        incidents: _get(j, 'incidents', true),
      );
  Json toJson() => {
        'longCommandSeconds': longCommandSeconds,
        'serviceDown': serviceDown,
        'diskFullPercent': diskFullPercent,
        'pcOffline': pcOffline,
        'grafanaAlerts': grafanaAlerts,
        'siteDown': siteDown,
        'backupAlerts': backupAlerts,
        'clipboardFromPc': clipboardFromPc,
        'clipboardToPc': clipboardToPc,
        'clipboardHostId': clipboardHostId,
        'telegramSent': telegramSent,
        'telegramAlerts': telegramAlerts,
        'incidents': incidents,
      };
  NotificationSettings copyWith({
    int? longCommandSeconds,
    bool? serviceDown,
    int? diskFullPercent,
    bool? pcOffline,
    bool? grafanaAlerts,
    bool? siteDown,
    bool? backupAlerts,
    bool? clipboardFromPc,
    bool? clipboardToPc,
    String? Function()? clipboardHostId,
    bool? telegramSent,
    bool? telegramAlerts,
    bool? incidents,
  }) =>
      NotificationSettings(
        longCommandSeconds: longCommandSeconds ?? this.longCommandSeconds,
        serviceDown: serviceDown ?? this.serviceDown,
        diskFullPercent: diskFullPercent ?? this.diskFullPercent,
        pcOffline: pcOffline ?? this.pcOffline,
        grafanaAlerts: grafanaAlerts ?? this.grafanaAlerts,
        siteDown: siteDown ?? this.siteDown,
        backupAlerts: backupAlerts ?? this.backupAlerts,
        clipboardFromPc: clipboardFromPc ?? this.clipboardFromPc,
        clipboardToPc: clipboardToPc ?? this.clipboardToPc,
        clipboardHostId: clipboardHostId == null ? this.clipboardHostId : clipboardHostId(),
        telegramSent: telegramSent ?? this.telegramSent,
        telegramAlerts: telegramAlerts ?? this.telegramAlerts,
        incidents: incidents ?? this.incidents,
      );
}

// ───────────────────────── Live screen remotes (11.1) ─────────────────────────

/// Icon set for user remotes (`remoteIcon` in the schema).
const remoteIcons = ['zap', 'star', 'play', 'search', 'save', 'copy', 'refresh', 'close', 'plus', 'folder', 'terminal', 'globe'];

enum RemoteKind { combo, sequence, prompt, scroll }

/// Sequence step: a shortcut ("ctrl+l", "Enter") or text to type.
class RemoteStep {
  const RemoteStep.combo(String this.combo) : text = null;
  const RemoteStep.text(String this.text) : combo = null;
  final String? combo;
  final String? text;
  factory RemoteStep.fromJson(Json j) => j['combo'] != null ? RemoteStep.combo(j['combo'] as String) : RemoteStep.text(j['text'] as String);
  Json toJson() => combo != null ? {'combo': combo} : {'text': text};
}

/// Remote action: shortcut, sequence, ask for text (first an optional shortcut, then the text, Enter if [submit]),
/// wheel.
class RemoteAction {
  const RemoteAction.combo(String this.combo)
      : kind = RemoteKind.combo,
        steps = const [],
        submit = true,
        dy = 0;
  const RemoteAction.sequence(this.steps)
      : kind = RemoteKind.sequence,
        combo = null,
        submit = true,
        dy = 0;
  const RemoteAction.prompt({this.combo, this.submit = true})
      : kind = RemoteKind.prompt,
        steps = const [],
        dy = 0;
  const RemoteAction.scroll(this.dy)
      : kind = RemoteKind.scroll,
        combo = null,
        steps = const [],
        submit = true;
  final RemoteKind kind;
  final String? combo;
  final List<RemoteStep> steps;
  final bool submit;

  /// Wheel notches; > 0 is down.
  final int dy;

  factory RemoteAction.fromJson(Json j) => switch (j['kind']) {
        'sequence' => RemoteAction.sequence(_list(j, 'steps', (e) => RemoteStep.fromJson(Map<String, dynamic>.from(e as Map)))),
        'prompt' => RemoteAction.prompt(combo: j['combo'] as String?, submit: _get(j, 'submit', true)),
        'scroll' => RemoteAction.scroll((j['dy'] as num).toInt()),
        _ => RemoteAction.combo(j['combo'] as String),
      };
  Json toJson() => switch (kind) {
        RemoteKind.combo => {'kind': 'combo', 'combo': combo},
        RemoteKind.sequence => {'kind': 'sequence', 'steps': steps.map((s) => s.toJson()).toList()},
        RemoteKind.prompt => {'kind': 'prompt', 'combo': ?combo, 'submit': submit},
        RemoteKind.scroll => {'kind': 'scroll', 'dy': dy},
      };
}

/// A button the user added for a window class (Settings › Desktop › Remotes).
class DesktopRemote {
  const DesktopRemote({required this.id, required this.windowClass, required this.name, this.icon = 'zap', required this.action, this.confirm = false});
  final String id;
  final String windowClass;
  final String name;
  final String icon;
  final RemoteAction action;
  final bool confirm;
  factory DesktopRemote.fromJson(Json j) => DesktopRemote(
        id: j['id'] as String,
        windowClass: j['windowClass'] as String,
        name: j['name'] as String,
        icon: _get(j, 'icon', 'zap'),
        action: RemoteAction.fromJson(Map<String, dynamic>.from(j['action'] as Map)),
        confirm: _get(j, 'confirm', false),
      );
  Json toJson() => {'id': id, 'windowClass': windowClass, 'name': name, 'icon': icon, 'action': action.toJson(), 'confirm': confirm};
}

// ───────────────────────── Profile ─────────────────────────

class Profile {
  const Profile({
    this.app = const AppSettings(),
    this.hosts = const [],
    this.keys = const [],
    this.claude = const ClaudeSettings(),
    this.integrations = const Integrations(),
    this.terminal = const TerminalSettings(),
    this.files = const FileSettings(),
    this.quickActions = const [],
    this.desktopRemotes = const [],
    this.notifications = const NotificationSettings(),
    this.agentConfigs = const {},
  });

  final AppSettings app;
  final List<Host> hosts;
  final List<KeyInfo> keys;
  final ClaudeSettings claude;
  final Integrations integrations;
  final TerminalSettings terminal;
  final FileSettings files;
  final List<QuickAction> quickActions;
  final List<DesktopRemote> desktopRemotes;
  final NotificationSettings notifications;
  final Map<String, Json> agentConfigs;

  static const empty = Profile();

  Host? host(String? id) => id == null ? null : hosts.where((h) => h.id == id).firstOrNull;

  /// JSON for the full profile (missing sections filled with defaults).
  factory Profile.fromJson(Json j) => Profile(
        app: AppSettings.fromJson(_obj(j, 'app') ?? {}),
        hosts: _list(j, 'hosts', (e) => Host.fromJson(Map<String, dynamic>.from(e as Map))),
        keys: _list(j, 'keys', (e) => KeyInfo.fromJson(Map<String, dynamic>.from(e as Map))),
        claude: ClaudeSettings.fromJson(_obj(j, 'claude') ?? {}),
        integrations: Integrations.fromJson(_obj(j, 'integrations') ?? {}),
        terminal: TerminalSettings.fromJson(_obj(j, 'terminal') ?? {}),
        files: FileSettings.fromJson(_obj(j, 'files') ?? {}),
        quickActions: _list(j, 'quickActions', (e) => QuickAction.fromJson(Map<String, dynamic>.from(e as Map))),
        desktopRemotes: _list(j, 'desktopRemotes', (e) => DesktopRemote.fromJson(Map<String, dynamic>.from(e as Map))),
        notifications: NotificationSettings.fromJson(_obj(j, 'notifications') ?? {}),
        agentConfigs: ((j['agentConfigs'] as Map?) ?? {})
            .map((k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map))),
      );

  Json toJson() => {
        'format': profileFormat,
        'schemaVersion': schemaVersion,
        'app': app.toJson(),
        'hosts': hosts.map((h) => h.toJson()).toList(),
        'keys': keys.map((k) => k.toJson()).toList(),
        'claude': claude.toJson(),
        'integrations': integrations.toJson(),
        'terminal': terminal.toJson(),
        'files': files.toJson(),
        'quickActions': quickActions.map((q) => q.toJson()).toList(),
        'desktopRemotes': desktopRemotes.map((r) => r.toJson()).toList(),
        'notifications': notifications.toJson(),
        'agentConfigs': agentConfigs,
      };

  Profile copyWith({
    AppSettings? app,
    List<Host>? hosts,
    List<KeyInfo>? keys,
    ClaudeSettings? claude,
    Integrations? integrations,
    TerminalSettings? terminal,
    FileSettings? files,
    List<QuickAction>? quickActions,
    List<DesktopRemote>? desktopRemotes,
    NotificationSettings? notifications,
    Map<String, Json>? agentConfigs,
  }) =>
      Profile(
        app: app ?? this.app,
        hosts: hosts ?? this.hosts,
        keys: keys ?? this.keys,
        claude: claude ?? this.claude,
        integrations: integrations ?? this.integrations,
        terminal: terminal ?? this.terminal,
        files: files ?? this.files,
        quickActions: quickActions ?? this.quickActions,
        desktopRemotes: desktopRemotes ?? this.desktopRemotes,
        notifications: notifications ?? this.notifications,
        agentConfigs: agentConfigs ?? this.agentConfigs,
      );

  /// All secret ids the profile references.
  Set<String> get secretIds {
    final refs = <String>{};
    for (final h in hosts) {
      if (h.ssh != null) refs.add(h.ssh!.auth.ref);
      if (h.agent != null) refs.add(h.agent!.tokenRef);
    }
    for (final g in integrations.grafana) {
      if (g.tokenRef != null) refs.add(g.tokenRef!);
    }
    for (final d in integrations.dozzle) {
      if (d.passwordRef != null) refs.add(d.passwordRef!);
    }
    return refs.map(secretIdOf).toSet();
  }
}

/// Add or replace by id within a list (order is preserved).
List<T> upsertBy<T>(List<T> list, T item, String Function(T) id) {
  final i = list.indexWhere((e) => id(e) == id(item));
  if (i < 0) return [...list, item];
  return [...list]..[i] = item;
}
