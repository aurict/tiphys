// System › Desktop (10.1): the PC's Hyprland desktop — workspace strip on top, window cards in the middle
// (thumbnail or app icon; tap = bring to front, swipe = close (confirmed), long press = menu), tools
// (media, clipboard, screenshot, screen off/on, sleep) and an app launcher at the bottom (search, categories,
// recently used). Browsing doesn't need a session; the first changing action opens a control session (lock asked
// again); while open, a "Control on · 14:59 · Stop" strip sits at the bottom. The session closes when leaving the
// screen or when the app stays in the background for more than 60 s.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
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
import '../system/media.dart';
import '../system/tools.dart' show ClipboardScreen, ScreenshotScreen;
import 'browser.dart';
import 'browser_screen.dart';
import 'desktop_caps.dart';
import 'desktop_data.dart';
import 'live_screen.dart';
import 'mobile_view_screen.dart';
import 'moonlight.dart';

/// The control session closes if the app stays in the background longer than this.
const controlBackgroundLimit = Duration(seconds: 60);

class DesktopScreen extends ConsumerStatefulWidget {
  const DesktopScreen({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<DesktopScreen> createState() => _DesktopScreenState();
}

class _DesktopScreenState extends ConsumerState<DesktopScreen> {
  late final ControlController _control;
  late final AppLifecycleListener _life;
  Timer? _bgTimer;
  DateTime? _bgAt;
  final _search = TextEditingController();
  String _group = 'all';

  @override
  void initState() {
    super.initState();
    _control = ref.read(controlProvider.notifier);
    _life = AppLifecycleListener(onStateChange: (s) {
      if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) {
        _bgAt ??= DateTime.now();
        _bgTimer ??= Timer(controlBackgroundLimit, _control.release);
      } else if (s == AppLifecycleState.resumed) {
        _bgTimer?.cancel();
        _bgTimer = null;
        final at = _bgAt;
        _bgAt = null;
        if (at != null && DateTime.now().difference(at) >= controlBackgroundLimit) _control.release();
      }
    });
  }

  @override
  void dispose() {
    _life.dispose();
    _bgTimer?.cancel();
    _search.dispose();
    // Leaving the screen ends the session (the indicator on the PC goes away) — unless a Claude using the PC holds it.
    Future.microtask(_control.release);
    super.dispose();
  }

  String get _lang => Localizations.localeOf(context).languageCode == 'tr' ? 'tr' : 'en';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = ref.watch(profileProvider).host(widget.hostId);
    final features = (ref.watch(healthProvider(widget.hostId)).value?['features'] as Map?);
    final featureOff = host?.agent == null || (features != null && features['desktop'] != true);
    final controlOff = features != null && features['control'] != true;
    final session = ref.watch(controlProvider);
    final active = session != null && session.hostId == widget.hostId;
    final caps = desktopCapsOf(ref, widget.hostId);
    final missing = missingDesktopFeatures(l, caps);

    final slivers = <Widget>[
      SliverAppBar(
        pinned: true,
        backgroundColor: t.isDark ? const Color(0xCC000000) : t.background,
        title: Text(host == null ? l.desktopTitle : '${l.desktopTitle} · ${host.name}'),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(LucideIcons.chevronLeft),
          onPressed: () => context.canPop() ? context.pop() : context.go('/system'),
        ),
        actions: [
          if (!featureOff && caps.has('stream'))
            IconButton(
              tooltip: l.liveTitle,
              icon: const Icon(LucideIcons.monitorPlay),
              onPressed: () {
                if (!_blocked(controlOff)) openLiveScreen(context, widget.hostId, title: host?.name);
              },
            ),
          if (!featureOff)
            IconButton(
              tooltip: l.commonRefresh,
              icon: const Icon(LucideIcons.refreshCw),
              onPressed: () {
                ref.invalidate(desktopStateProvider(widget.hostId));
                ref.invalidate(desktopAppsProvider((widget.hostId, _lang)));
                ref.invalidate(browserStatusProvider(widget.hostId));
                ref.invalidate(desktopCapsProvider(widget.hostId));
              },
            ),
        ],
      ),
    ];
    if (featureOff) {
      slivers.add(_pad(SliverToBoxAdapter(child: _FeatureOff(host: host))));
    } else {
      slivers.addAll([
        if (controlOff) _pad(SliverToBoxAdapter(child: _Note(icon: LucideIcons.eye, text: l.desktopControlOffHint))),
        // Helper backend that couldn't start (no helper binary, OS permission): say why instead of failing each call.
        if (caps.error != null && caps.caps.isEmpty)
          _pad(SliverToBoxAdapter(child: _Note(icon: LucideIcons.monitorOff, title: l.desktopHelperDown, text: agentErrorText(l, AgentError(caps.error!)))))
        else if (missing.isNotEmpty && !caps.isHyprland)
          _pad(SliverToBoxAdapter(child: _Note(icon: LucideIcons.info, text: l.desktopCapsMissing(desktopBackendName(l, caps), missing.join(', '))))),
        if (caps.has('windows')) ..._windowSlivers(l, controlOff, caps),
        _pad(SliverToBoxAdapter(child: _Tools(hostId: widget.hostId, host: host!, controlOff: controlOff, powerOn: features?['power'] == true, caps: caps))),
        if (caps.has('apps')) ..._appSlivers(l, controlOff, caps),
      ]);
    }
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + (active ? 96 : 40))));

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: Stack(children: [
          CustomScrollView(slivers: slivers),
          if (active)
            Positioned(
              left: TiphysTokens.gutter,
              right: TiphysTokens.gutter,
              bottom: MediaQuery.paddingOf(context).bottom + 14,
              child: ControlBanner(session: session),
            ),
        ]),
      ),
    );
  }

  Widget _pad(Widget sliver) => SliverPadding(padding: const EdgeInsets.symmetric(horizontal: TiphysTokens.gutter), sliver: sliver);

  Future<void> _act(String path, {Object? body, String? done}) => desktopAction(context, ref, widget.hostId, path, body: body, done: done);

  /// While "control" is off, changing taps only show an explanation.
  bool _blocked(bool controlOff) {
    if (controlOff) toast(context, AppLocalizations.of(context).desktopControlOffHint);
    return controlOff;
  }

  List<Widget> _windowSlivers(AppLocalizations l, bool controlOff, DesktopCaps caps) {
    final value = ref.watch(desktopStateProvider(widget.hostId));
    return value.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => [const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())))],
      error: (e, _) => [
        _pad(SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: e is AgentError && e.code == 'agent.desktop.noHyprland'
                ? _Note(icon: LucideIcons.monitorOff, title: l.desktopNoHyprland, text: l.desktopNoHyprlandHint)
                : _ErrorCard(text: agentErrorText(l, e), onRetry: () => ref.invalidate(desktopStateProvider(widget.hostId))),
          ),
        )),
      ],
      data: (s) => [
        if (caps.has('workspaces')) ...[
          _pad(SliverToBoxAdapter(child: SectionLabel(l.desktopWorkspaces))),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 58,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: TiphysTokens.gutter),
                children: [
                  for (final w in s.workspaces)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _WorkspaceChip(
                        ws: w,
                        onTap: w.focused
                            ? null
                            : () {
                                if (!_blocked(controlOff)) _act('/v1/desktop/workspace/${w.id}');
                              },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        _pad(SliverToBoxAdapter(child: SectionLabel(l.desktopWindows))),
        if (s.windows.isEmpty)
          _pad(SliverToBoxAdapter(child: _Note(icon: LucideIcons.appWindow, title: l.desktopNoWindows, text: l.desktopNoWindowsHint)))
        else ...[
          _pad(SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.98),
            itemCount: s.windows.length,
            itemBuilder: (c, i) => _WindowCard(
              hostId: widget.hostId,
              w: s.windows[i],
              thumbs: caps.has('thumbnails'),
              canClose: caps.has('windowActions'),
              onFocus: () {
                if (!_blocked(controlOff)) _act('/v1/desktop/windows/${s.windows[i].address}/focus');
              },
              onClose: () async {
                if (_blocked(controlOff)) return;
                final w = s.windows[i];
                if (!await confirmDialog(context, message: l.desktopCloseConfirm(w.label), confirmLabel: l.desktopCloseWindow, destructive: true)) return;
                await _act('/v1/desktop/windows/${w.address}/close');
              },
              onMenu: () => _windowMenu(s, s.windows[i], controlOff, caps),
            ),
          )),
          _pad(SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(l.desktopWindowHint, style: Theme.of(context).textTheme.bodySmall),
            ),
          )),
        ],
      ],
    );
  }

  Future<void> _windowMenu(DesktopState s, DesktopWindow w, bool controlOff, DesktopCaps caps) async {
    final actions = caps.has('windowActions');
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final picked = await showModalBottomSheet<String>(
      useRootNavigator: true, // so the bottom tab bar doesn't cover the bottom of the page
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(w.label, style: Theme.of(c).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            if (w.visible && caps.has('stream')) ListTile(leading: const Icon(LucideIcons.monitorPlay), title: Text(l.liveShowWindow), onTap: () => Navigator.pop(c, 'live')),
            if (w.visible && caps.has('mobileView')) ListTile(leading: const Icon(LucideIcons.layoutList), title: Text(l.uiTitle), onTap: () => Navigator.pop(c, 'mobile')),
            ListTile(leading: const Icon(LucideIcons.scanEye), title: Text(l.desktopFocus), onTap: () => Navigator.pop(c, 'focus')),
            if (actions) ...[
              ListTile(leading: const Icon(LucideIcons.maximize), title: Text(l.desktopFullscreen), onTap: () => Navigator.pop(c, 'fullscreen')),
              ListTile(leading: const Icon(LucideIcons.pictureInPicture2), title: Text(l.desktopFloat), onTap: () => Navigator.pop(c, 'float')),
              // The helper backend has no "pin"; it answers 501.
              if (caps.isHyprland) ListTile(leading: const Icon(LucideIcons.pin), title: Text(l.desktopPin), onTap: () => Navigator.pop(c, 'pin')),
            ],
            if (actions && caps.has('workspaces')) ...[
              Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 6), child: Text(l.desktopMoveTo, style: Theme.of(c).textTheme.bodySmall)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final n in s.moveTargets)
                    ActionChip(
                      label: Text('$n'),
                      tooltip: l.desktopWorkspace('$n'),
                      onPressed: n == w.workspaceId ? null : () => Navigator.pop(c, 'move:$n'),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 6),
            if (actions)
              ListTile(
                leading: Icon(LucideIcons.x, color: t.danger),
                title: Text(l.desktopCloseWindow, style: TextStyle(color: t.danger)),
                onTap: () => Navigator.pop(c, 'close'),
              ),
          ]),
        ),
      ),
    );
    if (picked == null || !mounted || _blocked(controlOff)) return;
    final base = '/v1/desktop/windows/${w.address}';
    if (picked == 'live') {
      await openLiveScreen(context, widget.hostId, window: w.address, title: w.label);
    } else if (picked == 'mobile') {
      await openMobileView(context, widget.hostId, address: w.address, title: w.label);
    } else if (picked == 'close') {
      if (!await confirmDialog(context, message: l.desktopCloseConfirm(w.label), confirmLabel: l.desktopCloseWindow, destructive: true)) return;
      await _act('$base/close');
    } else if (picked.startsWith('move:')) {
      await _act('$base/move-to-workspace', body: {'workspace': int.parse(picked.substring(5))});
    } else {
      await _act('$base/$picked');
    }
  }

  List<Widget> _appSlivers(AppLocalizations l, bool controlOff, DesktopCaps caps) {
    final value = ref.watch(desktopAppsProvider((widget.hostId, _lang)));
    final recentIds = ref.watch(desktopRecentProvider.select((m) => m[widget.hostId] ?? const <String>[]));
    final header = <Widget>[
      SectionLabel(l.desktopApps),
      TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(hintText: l.desktopAppsSearch, prefixIcon: const Icon(LucideIcons.search, size: 18), isDense: true),
      ),
    ];
    return value.when(
      skipLoadingOnRefresh: true,
      loading: () => [
        _pad(SliverList.list(children: [...header, const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))])),
      ],
      error: (e, _) => [
        _pad(SliverList.list(children: [
          SectionLabel(l.desktopApps),
          _ErrorCard(text: agentErrorText(l, e), onRetry: () => ref.invalidate(desktopAppsProvider((widget.hostId, _lang)))),
        ])),
      ],
      data: (apps) {
        final groups = [for (final g in desktopGroups) if (apps.any((a) => a.group == g)) g];
        final group = groups.contains(_group) ? _group : 'all';
        final q = _search.text;
        final shown = [for (final a in apps) if ((group == 'all' || a.group == group) && a.matches(q)) a];
        final byId = {for (final a in apps) a.id: a};
        final recents = [for (final id in recentIds) ?byId[id]];
        void launch(DesktopApp a) async {
          if (_blocked(controlOff)) return;
          if (!caps.has('launch')) return toast(context, l.desktopCapsMissing(desktopBackendName(l, caps), l.desktopCapLaunch));
          if (await desktopAction(context, ref, widget.hostId, '/v1/desktop/apps/${Uri.encodeComponent(a.id)}/launch', done: l.desktopLaunched(a.name))) {
            await ref.read(desktopRecentProvider.notifier).add(widget.hostId, a.id);
          }
        }

        return [
          _pad(SliverList.list(children: [
            ...header,
            const SizedBox(height: 10),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final g in ['all', ...groups])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _Pill(label: g == 'all' ? l.desktopCatAll : desktopGroupLabel(l, g), selected: g == group, onTap: () => setState(() => _group = g)),
                  ),
              ]),
            ),
            if (recents.isNotEmpty && q.trim().isEmpty && group == 'all') ...[
              SectionLabel(l.desktopRecent),
              SizedBox(
                height: 92,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final a in recents) SizedBox(width: 80, child: _AppTile(hostId: widget.hostId, app: a, onTap: () => launch(a))),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            if (shown.isEmpty) _Note(icon: LucideIcons.searchX, text: l.desktopAppsEmpty),
          ])),
          _pad(SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 88, mainAxisSpacing: 6, crossAxisSpacing: 4, mainAxisExtent: 92),
            itemCount: shown.length,
            itemBuilder: (c, i) => _AppTile(hostId: widget.hostId, app: shown[i], onTap: () => launch(shown[i])),
          )),
        ];
      },
    );
  }
}

/// Session strip at the bottom: remaining time (every second), extend, stop.
class ControlBanner extends ConsumerStatefulWidget {
  const ControlBanner({super.key, required this.session, this.onStop});
  final ControlSession session;

  /// "Stop" (default: closes the control session; in a Claude chat it also stops Claude).
  final VoidCallback? onStop;
  @override
  ConsumerState<ControlBanner> createState() => _ControlBannerState();
}

class _ControlBannerState extends ConsumerState<ControlBanner> {
  Timer? _tick;
  late final AppLifecycleListener _life;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // If extended from the notification (in the background), the new end time is read from the stored record on resume.
    _life = AppLifecycleListener(onResume: () => unawaited(ref.read(controlProvider.notifier).syncStored()));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      if (!widget.session.expiresAt.isAfter(ref.read(clockProvider)())) {
        if (_checking) return;
        _checking = true;
        try {
          await ref.read(controlProvider.notifier).expireIfDue();
        } finally {
          _checking = false;
        }
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _life.dispose();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final left = widget.session.expiresAt.difference(ref.read(clockProvider)());
    final secs = left.isNegative ? 0 : left.inSeconds;
    final time = '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    final bg = t.isDark ? const Color(0xFFB3261E) : t.danger;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: bg,
        elevation: 6,
        shadowColor: const Color(0x55000000),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
          child: Row(children: [
            const StatusDot(color: Colors.white, size: 8),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l.desktopControlOn(time),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14.5, fontFeatures: [FontFeature.tabularFigures()]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: l.desktopControlExtend,
              icon: const Icon(LucideIcons.timerReset, color: Colors.white, size: 20),
              onPressed: () async {
                try {
                  await ref.read(controlProvider.notifier).extend();
                } catch (e) {
                  if (context.mounted) toast(context, agentErrorText(l, e));
                }
              },
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: bg, minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 16)),
              onPressed: widget.onStop ?? () => ref.read(controlProvider.notifier).stop(),
              child: Text(l.desktopControlStop, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _WorkspaceChip extends StatelessWidget {
  const _WorkspaceChip({required this.ws, required this.onTap});
  final DesktopWorkspace ws;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final sel = ws.focused;
    final fg = sel ? (t.isDark ? Colors.black : Colors.white) : t.text;
    return Semantics(
      button: true,
      selected: sel,
      label: '${l.desktopWorkspace(ws.name)}, ${l.desktopWindowCount(ws.windows)}',
      excludeSemantics: true,
      child: Material(
        color: sel ? (t.isDark ? t.tabActive : const Color(0xFF111114)) : t.chipBackground,
        shape: StadiumBorder(side: BorderSide(color: sel ? Colors.transparent : t.separator)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 56, minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(ws.name, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 15)),
                Text(l.desktopWindowCount(ws.windows), style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 11)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowCard extends ConsumerWidget {
  const _WindowCard({required this.hostId, required this.w, required this.onFocus, required this.onClose, required this.onMenu, this.thumbs = true, this.canClose = true});
  final String hostId;
  final DesktopWindow w;

  /// The backend makes window thumbnails (otherwise the app icon).
  final bool thumbs;

  /// Window actions (close by swipe) are available.
  final bool canClose;
  final VoidCallback onFocus;
  final Future<void> Function() onClose;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final thumb = w.visible && thumbs ? ref.watch(desktopThumbProvider((hostId, w.address))).value : null;
    final preview = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: t.isDark ? const Color(0xFF1C1C22) : const Color(0xFFEDEDF2),
        child: Stack(fit: StackFit.expand, children: [
          if (thumb != null)
            Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true, excludeFromSemantics: true)
          else
            Center(child: w.appId == null ? Icon(LucideIcons.appWindow, size: 34, color: t.textSecondary) : DesktopAppIcon(hostId: hostId, appId: w.appId!, size: 44)),
          Positioned(
            left: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(8)),
              child: Text(w.workspaceName, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
            ),
          ),
          if (w.pinned || w.floating || w.fullscreen)
            Positioned(
              right: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(8)),
                child: Icon(w.fullscreen ? LucideIcons.maximize : (w.pinned ? LucideIcons.pin : LucideIcons.pictureInPicture2), size: 13, color: Colors.white),
              ),
            ),
        ]),
      ),
    );
    return Dismissible(
      key: ValueKey('win-${w.address}'),
      direction: canClose ? DismissDirection.horizontal : DismissDirection.none,
      confirmDismiss: (_) async {
        await onClose();
        return false; // the card disappears by itself when the list refreshes
      },
      background: _SwipeBg(left: true, label: l.desktopCloseWindow),
      secondaryBackground: _SwipeBg(left: false, label: l.desktopCloseWindow),
      child: Semantics(
        label: [w.label, w.cls, l.desktopWorkspace(w.workspaceName), if (w.focused) l.desktopFocused].join(', '),
        hint: l.desktopWindowHint,
        button: true,
        excludeSemantics: true,
        customSemanticsActions: {
          if (canClose) CustomSemanticsAction(label: l.desktopCloseWindow): () => onClose(),
          CustomSemanticsAction(label: l.desktopWindowMenu): onMenu,
        },
        child: TCard(
          padding: const EdgeInsets.all(8),
          borderColor: w.focused ? t.accent : null,
          onTap: onFocus,
          child: GestureDetector(
            onLongPress: onMenu,
            behavior: HitTestBehavior.opaque,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: preview),
              const SizedBox(height: 8),
              Row(children: [
                if (w.focused) ...[StatusDot(color: t.accent, size: 7), const SizedBox(width: 6)],
                Expanded(
                  child: Text(w.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                ),
              ]),
              Text(w.cls, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SwipeBg extends StatelessWidget {
  const _SwipeBg({required this.left, required this.label});
  final bool left;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: context.tokens.danger, borderRadius: BorderRadius.circular(TiphysTokens.radiusCard)),
        alignment: left ? Alignment.centerLeft : Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Icon(LucideIcons.x, color: Colors.white, semanticLabel: label),
      );
}

/// App icon; if unavailable (SVG, not in theme) a generic window icon.
class DesktopAppIcon extends ConsumerWidget {
  const DesktopAppIcon({super.key, required this.hostId, required this.appId, this.size = 44});
  final String hostId;
  final String appId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final b = ref.watch(desktopIconProvider((hostId, appId))).value;
    if (b != null) return Image.memory(b, width: size, height: size, fit: BoxFit.contain, gaplessPlayback: true, excludeFromSemantics: true, filterQuality: FilterQuality.medium);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(size * 0.24), border: Border.all(color: t.separator)),
      child: Icon(LucideIcons.appWindow, size: size * 0.5, color: t.textSecondary),
    );
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({required this.hostId, required this.app, required this.onTap});
  final String hostId;
  final DesktopApp app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: app.name,
      hint: app.genericName,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
          child: Column(children: [
            app.hasIcon ? DesktopAppIcon(hostId: hostId, appId: app.id) : const _NoIcon(),
            const SizedBox(height: 6),
            Text(app.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, height: 1.2, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}

class _NoIcon extends StatelessWidget {
  const _NoIcon();
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(10.5), border: Border.all(color: t.separator)),
      child: Icon(LucideIcons.appWindow, size: 22, color: t.textSecondary),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ChoiceChip(
      selected: selected,
      showCheckmark: false,
      label: Text(label),
      onSelected: (_) => onTap(),
      selectedColor: t.isDark ? t.tabActive : const Color(0xFF111114),
      labelStyle: TextStyle(color: selected ? (t.isDark ? Colors.black : Colors.white) : t.text, fontWeight: FontWeight.w600),
      backgroundColor: t.chipBackground,
      side: BorderSide(color: t.separator),
      shape: const StadiumBorder(),
    );
  }
}

/// Media, clipboard, screenshot (existing tool screens) + screen off/on (DPMS) + sleep.
class _Tools extends ConsumerWidget {
  const _Tools({required this.hostId, required this.host, required this.controlOff, required this.powerOn, required this.caps});
  final String hostId;
  final Host host;
  final bool controlOff;
  final bool powerOn;
  final DesktopCaps caps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final screenOn = ref.watch(desktopStateProvider(hostId)).value?.screenOn ?? true;
    final browser = ref.watch(browserStatusProvider(hostId)).value;
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return GroupedSection(title: l.toolsTitle, children: [
      if (browser != null)
        GroupedRow(
          title: l.browserTitle,
          subtitle: browser.connected ? l.browserRowConnected : l.browserRowSetup,
          icon: LucideIcons.globe,
          iconBackground: const Color(0xFFE66000),
          onTap: () async {
            if (controlOff && browser.connected) return toast(context, l.desktopControlOffHint);
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BrowserTabsScreen(hostId: hostId)));
            ref.invalidate(browserStatusProvider(hostId));
          },
        ),
      GroupedRow(title: l.mediaTitle, icon: LucideIcons.music, iconBackground: const Color(0xFFFF375F), onTap: () => open(MediaScreen(hostId: hostId))),
      if (caps.has('clipboard')) GroupedRow(title: l.toolsClipboard, icon: LucideIcons.clipboard, iconBackground: const Color(0xFFBF5AF2), onTap: () => open(ClipboardScreen(host: host))),
      if (caps.has('screenshot')) GroupedRow(title: l.toolsScreenshot, icon: LucideIcons.monitor, iconBackground: const Color(0xFF30B0C7), onTap: () => open(ScreenshotScreen(host: host))),
      if (caps.has('sunshine'))
        GroupedRow(
          title: l.moonlightEntry,
          subtitle: l.moonlightSubtitle,
          icon: LucideIcons.gamepad2,
          iconBackground: const Color(0xFF5E5CE6),
          onTap: () => showMoonlightSheet(context, hostId),
        ),
      if (caps.has('dpms'))
        GroupedRow(
          title: screenOn ? l.desktopScreenOff : l.desktopScreenOn,
          icon: screenOn ? LucideIcons.monitorOff : LucideIcons.monitorCheck,
          iconBackground: const Color(0xFF636366),
          showChevron: false,
          onTap: () {
            if (controlOff) return toast(context, l.desktopControlOffHint);
            desktopAction(context, ref, hostId, '/v1/desktop/dpms/${screenOn ? 'off' : 'on'}');
          },
        ),
      if (powerOn)
        GroupedRow(
          title: l.systemSuspend,
          icon: LucideIcons.moon,
          iconBackground: const Color(0xFF5E5CE6),
          showChevron: false,
          onTap: () async {
            if (!await confirmDialog(context, message: l.systemPowerConfirm(l.systemSuspend, host.name), confirmLabel: l.systemSuspend, destructive: true)) return;
            try {
              await agentCall(ref, hostId, 'POST', '/v1/power/suspend', {'confirm': true});
              if (context.mounted) toast(context, l.systemPowerSent(l.systemSuspend));
            } catch (e) {
              if (context.mounted) toast(context, agentErrorText(l, e));
            }
          },
        ),
    ]);
  }
}

class _FeatureOff extends StatelessWidget {
  const _FeatureOff({required this.host});
  final Host? host;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TCard(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(LucideIcons.monitorOff, size: 32, color: t.textSecondary),
          const SizedBox(height: 10),
          Text(host?.agent == null ? l.hostAgentNone : l.desktopFeatureOff, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(l.desktopFeatureOffHint(host?.name ?? ''), style: TextStyle(color: t.textSecondary, height: 1.35)),
          if (host?.agent != null) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => context.push('/settings/hosts/agent?id=${host!.id}'),
              icon: const Icon(LucideIcons.slidersHorizontal, size: 18),
              label: Text(l.agentSettings),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.title});
  final IconData icon;
  final String? title;
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: t.textSecondary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (title != null) ...[Text(title!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)), const SizedBox(height: 3)],
              Text(text, style: TextStyle(color: t.textSecondary, height: 1.35)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.text, required this.onRetry});
  final String text;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => TCard(
        child: Row(children: [
          Icon(LucideIcons.circleAlert, color: context.tokens.danger),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
          TextButton(onPressed: onRetry, child: Text(AppLocalizations.of(context).commonRetry)),
        ]),
      );
}
