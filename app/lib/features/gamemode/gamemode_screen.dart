// Game mode screen (route /gamemode?host=<display host>): hero with live preview and a one-tap Start/Stop, the kiosk's
// settings (each change goes to the display PC at once), connections and the source PC's setup. When no source is set up
// yet the setup wizard is shown instead. PLAN.md §19.
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
import 'gamemode_data.dart';

class GameModeScreen extends ConsumerStatefulWidget {
  const GameModeScreen({super.key, required this.hostId});

  /// The display host; empty: the one that is set up (or the first host with the feature).
  final String hostId;
  @override
  ConsumerState<GameModeScreen> createState() => _GameModeScreenState();
}

class _GameModeScreenState extends ConsumerState<GameModeScreen> {
  late String _hostId = widget.hostId;

  /// null: the wizard shows while no source is set up; true: forced open (set up again / still showing its result).
  bool? _wizard;

  void _setHost(String id) => setState(() {
    _hostId = id;
    _wizard = false;
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final profile = ref.watch(profileProvider);
    var hostId = _hostId;
    if (hostId.isEmpty) {
      final target = ref.watch(gameModeTargetProvider);
      if (target.isLoading && !target.hasValue) return _page(l, null, [const _Loading()]);
      hostId = target.value?.host.id ?? '';
    }
    final host = profile.host(hostId);
    if (host == null) return _page(l, null, [_Notice(icon: LucideIcons.gamepad2, title: l.gmNoHostTitle, body: l.gmNoHostBody)]);

    final health = ref.watch(healthProvider(host.id));
    final features = health.value?['features'] as Map?;
    if (features != null && features['gamemode'] != true) return _page(l, host, [_FeatureOff(host: host)]);

    final status = ref.watch(gameModeProvider(host.id));
    return _page(l, host, [
      if (status.value == null)
        status.when(
          loading: () => const _Loading(),
          error: (e, _) => e is AgentError && (e.code == 'agent.route.notFound' || e.status == 404)
              ? _FeatureOff(host: host)
              : _ErrorCard(error: e, onRetry: () => ref.read(gameModeProvider(host.id).notifier).retry()),
          data: (_) => const SizedBox.shrink(),
        )
      else ...[
        if (status.hasError) _ErrorCard(error: status.error!, onRetry: () => ref.read(gameModeProvider(host.id).notifier).retry()),
        if (_wizard ?? !status.value!.sourceConfigured)
          _SetupWizard(
            initialDisplay: host.id,
            onStarted: () => setState(() => _wizard = true),
            onDone: (display) => display == host.id ? setState(() => _wizard = false) : _setHost(display),
          )
        else
          _Main(host: host, status: status.value!, onReconfigure: () => setState(() => _wizard = true)),
      ],
    ]);
  }

  Widget _page(AppLocalizations l, Host? host, List<Widget> body) => SettingsPage(
    title: host?.name ?? l.gmTitle,
    children: [
      LargeTitleHeader(title: l.gmTitle),
      const SizedBox(height: 14),
      ...body,
    ],
  );
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(40),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 28, color: t.textSecondary),
          const SizedBox(height: 12),
          Text(title, style: tt.titleLarge),
          const SizedBox(height: 6),
          Text(body, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

/// The feature is off on this host: explain and lead to the agent settings where it is turned on.
class _FeatureOff extends StatelessWidget {
  const _FeatureOff({required this.host});
  final Host host;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return _Notice(
      icon: LucideIcons.powerOff,
      title: l.gmFeatureOffTitle,
      body: l.gmFeatureOffBody,
      action: FilledButton.icon(
        onPressed: () => context.push('/settings/hosts/agent?id=${Uri.encodeQueryComponent(host.id)}'),
        icon: const Icon(LucideIcons.slidersHorizontal, size: 18),
        label: Text(l.gmFeatureOpenSettings),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TCard(
        child: Row(
          children: [
            Icon(LucideIcons.triangleAlert, color: t.warning, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(agentErrorText(l, error))),
            TextButton(onPressed: onRetry, child: Text(l.commonRetry)),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── main view ─────────────────────────────

class _Main extends ConsumerWidget {
  const _Main({required this.host, required this.status, required this.onReconfigure});
  final Host host;
  final GameStatus status;
  final VoidCallback onReconfigure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final source = hostForAgentUrl(ref.watch(profileProvider), status.sourceUrl);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GameHero(host: host, status: status),
        _SettingsSection(hostId: host.id, settings: status.settings),
        _ConnectionsSection(host: host, status: status, source: source, onReconfigure: onReconfigure),
        if (source != null)
          _SetupSection(source: source, mapPresent: status.mapPresent)
        else
          GroupedSection(
            title: l.gmSectionSetup,
            children: [GroupedRow(title: l.gmSourceNoHost, showChevron: false)],
          ),
      ],
    );
  }
}

/// Scene, song and ETS2 state in words, for the hero and the card.
String gameSceneName(AppLocalizations l, String scene) => switch (scene) {
  'drive' => l.gmSceneDrive,
  'music' => l.gmSceneMusic,
  _ => l.gmSceneIdle,
};

String gameEts2Text(AppLocalizations l, GameTruck? t) => switch (t?.state) {
  'menu' => l.gmEts2Menu,
  'paused' => l.gmEts2Paused,
  'driving' => l.gmEts2Driving,
  _ => l.gmEts2None,
};

/// Hero: preview of what the display shows, and the big Start/Stop button.
class GameHero extends ConsumerStatefulWidget {
  const GameHero({super.key, required this.host, required this.status});
  final Host host;
  final GameStatus status;
  @override
  ConsumerState<GameHero> createState() => _GameHeroState();
}

class _GameHeroState extends ConsumerState<GameHero> {
  bool _busy = false;

  Future<void> _toggle() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(gameModeProvider(widget.host.id).notifier).setRunning(!widget.status.running);
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
    final tt = Theme.of(context).textTheme;
    final s = widget.status;
    final on = s.running;
    final truck = s.truck;
    final music = s.music;
    final accent = on ? t.success : t.textSecondary;
    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: on ? t.accent : t.chipBackground, borderRadius: BorderRadius.circular(15)),
                child: Icon(LucideIcons.gamepad2, color: on ? t.onAccent : t.textSecondary, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StatusDot(color: accent),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            on ? l.gmOnAt(widget.host.name) : l.gmOff,
                            style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      on ? l.gmSceneNow(gameSceneName(l, s.activeScene)) : l.gmOffHint(widget.host.name),
                      style: tt.bodySmall?.copyWith(color: t.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (on) ...[
            const SizedBox(height: 14),
            Divider(color: t.separator, height: 1),
            const SizedBox(height: 12),
            _PreviewRow(
              icon: LucideIcons.music,
              title: music == null ? l.gmNothingPlaying : music.title,
              subtitle: music == null || music.artist.isEmpty ? null : music.artist,
              dim: music == null,
            ),
            const SizedBox(height: 10),
            _PreviewRow(
              icon: LucideIcons.truck,
              title: truck?.driving == true && truck?.speedKmh != null ? l.gmDrivingSpeed('${truck!.speedKmh}') : gameEts2Text(l, truck),
              subtitle: truck?.driving == true && truck?.from != null && truck?.to != null ? '${truck!.from} → ${truck.to}' : null,
              dim: truck?.driving != true,
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: on ? t.danger : t.accent,
                foregroundColor: on ? Colors.white : t.onAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                textStyle: tt.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              onPressed: _busy ? null : _toggle,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(on ? LucideIcons.square : LucideIcons.play, size: 20),
              label: Text(on ? l.gmStop : l.gmStart),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.icon, required this.title, this.subtitle, this.dim = false});
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool dim;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(11)),
          child: Icon(icon, size: 17, color: t.textSecondary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: tt.titleMedium?.copyWith(color: dim ? t.textSecondary : t.text),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) Text(subtitle!, style: tt.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────── settings ─────────────────────────────

class _SettingsSection extends ConsumerStatefulWidget {
  const _SettingsSection({required this.hostId, required this.settings});
  final String hostId;
  final GameSettings settings;
  @override
  ConsumerState<_SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends ConsumerState<_SettingsSection> {
  /// While the slider is dragged its own value shows (the status polls would pull it back).
  double? _drag;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _save(Map<String, Object?> patch) async {
    final l = AppLocalizations.of(context);
    try {
      await ref.read(gameModeProvider(widget.hostId).notifier).saveSettings(patch);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
  }

  void _brightness(double v, {bool end = false}) {
    setState(() => _drag = v);
    _debounce?.cancel();
    void send() {
      unawaited(_save({'brightness': v.round()}));
      if (mounted) setState(() => _drag = null);
    }

    if (end) {
      send();
    } else {
      _debounce = Timer(const Duration(milliseconds: 350), send);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = widget.settings;
    final keep = s.brightness == null;
    final shown = (_drag ?? s.brightness ?? 60).clamp(5, 100).toDouble();
    final dim = {0, 5, 10, 30, 60, s.dimIdleMinutes}.toList()..sort();
    return GroupedSection(
      title: l.gmSectionDisplay,
      children: [
        _SegRow<String>(
          title: l.gmScene,
          value: s.scene,
          options: [('auto', l.gmSceneAuto), ('drive', l.gmSceneDrive), ('music', l.gmSceneMusic)],
          onChanged: (v) => _save({'scene': v}),
        ),
        SwitchRow(
          title: l.gmLyrics,
          icon: LucideIcons.textQuote,
          iconBackground: const Color(0xFF5E5CE6),
          value: s.lyrics,
          onChanged: (v) => _save({'lyrics': v}),
        ),
        SwitchRow(
          title: l.gmSpectrum,
          icon: LucideIcons.audioLines,
          iconBackground: const Color(0xFFFF375F),
          value: s.spectrum,
          onChanged: (v) => _save({'spectrum': v}),
        ),
        _SegRow<String>(
          title: l.gmMotion,
          value: s.motion,
          options: [('low', l.gmMotionLow), ('normal', l.gmMotionNormal), ('high', l.gmMotionHigh)],
          onChanged: (v) => _save({'motion': v}),
        ),
        SwitchRow(
          title: l.gmBrightnessKeep,
          subtitle: l.gmBrightnessKeepHint,
          icon: LucideIcons.sun,
          iconBackground: const Color(0xFFFF9F0A),
          value: keep,
          onChanged: (v) => _save({'brightness': v ? null : 60}),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(l.gmBrightness, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: keep ? t.textSecondary : t.text)),
                  ),
                  Text(
                    keep ? '–' : '${shown.round()}%',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
              Semantics(
                label: l.gmBrightness,
                value: keep ? null : '${shown.round()}%',
                child: Slider(
                  value: shown,
                  min: 5,
                  max: 100,
                  divisions: 19,
                  onChanged: keep ? null : _brightness,
                  onChangeEnd: keep ? null : (v) => _brightness(v, end: true),
                ),
              ),
            ],
          ),
        ),
        SwitchRow(
          title: l.gmClock24,
          icon: LucideIcons.clock,
          iconBackground: const Color(0xFF0A84FF),
          value: s.clock24,
          onChanged: (v) => _save({'clock24': v}),
        ),
        _SegRow<int>(
          title: l.gmDimAfter,
          subtitle: l.gmDimHint,
          value: s.dimIdleMinutes,
          options: [for (final m in dim) (m, m == 0 ? l.gmDimNever : '$m')],
          onChanged: (v) => _save({'dimIdleMinutes': v}),
        ),
      ],
    );
  }
}

/// A row with a title and a segmented choice under it (full width, so three or five segments fit at 375 px).
class _SegRow<T> extends StatelessWidget {
  const _SegRow({required this.title, required this.value, required this.options, required this.onChanged, this.subtitle});
  final String title;
  final String? subtitle;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: tt.titleMedium),
          if (subtitle != null) Text(subtitle!, style: tt.bodySmall),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              showSelectedIcon: false,
              segments: [
                for (final (v, label) in options)
                  ButtonSegment(
                    value: v,
                    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              selected: {value},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── connections ─────────────────────────────

class _ConnectionsSection extends StatelessWidget {
  const _ConnectionsSection({required this.host, required this.status, required this.source, required this.onReconfigure});
  final Host host;
  final GameStatus status;
  final Host? source;
  final VoidCallback onReconfigure;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final (srcLabel, srcColor) = switch (status.sourceState) {
      'ok' => (l.gmStateOk, t.success),
      'connecting' => (l.gmStateConnecting, t.warning),
      'down' => (l.gmStateDown, t.danger),
      _ => (l.gmStateOff, t.textSecondary),
    };
    Widget state(String text, Color c) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: c),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(fontSize: 13.5, color: t.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final srcName = source?.name ?? Uri.tryParse(status.sourceUrl ?? '')?.host ?? l.gmSourceUnknown;
    return GroupedSection(
      title: l.gmSectionConnections,
      children: [
        GroupedRow(
          title: l.gmDisplayHost,
          subtitle: host.name,
          icon: LucideIcons.monitor,
          iconBackground: t.hostColor(hexColor(host.color)),
          showChevron: false,
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: state(status.running ? l.gmOn : l.gmOff, status.running ? t.success : t.textSecondary),
          ),
        ),
        GroupedRow(
          title: l.gmSourceHost,
          subtitle: srcName,
          icon: LucideIcons.server,
          iconBackground: source == null ? const Color(0xFF6C6C70) : t.hostColor(hexColor(source!.color)),
          showChevron: false,
          trailing: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 130), child: state(srcLabel, srcColor)),
        ),
        GroupedRow(title: l.gmReconfigure, icon: LucideIcons.refreshCw, iconBackground: const Color(0xFF6C6C70), onTap: onReconfigure),
      ],
    );
  }
}

// ───────────────────────────── setup (source PC) ─────────────────────────────

class _SetupSection extends ConsumerStatefulWidget {
  const _SetupSection({required this.source, required this.mapPresent});
  final Host source;

  /// The map files live on the display host (GET /v1/gamemode), not on the source.
  final bool mapPresent;
  @override
  ConsumerState<_SetupSection> createState() => _SetupSectionState();
}

class _SetupSectionState extends ConsumerState<_SetupSection> {
  bool _busy = false;

  Future<void> _plugin(String action) async {
    final l = AppLocalizations.of(context);
    if (action == 'remove' && !await confirmDialog(context, message: l.gmPluginRemoveConfirm, confirmLabel: l.gmPluginRemove, destructive: true)) return;
    setState(() => _busy = true);
    try {
      final c = await ref.read(agentClientFactoryProvider)(widget.source);
      try {
        await c.request('POST', '/v1/gamemode/plugin', body: {'action': action}, timeout: const Duration(seconds: 90));
      } finally {
        c.close();
      }
      ref.invalidate(gameSourceProvider(widget.source.id));
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
    final info = ref.watch(gameSourceProvider(widget.source.id));
    final velourRow = GroupedRow(
      title: l.gmOpenVelour,
      subtitle: info.value != null && !info.value!.velour ? l.gmVelourOff : null,
      icon: LucideIcons.music,
      iconBackground: const Color(0xFFFF375F),
      onTap: () => context.push('/system/velour?host=${Uri.encodeQueryComponent(widget.source.id)}'),
    );
    return info.when(
      loading: () => GroupedSection(
        title: l.gmSectionSetup,
        children: [
          const Padding(
            padding: EdgeInsets.all(18),
            child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
          velourRow,
        ],
      ),
      error: (e, _) => GroupedSection(
        title: l.gmSectionSetup,
        children: [
          GroupedRow(
            title: l.gmSourceInfoFailed,
            subtitle: agentErrorText(l, e),
            icon: LucideIcons.triangleAlert,
            iconBackground: t.warning,
            trailing: TextButton(onPressed: () => ref.invalidate(gameSourceProvider(widget.source.id)), child: Text(l.commonRetry)),
          ),
          velourRow,
        ],
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
        return GroupedSection(
          title: l.gmSectionSetup,
          footer: widget.mapPresent ? null : l.gmMapMissingHint,
          children: [
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
                            onPressed: () => _plugin('remove'),
                            style: TextButton.styleFrom(foregroundColor: t.danger),
                            child: Text(l.gmPluginRemove),
                          ),
                        if (!installed) TextButton(onPressed: () => _plugin('install'), child: Text(outdated ? l.gmPluginUpdate : l.gmPluginInstall)),
                      ],
                    ),
            ),
            GroupedRow(
              title: l.gmMap,
              icon: LucideIcons.map,
              iconBackground: const Color(0xFF30B0C7),
              showChevron: false,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusDot(color: widget.mapPresent ? t.success : t.warning),
                  const SizedBox(width: 6),
                  Text(widget.mapPresent ? l.gmMapPresent : l.gmMapMissing, style: TextStyle(fontSize: 13.5, color: t.textSecondary)),
                ],
              ),
            ),
            velourRow,
          ],
        );
      },
    );
  }
}

// ───────────────────────────── wizard ─────────────────────────────

class _SetupWizard extends ConsumerStatefulWidget {
  const _SetupWizard({required this.initialDisplay, required this.onStarted, required this.onDone});
  final String initialDisplay;
  final VoidCallback onStarted;
  final void Function(String displayHostId) onDone;
  @override
  ConsumerState<_SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends ConsumerState<_SetupWizard> {
  String? _display;
  String? _source;
  bool _busy = false;
  GameStatus? _result;
  Object? _error;

  Future<void> _connect(Host display, Host source) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onStarted();
    AgentClient? dc, sc;
    try {
      final factory = ref.read(agentClientFactoryProvider);
      dc = await factory(display);
      sc = await factory(source);
      final st = await connectGameMode(display: display, source: source, displayClient: dc, sourceClient: sc);
      ref.invalidate(gameModeProvider(display.id));
      ref.invalidate(gameModeTargetProvider);
      if (mounted) setState(() => _result = st);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      dc?.close();
      sc?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final hosts = ref.watch(gameModeHostsProvider);
    final profile = ref.watch(profileProvider);
    if (_result != null) {
      final src = profile.host(_source ?? '')?.name ?? '';
      final down = _result!.sourceState == 'down';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Notice(
            icon: down ? LucideIcons.triangleAlert : LucideIcons.circleCheck,
            title: l.gmSetupDoneTitle,
            body: down ? l.gmSetupDownBody(src) : l.gmSetupDoneBody(src),
            action: FilledButton(onPressed: () => widget.onDone(_display ?? widget.initialDisplay), child: Text(l.gmSetupFinish)),
          ),
        ],
      );
    }
    return hosts.when(
      loading: () => const _Loading(),
      error: (e, _) => _ErrorCard(error: e, onRetry: () => ref.invalidate(gameModeHostsProvider)),
      data: (list) {
        if (list.length < 2) {
          return _Notice(
            icon: LucideIcons.gamepad2,
            title: l.gmSetupTitle,
            body: l.gmSetupNeedTwo,
            action: FilledButton.icon(
              onPressed: () => context.push('/settings/hosts/agent?id=${Uri.encodeQueryComponent(widget.initialDisplay)}'),
              icon: const Icon(LucideIcons.slidersHorizontal, size: 18),
              label: Text(l.gmFeatureOpenSettings),
            ),
          );
        }
        final display = list.where((h) => h.id == (_display ?? widget.initialDisplay)).firstOrNull ?? list.first;
        final others = list.where((h) => h.id != display.id).toList();
        final source = others.where((h) => h.id == _source).firstOrNull ?? others.first;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Text(l.gmSetupIntro, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
            ),
            ChoiceSection<String>(
              title: l.gmSetupDisplay,
              options: [for (final h in list) (h.id, h.name)],
              value: display.id,
              onChanged: (v) => setState(() => _display = v),
            ),
            ChoiceSection<String>(
              title: l.gmSetupSource,
              options: [for (final h in others) (h.id, h.name)],
              value: source.id,
              onChanged: (v) => setState(() => _source = v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(agentErrorText(l, _error!), style: TextStyle(color: t.danger)),
              ),
            const SizedBox(height: 18),
            SizedBox(
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: _busy
                    ? null
                    : () {
                        _display = display.id;
                        _source = source.id;
                        unawaited(_connect(display, source));
                      },
                child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.gmSetupConnect),
              ),
            ),
          ],
        );
      },
    );
  }
}
