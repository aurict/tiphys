// "Send to Claude" (PLAN.md §16 F4): the items picked on the security screens, the brief the monitoring agent turns them
// into, the fix targets of the PC agent, and the session request. The brief is data from audited machines: it is shown
// as plain text and handed to the session as-is, never interpreted by the app.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../system/agent_providers.dart';
import 'security_fix_sheet.dart' show sendToClaude;

// ---------------------------------------------------------------------------------------------------------------------
// Items

/// One selected thing. [label] is only for the app's own lists; [toJson] is the brief request's item.
class FixItem {
  const FixItem._(this.type, this.label, {this.host, this.id, this.image, this.cve});

  /// Rule finding of an audited host.
  factory FixItem.finding({required String host, required String id, required String label}) => FixItem._('finding', label, host: host, id: id);

  /// Baseline change; the agent's id is `category|item`.
  factory FixItem.change({required String host, required String category, required String item, required String label}) => FixItem._('change', label, host: host, id: '$category|$item');

  /// One CVE of an image (the image id is the hex digest the screens carry).
  factory FixItem.vuln({required String hex, required String cve, required String label}) => FixItem._('vuln', label, image: 'sha256:$hex', cve: cve);
  factory FixItem.secret({required String id, required String label}) => FixItem._('secret', label, id: id);
  factory FixItem.exposure({required String id, required String label}) => FixItem._('exposure', label, id: id);

  /// finding | change | vuln | secret | exposure
  final String type;
  final String label;
  final String? host, id, image, cve;

  Map<String, dynamic> toJson() => {'type': type, 'host': ?host, 'id': ?id, 'image': ?image, 'cve': ?cve};

  /// Identity of the item (selection set).
  String get key => jsonEncode(toJson());

  @override
  bool operator ==(Object other) => other is FixItem && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The agent takes 1…30 items per brief.
const fixMaxItems = 30;

/// Body of `POST /v1/security/brief`. [language] is `tr` or `en` (the brief's text language).
Map<String, dynamic> fixBriefRequest(List<FixItem> items, String language) => {
      'items': [for (final i in items.take(fixMaxItems)) i.toJson()],
      'language': language == 'tr' ? 'tr' : 'en',
    };

/// The brief's language follows the app's.
String fixLanguage(BuildContext context) => Localizations.localeOf(context).languageCode == 'tr' ? 'tr' : 'en';

// ---------------------------------------------------------------------------------------------------------------------
// The brief

class FixBriefItem {
  FixBriefItem(Map<String, dynamic> j)
      : ref = '${j['ref']}',
        type = '${j['type']}',
        host = j['host'] as String?,
        mode = j['mode'] as String?,
        error = j['error'] as String?;
  final String ref, type;
  final String? host;

  /// fix | investigate (null when [error] is set)
  final String? mode;

  /// Per-item error code (`agent.security.hostNotFound`, `…itemNotFound`, `…briefTruncated`).
  final String? error;
  bool get ok => error == null;
}

class FixBriefHost {
  FixBriefHost(Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        role = '${j['role']}',
        root = j['root'] as bool?,
        source = '${j['source']}';
  final String id, name, role, source;

  /// Whether the last report ran as root; null: no report yet.
  final bool? root;
}

class FixBrief {
  FixBrief(Map<String, dynamic> j)
      : text = '${j['text'] ?? ''}',
        bytes = (j['bytes'] as num?)?.toInt() ?? 0,
        truncated = j['truncated'] == true,
        investigate = j['investigate'] == true,
        hosts = [for (final h in (j['hosts'] as List? ?? const [])) FixBriefHost(Map<String, dynamic>.from(h as Map))],
        items = [for (final i in (j['items'] as List? ?? const [])) FixBriefItem(Map<String, dynamic>.from(i as Map))];
  final String text;
  final int bytes;
  final bool truncated, investigate;
  final List<FixBriefHost> hosts;
  final List<FixBriefItem> items;

  /// References of the items the brief covers (kept with the session so the audit can be re-run).
  List<String> get refs => [for (final i in items) if (i.ok) i.ref];
  bool get hasItems => items.any((i) => i.ok);
}

/// The brief of [items] from the monitoring agent [agentId].
Future<FixBrief> fetchFixBrief(WidgetRef ref, String agentId, List<FixItem> items, String language) async {
  final j = await agentCall(ref, agentId, 'POST', '/v1/security/brief', fixBriefRequest(items, language));
  return FixBrief(Map<String, dynamic>.from(j as Map));
}

// ---------------------------------------------------------------------------------------------------------------------
// Session request

const fixModes = ['plan', 'default', 'acceptEdits', 'bypassPermissions'];

/// An investigation (possible attack traces) is read-only: the session opens in plan mode and stays there.
List<String> fixAllowedModes({required bool investigate}) => investigate ? const ['plan'] : fixModes;

String fixDefaultMode({required bool investigate}) => investigate ? 'plan' : 'default';

/// `origin` of the session: where the audit runs again. The agent stores at most 4 KB of it.
Map<String, dynamic> fixOrigin(String agentHostId, List<String> refs) {
  final keep = [...refs];
  Map<String, dynamic> origin() => {'agentHostId': agentHostId, 'refs': keep};
  while (keep.isNotEmpty && utf8.encode(jsonEncode(origin())).length > 3800) {
    keep.removeLast();
  }
  return origin();
}

/// Body of `POST /v1/claude/sessions` for a security session. [note] is the user's own (trusted) instruction.
Map<String, dynamic> fixSessionBody({
  required FixBrief brief,
  required String agentHostId,
  required String mode,
  String note = '',
  String effort = '',
  String model = '',
}) =>
    {
      'cwd': '~',
      'kind': 'security',
      'prompt': note.trim(),
      'permissionMode': fixAllowedModes(investigate: brief.investigate).contains(mode) ? mode : fixDefaultMode(investigate: brief.investigate),
      if (effort.isNotEmpty) 'effort': effort,
      if (model.isNotEmpty) 'model': model,
      'security': {
        'brief': brief.text,
        'hosts': [for (final h in brief.hosts) h.id],
        'investigate': brief.investigate,
        'origin': fixOrigin(agentHostId, brief.refs),
      },
    };

// ---------------------------------------------------------------------------------------------------------------------
// Fix targets (GET|PUT /v1/claude/security/targets on the PC agent)

final fixHostRe = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');
final fixSshRe = RegExp(r'^(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}@)?[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}$');
const fixMaxTargets = 20;

class FixTarget {
  const FixTarget({required this.host, required this.name, this.ssh, this.port});
  FixTarget.fromJson(Map<String, dynamic> j)
      : host = '${j['host']}',
        name = '${j['name']}',
        ssh = j['ssh'] as String?,
        port = (j['port'] as num?)?.toInt();

  /// Security host id on the monitoring agent.
  final String host, name;

  /// `user@host`; null = this PC.
  final String? ssh;
  final int? port;

  Map<String, dynamic> toJson() => {'host': host, 'name': name, 'ssh': ssh, 'port': ?port};

  /// "user@host:2222" / null for this PC.
  String? get destination => ssh == null ? null : (port == null ? ssh : '$ssh:$port');
}

class FixTargets {
  const FixTargets({required this.targets, this.sudoCacheMinutes = 15});
  FixTargets.fromJson(Map<String, dynamic> j)
      : targets = [for (final t in (j['targets'] as List? ?? const [])) FixTarget.fromJson(Map<String, dynamic>.from(t as Map))],
        sudoCacheMinutes = (j['sudoCacheMinutes'] as num?)?.toInt() ?? 15;
  final List<FixTarget> targets;
  final int sudoCacheMinutes;

  FixTarget? of(String host) => targets.where((t) => t.host == host).firstOrNull;

  Map<String, dynamic> toJson() => {'targets': [for (final t in targets) t.toJson()], 'sudoCacheMinutes': sudoCacheMinutes};
}

enum FixTargetProblem { host, name, ssh, port, duplicate, tooMany, cache }

bool validFixHost(String v) => fixHostRe.hasMatch(v);

/// `user@host` or `host` (null/empty is "this PC" and valid elsewhere).
bool validFixSsh(String v) => fixSshRe.hasMatch(v);
bool validFixPort(int v) => v >= 1 && v <= 65535;

/// The first problem of [t] as the agent would see it; null when it would be accepted.
FixTargetProblem? fixTargetsProblem(FixTargets t) {
  if (t.targets.length > fixMaxTargets) return FixTargetProblem.tooMany;
  if (t.sudoCacheMinutes < 1 || t.sudoCacheMinutes > 120) return FixTargetProblem.cache;
  final seen = <String>{};
  for (final x in t.targets) {
    if (!validFixHost(x.host)) return FixTargetProblem.host;
    if (x.name.trim().isEmpty) return FixTargetProblem.name;
    if (!seen.add(x.host)) return FixTargetProblem.duplicate;
    if (x.ssh != null && !validFixSsh(x.ssh!)) return FixTargetProblem.ssh;
    if (x.port != null && (x.ssh == null || !validFixPort(x.port!))) return FixTargetProblem.port;
  }
  return null;
}

String fixTargetProblemText(AppLocalizations l, FixTargetProblem p) => switch (p) {
      FixTargetProblem.host => l.fixTargetHostInvalid,
      FixTargetProblem.name => l.commonRequired,
      FixTargetProblem.ssh => l.fixTargetSshInvalid,
      FixTargetProblem.port => l.fixTargetPortInvalid,
      FixTargetProblem.duplicate => l.fixTargetDuplicate,
      FixTargetProblem.tooMany => l.fixTargetTooMany(fixMaxTargets),
      FixTargetProblem.cache => l.fixTargetCacheInvalid,
    };

/// Targets of the PC agent [hostId]; `agent.claude.securityFixDisabled` (403) while the feature is off.
final fixTargetsProvider = FutureProvider.autoDispose.family<FixTargets, String>((ref, hostId) async {
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/claude/security/targets')).timeout(const Duration(seconds: 20));
  return FixTargets.fromJson(j);
});

// ---------------------------------------------------------------------------------------------------------------------
// Multi-select on the security screens

/// Which items are ticked and whether a screen is in selection mode. The screens own one and rebuild on changes.
class FixSelection extends ChangeNotifier {
  final _items = <FixItem, FixItem>{};
  bool _selecting = false;

  /// Screens that list several monitoring agents' items: the agent the selection belongs to (null = any) and everything
  /// it offers for "select all". Set when selection mode starts.
  String? agentId;
  List<FixItem> offered = const [];

  /// Starts selection mode for [agent]'s [all] items.
  void begin(String agent, List<FixItem> all) {
    agentId = agent;
    offered = all;
    if (!_selecting) toggleMode();
  }

  bool get selecting => _selecting;
  int get count => _items.length;
  List<FixItem> get items => _items.values.toList();
  bool has(FixItem i) => _items.containsKey(i);

  void toggleMode() {
    _selecting = !_selecting;
    if (!_selecting) {
      _items.clear();
      agentId = null;
    }
    notifyListeners();
  }

  void toggle(FixItem i) {
    if (_items.remove(i) == null) _items[i] = i;
    notifyListeners();
  }

  void selectAll(Iterable<FixItem> all) {
    _items
      ..clear()
      ..addEntries([for (final i in all) MapEntry(i, i)]);
    notifyListeners();
  }

  /// Leaves selection mode after the items were handed over.
  void done() {
    _selecting = false;
    _items.clear();
    agentId = null;
    notifyListeners();
  }
}

/// A selectable row: in selection mode a checkbox leads it and a tap ticks it; otherwise it is [child] as it is.
class FixPick extends StatelessWidget {
  const FixPick({super.key, required this.selection, required this.item, required this.child, this.agentId});
  final FixSelection selection;
  final FixItem item;
  final Widget child;

  /// The monitoring agent the row belongs to; rows of other agents stay plain while a selection is open.
  final String? agentId;

  @override
  Widget build(BuildContext context) {
    if (!selection.selecting || (agentId != null && selection.agentId != null && selection.agentId != agentId)) return child;
    final on = selection.has(item);
    return Semantics(
      checked: on,
      label: item.label,
      excludeSemantics: true,
      onTap: () => selection.toggle(item),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => selection.toggle(item),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ExcludeFocus(child: Checkbox(value: on, onChanged: (_) => selection.toggle(item), visualDensity: VisualDensity.compact)),
          Expanded(child: IgnorePointer(child: child)),
        ]),
      ),
    );
  }
}

/// App bar button that enters and leaves selection mode.
class FixSelectButton extends StatelessWidget {
  const FixSelectButton({super.key, required this.selection});
  final FixSelection selection;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return IconButton(
      tooltip: selection.selecting ? l.fixSelectCancel : l.fixSelect,
      icon: Icon(selection.selecting ? LucideIcons.x : LucideIcons.listChecks),
      onPressed: selection.toggleMode,
    );
  }
}

/// Pinned bar of the selection mode: count, "select all", "Send to Claude".
class FixBar extends StatelessWidget {
  const FixBar({super.key, required this.selection, required this.all, required this.onSend});
  final FixSelection selection;

  /// Everything the screen offers (for "select all").
  final List<FixItem> all;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final n = selection.count;
    final tooMany = n > fixMaxItems;
    return Material(
      color: t.isDark ? const Color(0xFF1C1C1E) : t.background,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(tooMany ? l.fixSelectedTooMany(n, fixMaxItems) : l.fixSelectedCount(n), style: Theme.of(context).textTheme.titleSmall?.copyWith(color: tooMany ? t.warning : null)),
              ),
            ),
            TextButton(onPressed: all.isEmpty ? null : () => selection.selectAll(all.take(fixMaxItems)), child: Text(l.fixSelectAll)),
            const SizedBox(width: 6),
            FilledButton.icon(onPressed: n == 0 || tooMany ? null : onSend, icon: const Icon(LucideIcons.asterisk, size: 16), label: Text(l.fixSend)),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Error texts

/// Codes of the brief and of the security session that have their own text.
const fixErrorCodes = {
  'agent.security.briefRateLimited',
  'agent.security.itemNotFound',
  'agent.security.briefTruncated',
  'agent.claude.securityFixDisabled',
  'agent.claude.securityRequired',
  'agent.claude.securityNoTargets',
  'agent.claude.securityInvestigateReadOnly',
  'agent.claude.bypassNeedsNewSession',
  'agent.claude.securityOwnerOnly',
  'agent.claude.securityTargetGone',
  'agent.claude.securitySshConfig',
};

String fixErrorText(AppLocalizations l, String code, [Map<String, dynamic> params = const {}]) => switch (code) {
      'agent.security.briefRateLimited' => l.fixErrRateLimited((params['limit'] as num?)?.toInt() ?? 10, (((params['windowSeconds'] as num?) ?? 600) / 60).ceil()),
      'agent.security.itemNotFound' => l.fixErrItemNotFound,
      'agent.security.briefTruncated' => l.fixErrTruncated,
      'agent.security.hostNotFound' => l.fixErrHostNotFound,
      'agent.claude.securityFixDisabled' => l.fixErrDisabled,
      'agent.claude.securityRequired' => l.fixErrRequired,
      'agent.claude.securityNoTargets' => l.fixErrNoTargets,
      'agent.claude.securityInvestigateReadOnly' => l.fixErrInvestigateReadOnly,
      'agent.claude.bypassNeedsNewSession' => l.fixErrBypassNew,
      'agent.claude.securityOwnerOnly' => l.fixErrOwnerOnly,
      'agent.claude.securityTargetGone' => l.fixErrTargetGone,
      'agent.claude.securitySshConfig' => l.fixErrSshConfig('${params['host'] ?? '?'}', '${params['reason'] ?? ''}'),
      _ => '${l.commonError} ($code)',
    };

/// Inline "Select" toggle of a block (secrets, outside view) whose screen holds the [FixBar].
class FixSelectRow extends StatelessWidget {
  const FixSelectRow({super.key, required this.selection, required this.agentId, required this.all});
  final FixSelection selection;
  final String agentId;
  final List<FixItem> all;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (all.isEmpty) return const SizedBox.shrink();
    final mine = selection.selecting && selection.agentId == agentId;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: TextButton.icon(
        onPressed: () => mine ? selection.toggleMode() : selection.begin(agentId, all),
        icon: Icon(mine ? LucideIcons.x : LucideIcons.listChecks, size: 16),
        label: Text(mine ? l.fixSelectCancel : l.fixSelect),
      ),
    );
  }
}

/// The [FixBar] of a screen whose blocks bind their own agent and items to the [selection]; null outside selection mode.
Widget? fixBarFor(BuildContext context, WidgetRef ref, FixSelection selection) {
  final agent = selection.agentId;
  if (!selection.selecting || agent == null) return null;
  return FixBar(
    selection: selection,
    all: selection.offered,
    onSend: () async {
      if (await sendToClaude(context, ref, agentId: agent, items: selection.items) && context.mounted) selection.done();
    },
  );
}
