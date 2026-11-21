// Screen mode connections, setup and the setup wizard (PLAN.md §20 U3/U6, generalizing §19's): the display host's
// sources (add / remove / test), the Game source host's ETS2 plugin and map, the `scratch` keybind state, and the wizard
// that connects a display host to source hosts: a `screen`-scoped service token is created on each source (its agent
// API), handed to the display agent and tested; code sharing (diffs and file names) is a separate, explicit step that is
// off unless the user turns it on and confirms (Decision 2).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'screen_data.dart';
import 'screen_texts.dart';
import 'screen_widgets.dart';

// ───────────────────────────── connections ─────────────────────────────

class ConnectionsSection extends ConsumerStatefulWidget {
  const ConnectionsSection({super.key, required this.host, required this.status, required this.onAdd});
  final Host host;
  final ScreenStatus status;
  final VoidCallback onAdd;
  @override
  ConsumerState<ConnectionsSection> createState() => _ConnectionsSectionState();
}

class _ConnectionsSectionState extends ConsumerState<ConnectionsSection> {
  String? _busy;

  Future<void> _remove(ScreenSource src, Host? srcHost, String label) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.smSourceRemoveConfirm(label), confirmLabel: l.smSourceRemove, destructive: true)) return;
    setState(() => _busy = src.name);
    try {
      await ref.read(screenProvider(widget.host.id).notifier).putSources({src.name: null});
      if (srcHost != null) {
        try {
          final c = await ref.read(agentClientFactoryProvider)(srcHost);
          try {
            await revokeScreenTokens(display: widget.host, sourceClient: c);
          } finally {
            c.close();
          }
        } catch (_) {
          // The token stays listed on the source host; it can be revoked there.
        }
      }
      if (mounted) toast(context, l.systemDone);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// The source host answers the phone, and (while a mode uses it) the display host is connected to it.
  Future<void> _test(ScreenSource src, Host? srcHost, String label) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = src.name);
    try {
      if (srcHost != null) {
        ref.invalidate(healthProvider(srcHost.id));
        await ref.read(healthProvider(srcHost.id).future);
      }
      final msg = switch (src.state) {
        'ok' => l.smTestOk(label),
        'down' => l.smTestDown(label),
        _ => srcHost == null ? l.smTestIdleUnknown(label) : l.smTestIdle(label),
      };
      if (mounted) toast(context, msg);
    } catch (e) {
      if (mounted) toast(context, l.smTestUnreachable(label));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = widget.status;
    final profile = ref.watch(profileProvider);
    return GroupedSection(
      title: l.gmSectionConnections,
      footer: s.legacy ? null : l.smConnectionsHint,
      children: [
        GroupedRow(
          title: l.gmDisplayHost,
          subtitle: widget.host.name,
          icon: LucideIcons.monitor,
          iconBackground: t.hostColor(hexColor(widget.host.color)),
          showChevron: false,
          trailing: StateText(text: s.running ? l.gmOn : l.gmOff, color: s.running ? t.success : t.textSecondary, maxWidth: 130),
        ),
        for (final src in s.remoteSources)
          () {
            final h = hostForAgentUrl(profile, src.url);
            final label = sourceLabel(profile, widget.host, s, src.name);
            final (text, color) = sourceStateText(l, t, src.state);
            return GroupedRow(
              title: label,
              subtitle: [l.gmSourceHost, if (h == null && src.url != null) Uri.tryParse(src.url!)?.host ?? src.url!].join(' · '),
              icon: LucideIcons.server,
              iconBackground: h == null ? const Color(0xFF6C6C70) : t.hostColor(hexColor(h.color)),
              showChevron: false,
              trailing: _busy == src.name
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StateText(text: text, color: color, maxWidth: 96),
                        PopupMenuButton<String>(
                          tooltip: l.smSourceActions(label),
                          icon: Icon(LucideIcons.ellipsis, size: 18, color: t.textSecondary),
                          onSelected: (v) => v == 'test' ? _test(src, h, label) : _remove(src, h, label),
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'test', child: Text(l.smSourceTest)),
                            if (!s.legacy) PopupMenuItem(value: 'remove', child: Text(l.smSourceRemove, style: TextStyle(color: t.danger))),
                          ],
                        ),
                      ],
                    ),
            );
          }(),
        GroupedRow(
          title: s.legacy ? l.gmReconfigure : l.smSourceAdd,
          icon: s.legacy ? LucideIcons.refreshCw : LucideIcons.plus,
          iconBackground: t.accent,
          onTap: widget.onAdd,
        ),
      ],
    );
  }
}

// ───────────────────────────── setup (Kurulum) ─────────────────────────────

/// §19's setup of the Game source host (ETS2 plugin, map, Velour) and the `scratch` keybind state.
class SetupSection extends ConsumerStatefulWidget {
  const SetupSection({super.key, required this.host, required this.status});
  final Host host;
  final ScreenStatus status;
  @override
  ConsumerState<SetupSection> createState() => _SetupSectionState();
}

class _SetupSectionState extends ConsumerState<SetupSection> {
  bool _busy = false;

  Future<void> _plugin(Host source, String action) async {
    final l = AppLocalizations.of(context);
    if (action == 'remove' && !await confirmDialog(context, message: l.gmPluginRemoveConfirm, confirmLabel: l.gmPluginRemove, destructive: true)) return;
    setState(() => _busy = true);
    try {
      final c = await ref.read(agentClientFactoryProvider)(source);
      try {
        await gamePlugin(c, action);
      } finally {
        c.close();
      }
      ref.invalidate(gameSourceProvider(source.id));
      if (mounted) toast(context, l.systemDone);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = widget.status;
    final profile = ref.watch(profileProvider);
    final gameSrc = s.settings.mode('game').layout.cards.where((c) => c.kind == 'cockpit' || c.kind == 'map').firstOrNull?.source ?? selfSource;
    final source = hostForSource(profile, widget.host, s, gameSrc);
    final rows = <Widget>[];

    if (!s.legacy) {
      final scratch = s.settings.placement == 'scratch';
      final bound = s.running && s.placement == 'scratch';
      rows.add(
        GroupedRow(
          title: l.smBindState,
          subtitle: scratch ? bindText(s.settings.scratchBind) : l.smPlacementFull,
          icon: LucideIcons.keyboard,
          iconBackground: const Color(0xFF6C6C70),
          showChevron: false,
          trailing: StateText(
            text: !scratch ? l.smBindUnused : (bound ? l.smBindActive : l.smBindOnStart),
            color: bound ? t.success : t.textSecondary,
            maxWidth: 150,
          ),
        ),
      );
    }

    if (source == null) {
      rows.add(GroupedRow(title: l.gmSourceNoHost, showChevron: false));
      return GroupedSection(title: l.gmSectionSetup, children: rows);
    }

    final info = ref.watch(gameSourceProvider(source.id));
    final velourRow = GroupedRow(
      title: l.gmOpenVelour,
      subtitle: info.value != null && !info.value!.velour ? l.gmVelourOff : source.name,
      icon: LucideIcons.music,
      iconBackground: const Color(0xFFFF375F),
      onTap: () => context.push('/system/velour?host=${Uri.encodeQueryComponent(source.id)}'),
    );
    final mapRow = GroupedRow(
      title: l.gmMap,
      icon: LucideIcons.map,
      iconBackground: const Color(0xFF30B0C7),
      showChevron: false,
      trailing: StateText(text: s.mapPresent ? l.gmMapPresent : l.gmMapMissing, color: s.mapPresent ? t.success : t.warning),
    );
    info.when(
      loading: () => rows.add(
        const Padding(
          padding: EdgeInsets.all(18),
          child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      ),
      error: (e, _) => rows.add(
        GroupedRow(
          title: l.gmSourceInfoFailed,
          subtitle: agentErrorText(l, e),
          icon: LucideIcons.triangleAlert,
          iconBackground: t.warning,
          trailing: TextButton(onPressed: () => ref.invalidate(gameSourceProvider(source.id)), child: Text(l.commonRetry)),
        ),
      ),
      data: (i) {
        final installed = i.plugin == 'installed';
        final outdated = i.plugin == 'outdated';
        final version = i.pluginVersion ?? '';
        final pluginText = i.gameDir == null
            ? l.gmPluginNoGame
            : installed
            ? (version.isEmpty ? l.gmPluginInstalledPlain : l.gmPluginInstalled(version))
            : outdated
            ? l.gmPluginOutdated(version.isEmpty ? '?' : version)
            : l.gmPluginMissing;
        final telemetry = installed && i.ets2Running
            ? (i.telemetry == 'unsupported' ? l.gmTelemetryUnsupported : (i.telemetry == 'none' ? l.gmTelemetryNone : null))
            : null;
        rows.add(
          GroupedRow(
            title: l.gmPlugin,
            subtitle: [pluginText, ?telemetry].join('\n'),
            icon: LucideIcons.plug,
            iconBackground: const Color(0xFF1D63ED),
            showChevron: false,
            trailing: i.gameDir == null
                ? null
                : _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (installed || outdated)
                        TextButton(
                          onPressed: () => _plugin(source, 'remove'),
                          style: TextButton.styleFrom(foregroundColor: t.danger),
                          child: Text(l.gmPluginRemove),
                        ),
                      if (!installed) TextButton(onPressed: () => _plugin(source, 'install'), child: Text(outdated ? l.gmPluginUpdate : l.gmPluginInstall)),
                    ],
                  ),
          ),
        );
      },
    );
    rows.addAll([mapRow, velourRow]);
    return GroupedSection(title: l.gmSectionSetup, footer: s.mapPresent ? null : l.gmMapMissingHint, children: rows);
  }
}

// ───────────────────────────── wizard (U6) ─────────────────────────────

class ScreenSetupWizard extends ConsumerStatefulWidget {
  const ScreenSetupWizard({super.key, required this.initialDisplay, required this.onStarted, required this.onDone, this.onCancel});
  final String initialDisplay;
  final VoidCallback onStarted;
  final void Function(String displayHostId) onDone;

  /// Back to the screen without connecting anything (null: the wizard is the only way on).
  final VoidCallback? onCancel;
  @override
  ConsumerState<ScreenSetupWizard> createState() => _ScreenSetupWizardState();
}

/// One source's outcome in the wizard.
class _Result {
  _Result(this.host, {this.name, this.error, this.reachable});
  final Host host;
  final String? name;
  final Object? error;
  final bool? reachable;
}

class _ScreenSetupWizardState extends ConsumerState<ScreenSetupWizard> {
  String? _display;
  Set<String>? _sources;
  bool _busy = false;
  List<_Result>? _results;
  bool _legacy = false;

  /// The code sharing step: which connected sources the user turned it on for (after confirming).
  final _shared = <String>{};

  Future<void> _connect(Host display, List<Host> sources) async {
    setState(() {
      _busy = true;
      _results = null;
    });
    widget.onStarted();
    final factory = ref.read(agentClientFactoryProvider);
    final out = <_Result>[];
    AgentClient? dc;
    try {
      dc = await factory(display);
      // An older display agent (no /v1/screen): Game mode's one source.
      try {
        await dc.get('/v1/screen');
        _legacy = false;
      } catch (e) {
        if (!isNotFound(e)) rethrow;
        _legacy = true;
      }
      for (final src in _legacy ? sources.take(1) : sources) {
        AgentClient? sc;
        try {
          sc = await factory(src);
          final name = await connectScreenSource(display: display, source: src, displayClient: dc, sourceClient: sc, legacy: _legacy);
          var reachable = true;
          try {
            await ref.read(agentHealthFnProvider)(src.agent!.url);
          } catch (_) {
            reachable = false;
          }
          out.add(_Result(src, name: name, reachable: reachable));
        } catch (e) {
          out.add(_Result(src, error: e));
        } finally {
          sc?.close();
        }
      }
    } catch (e) {
      for (final s in sources) {
        out.add(_Result(s, error: e));
      }
    } finally {
      dc?.close();
    }
    ref.invalidate(screenProvider(display.id));
    ref.invalidate(screenTargetProvider);
    if (mounted) {
      setState(() {
        _busy = false;
        _results = out;
      });
    }
  }

  Future<void> _share(Host src, bool on) async {
    final l = AppLocalizations.of(context);
    final display = ref.read(profileProvider).host(_display ?? widget.initialDisplay);
    if (on && !await confirmDialog(context, message: l.smShareConfirm(src.name, display?.name ?? ''), confirmLabel: l.smShareOn)) return;
    try {
      final c = await ref.read(agentClientFactoryProvider)(src);
      try {
        await setShareCode(c, on);
      } finally {
        c.close();
      }
      ref.invalidate(shareCodeProvider(src.id));
      setState(() => on ? _shared.add(src.id) : _shared.remove(src.id));
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final hosts = ref.watch(screenHostsProvider);
    final results = _results;
    if (results != null && results.isNotEmpty && results.every((r) => r.error == null)) return _done(l, t, tt, results);
    return hosts.when(
      loading: () => const ScreenLoading(),
      error: (e, _) => ScreenErrorCard(error: e, onRetry: () => ref.invalidate(screenHostsProvider)),
      data: (list) {
        if (list.length < 2) {
          return ScreenNotice(
            icon: LucideIcons.monitor,
            title: l.smSetupTitle,
            body: l.smSetupNeedTwo,
            action: FilledButton.icon(
              onPressed: () => context.push('/settings/hosts/agent?id=${Uri.encodeQueryComponent(widget.initialDisplay)}'),
              icon: const Icon(LucideIcons.slidersHorizontal, size: 18),
              label: Text(l.gmFeatureOpenSettings),
            ),
          );
        }
        final display = list.where((h) => h.id == (_display ?? widget.initialDisplay)).firstOrNull ?? list.first;
        final others = list.where((h) => h.id != display.id).toList();
        final chosen = (_sources ?? {others.first.id}).where((id) => others.any((h) => h.id == id)).toSet();
        final failed = results?.where((r) => r.error != null).toList() ?? const [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Text(l.smSetupIntro, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
            ),
            ChoiceSection<String>(
              title: l.smSetupDisplay,
              options: [for (final h in list) (h.id, h.name)],
              value: display.id,
              onChanged: (v) => setState(() {
                _display = v;
                _sources = null;
              }),
            ),
            GroupedSection(
              title: l.smSetupSources,
              footer: l.smSetupSourcesHint,
              children: [
                for (final h in others)
                  MergeSemantics(
                    child: GroupedRow(
                      title: h.name,
                      icon: LucideIcons.server,
                      iconBackground: t.hostColor(hexColor(h.color)),
                      showChevron: false,
                      onTap: () => setState(() => _sources = chosen.contains(h.id) ? (chosen.toSet()..remove(h.id)) : {...chosen, h.id}),
                      trailing: Checkbox(
                        value: chosen.contains(h.id),
                        onChanged: (v) => setState(() => _sources = v == true ? {...chosen, h.id} : (chosen.toSet()..remove(h.id))),
                      ),
                    ),
                  ),
              ],
            ),
            for (final r in failed)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('${r.host.name}: ${agentErrorText(l, r.error!)}', style: TextStyle(color: t.danger)),
              ),
            const SizedBox(height: 18),
            SizedBox(
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: _busy || chosen.isEmpty
                    ? null
                    : () {
                        _display = display.id;
                        _sources = chosen;
                        unawaited(_connect(display, [for (final h in others) if (chosen.contains(h.id)) h]));
                      },
                child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.gmSetupConnect),
              ),
            ),
            if (widget.onCancel != null) ...[
              const SizedBox(height: 6),
              TextButton(onPressed: _busy ? null : widget.onCancel, child: Text(l.commonCancel)),
            ],
          ],
        );
      },
    );
  }

  /// Connected: the test result per source, then the separate code sharing step (off unless turned on).
  Widget _done(AppLocalizations l, TiphysTokens t, TextTheme tt, List<_Result> results) {
    final down = results.where((r) => r.reachable == false).toList();
    final names = results.map((r) => r.host.name).join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScreenNotice(
          icon: down.isEmpty ? LucideIcons.circleCheck : LucideIcons.triangleAlert,
          iconColor: down.isEmpty ? t.success : t.warning,
          title: l.gmSetupDoneTitle,
          body: down.isEmpty ? l.smSetupDoneBody(names) : l.gmSetupDownBody(down.map((r) => r.host.name).join(', ')),
        ),
        if (!_legacy) ...[
          SectionLabel(l.smShareStep),
          TCard(
            radius: TiphysTokens.radiusList,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.fileCode2, size: 20, color: t.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(l.smShareStepTitle, style: tt.titleMedium)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(l.smShareStepBody, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
                const SizedBox(height: 6),
                for (final r in results)
                  MergeSemantics(
                    child: Row(
                      children: [
                        Expanded(child: Text(r.host.name, style: tt.titleMedium)),
                        Text(_shared.contains(r.host.id) ? l.gmOn : l.gmOff, style: tt.bodySmall),
                        Switch(value: _shared.contains(r.host.id), onChanged: (v) => _share(r.host, v)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        SizedBox(
          height: 52,
          child: FilledButton(
            style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
            onPressed: () => widget.onDone(_display ?? widget.initialDisplay),
            child: Text(l.gmSetupFinish),
          ),
        ),
      ],
    );
  }
}
