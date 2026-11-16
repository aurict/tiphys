// Firefox bridge screens (11.2, 11.3): tabs page (search, groups per window, active tab highlighted; tap = switch to
// the tab, swipe = close + "Undo", long press = multi-select + confirmed close, new tab, reopen closed, per-tab
// sheet: send to phone, reload, back/forward, pin, mute, reader view, page remote), bridge setup card, page
// content permission card, reader view (selectable text, font size, "Have Claude summarize") and page remote
// (media, scrolling, typing into the focused field). The tab list is live over SSE (see browser.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show claudeHostProvider, showNewSession;
import '../system/agent_providers.dart';
import 'browser.dart';
import 'desktop_data.dart';

const _base = '/v1/desktop/browser';

/// Command on the PC where the bridge is installed (the agent runs from source: systemd unit ~/Desktop/tiphys/agent).
const browserInstallCommand = 'cd ~/Desktop/tiphys/agent && node dist/cli.js firefox install';

void _push(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

/// Tabs page. [fromLive]: opened from the live screen → switching to a tab returns to the live screen.
class BrowserTabsScreen extends ConsumerStatefulWidget {
  const BrowserTabsScreen({super.key, required this.hostId, this.fromLive = false});
  final String hostId;
  final bool fromLive;
  @override
  ConsumerState<BrowserTabsScreen> createState() => _BrowserTabsScreenState();
}

class _BrowserTabsScreenState extends ConsumerState<BrowserTabsScreen> {
  late final BrowserTabsController _c;
  late final AppLifecycleListener _life;
  final _search = TextEditingController();
  final _selected = <int>{};
  bool _selecting = false;

  /// Open "reopen closed" notification: the root notification area outlives the screen; when the screen closes this
  /// notification is closed too (its action depends on the screen's context/ref).
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undo;

  @override
  void initState() {
    super.initState();
    _c = BrowserTabsController(
      client: () => ref.read(agentClientFactoryProvider)(ref.read(profileProvider).host(widget.hostId)!),
      token: () async => mounted ? (await ref.read(controlProvider.notifier).ensure(context, widget.hostId))?.token : null,
    )..addListener(_changed);
    _life = AppLifecycleListener(onStateChange: (s) {
      if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) _c.pause();
      if (s == AppLifecycleState.resumed) _c.resume();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.start());
  }

  void _changed() {
    if (!mounted) return;
    // Closed tabs drop out of the selection.
    final ids = {for (final t in _c.tabs ?? const <BrowserTab>[]) t.id};
    _selected.removeWhere((id) => !ids.contains(id));
    if (_selected.isEmpty) _selecting = false;
    setState(() {});
  }

  @override
  void dispose() {
    // Don't touch the notification area while the tree is locked; closing is deferred to the next microtask.
    if (_undo case final u?) scheduleMicrotask(u.close);
    _undo = null;
    _life.dispose();
    _c.removeListener(_changed);
    _c.dispose();
    _search.dispose();
    super.dispose();
  }

  String _path(int id, String action) => '$_base/tabs/$id/$action';

  Future<void> _activate(BrowserTab tab) async {
    final l = AppLocalizations.of(context);
    final r = await browserAction(context, ref, widget.hostId, _path(tab.id, 'activate'));
    if (r == null || !mounted) return;
    if (widget.fromLive) {
      Navigator.of(context).pop();
    } else {
      toast(context, l.browserActivated);
    }
  }

  /// Single tab: closes immediately; "Reopen closed" in the notification reopens the last closed tab in Firefox (the
  /// agent can't target a specific tab, hence the name isn't "undo"). Offered only while the screen is open. Multiple:
  /// confirm first.
  Future<void> _close(List<BrowserTab> tabs) async {
    final l = AppLocalizations.of(context);
    if (tabs.length > 1 && !await confirmDialog(context, message: l.browserCloseConfirm(tabs.length), confirmLabel: l.browserCloseTabs, destructive: true)) return;
    if (!mounted) return;
    final ids = [for (final t in tabs) t.id];
    _c.removeLocal(ids);
    _clearSelection();
    final r = await browserAction(context, ref, widget.hostId, '$_base/tabs/close', body: {'ids': ids});
    if (r == null) return _c.reload();
    if (!mounted || tabs.length > 1) return;
    final m = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final u = _undo = m.showSnackBar(SnackBar(
      content: Text(l.browserClosed),
      action: SnackBarAction(label: l.browserRestore, onPressed: () {
        if (mounted) browserAction(context, ref, widget.hostId, '$_base/restore', done: l.browserRestored);
      }),
    ));
    unawaited(u.closed.then((_) {
      if (identical(_undo, u)) _undo = null;
    }));
  }

  Future<void> _newTab() async {
    final l = AppLocalizations.of(context);
    final url = await showDialog<String>(context: context, builder: (_) => const _NewTabDialog());
    if (url == null || !mounted) return;
    final r = await browserAction(context, ref, widget.hostId, '$_base/tabs', body: {'url': url}, done: widget.fromLive ? null : l.browserOpened);
    if (r != null && widget.fromLive && mounted) Navigator.of(context).pop();
  }

  void _clearSelection() => setState(() {
        _selected.clear();
        _selecting = false;
      });

  void _toggle(BrowserTab t) => setState(() {
        if (!_selected.remove(t.id)) _selected.add(t.id);
        _selecting = _selected.isNotEmpty;
      });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final connected = _c.status?.connected == true && _c.error == null;
    final tabs = _c.tabs;
    final slivers = <Widget>[
      SliverAppBar(
        pinned: true,
        backgroundColor: t.isDark ? const Color(0xCC000000) : t.background,
        title: Text(_selecting ? l.browserSelected(_selected.length) : l.browserTabs),
        leading: _selecting
            ? IconButton(tooltip: l.commonCancel, icon: const Icon(LucideIcons.x), onPressed: _clearSelection)
            : IconButton(tooltip: MaterialLocalizations.of(context).backButtonTooltip, icon: const Icon(LucideIcons.chevronLeft), onPressed: () => Navigator.of(context).maybePop()),
        actions: [
          if (_selecting)
            IconButton(
              tooltip: l.browserCloseTabs,
              icon: Icon(LucideIcons.trash2, color: t.danger),
              onPressed: () => _close([for (final x in tabs ?? const <BrowserTab>[]) if (_selected.contains(x.id)) x]),
            )
          else if (connected) ...[
            IconButton(tooltip: l.browserRestore, icon: const Icon(LucideIcons.history), onPressed: () => browserAction(context, ref, widget.hostId, '$_base/restore', done: l.browserRestored)),
            IconButton(tooltip: l.remoteNewTab, icon: const Icon(LucideIcons.plus), onPressed: _newTab),
          ],
        ],
      ),
    ];
    Widget pad(Widget w) => SliverPadding(padding: const EdgeInsets.symmetric(horizontal: TiphysTokens.gutter), sliver: SliverToBoxAdapter(child: w));
    const spinner = SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())));

    if (_c.loading) {
      slivers.add(spinner);
    } else if (_c.cancelled) {
      slivers.add(pad(BrowserNote(icon: LucideIcons.lock, text: l.browserNeedsControl, onRetry: _c.start)));
    } else if (_c.error case final e?) {
      slivers.add(pad(BrowserNote(
        icon: LucideIcons.circleAlert,
        danger: true,
        text: e is AgentError && e.code == 'agent.control.sessionRequired' ? l.desktopControlEnded : agentErrorText(l, e),
        onRetry: _c.start,
      )));
    } else if (!connected) {
      slivers.add(pad(BrowserSetupCard(onRetry: _c.start)));
    } else if (tabs == null) {
      slivers.add(spinner);
    } else {
      final groups = groupTabs(tabs, _search.text);
      slivers.add(pad(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: l.browserSearch, prefixIcon: const Icon(LucideIcons.search, size: 18), isDense: true),
        ),
      )));
      if (tabs.isEmpty) {
        slivers.add(pad(BrowserNote(icon: LucideIcons.appWindow, text: l.browserNoTabs)));
      } else if (groups.isEmpty) {
        slivers.add(pad(BrowserNote(icon: LucideIcons.searchX, text: l.browserNoMatch)));
      }
      final windows = groupTabs(tabs).map((g) => g.$1).toList();
      for (final (win, list) in groups) {
        slivers.add(pad(SectionLabel('${l.browserWindow(windows.indexOf(win) + 1)} · ${l.browserTabCount(list.length)}')));
        slivers.add(pad(TCard(
          padding: EdgeInsets.zero,
          radius: TiphysTokens.radiusList,
          // Keep the background of the active/selected row and the scroll background from overflowing the card's corners.
          child: ClipRRect(
            borderRadius: BorderRadius.circular(TiphysTokens.radiusList),
            child: Column(children: [
              for (var i = 0; i < list.length; i++) ...[
                if (i > 0) Padding(padding: const EdgeInsets.only(left: 64), child: Divider(height: 1, color: t.separator)),
                _TabRow(
                  key: ValueKey('tab-${list[i].id}'),
                  tab: list[i],
                  selecting: _selecting,
                  selected: _selected.contains(list[i].id),
                  onTap: () => _selecting ? _toggle(list[i]) : _activate(list[i]),
                  onLongPress: () => _toggle(list[i]),
                  onMenu: () => _menu(list[i]),
                  onClose: () => _close([list[i]]),
                ),
              ],
            ]),
          ),
        )));
      }
      if (groups.isNotEmpty) {
        slivers.add(pad(Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 0), child: Text(l.browserTabsHint, style: Theme.of(context).textTheme.bodySmall))));
      }
    }
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 40)));
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(backgroundColor: Colors.transparent, body: AmbientBackground(child: CustomScrollView(slivers: slivers))),
    );
  }

  Future<void> _menu(BrowserTab tab) async {
    final l = AppLocalizations.of(context);
    final picked = await showBrowserTabSheet(context, tab);
    if (picked == null || !mounted) return;
    final content = _c.status?.content ?? false;
    switch (picked) {
      case 'activate':
        await _activate(tab);
      case 'phone':
        await openTabOnPhone(context, ref, tab);
      case 'reader':
        _push(context, BrowserReaderScreen(hostId: widget.hostId, tab: tab, content: content));
      case 'page':
        _push(context, BrowserPageScreen(hostId: widget.hostId, tab: tab, content: content));
      case 'close':
        await _close([tab]);
      case 'pin':
        await browserAction(context, ref, widget.hostId, _path(tab.id, 'pin'), done: tab.pinned ? l.browserUnpinned : l.browserPinned);
      case 'mute':
        await browserAction(context, ref, widget.hostId, _path(tab.id, 'mute'), done: tab.muted ? l.browserUnmuted : l.browserMutedDone);
      default: // reload, back, forward
        await browserAction(context, ref, widget.hostId, _path(tab.id, picked), done: l.browserSent);
    }
  }
}

/// Per-tab sheet; returns the selected action id.
Future<String?> showBrowserTabSheet(BuildContext context, BrowserTab tab) {
  final l = AppLocalizations.of(context);
  final t = context.tokens;
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) {
      Widget tile(String id, IconData icon, String title, {Color? color}) => ListTile(
            leading: Icon(icon, color: color),
            title: Text(title, style: color == null ? null : TextStyle(color: color)),
            minTileHeight: 48,
            onTap: () => Navigator.pop(c, id),
          );
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.8),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
              child: Text(tab.label, style: Theme.of(c).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            if (tab.domain.isNotEmpty)
              Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(tab.domain, style: Theme.of(c).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (!tab.active) tile('activate', LucideIcons.scanEye, l.browserActivate),
            if (tab.webUrl) tile('phone', LucideIcons.smartphone, l.browserToPhone),
            tile('reader', LucideIcons.bookOpen, l.browserReader),
            tile('page', LucideIcons.sliders, l.browserPageControls),
            tile('reload', LucideIcons.rotateCw, l.remoteReload),
            tile('back', LucideIcons.arrowLeft, l.remoteBack),
            tile('forward', LucideIcons.arrowRight, l.remoteForward),
            tile('pin', tab.pinned ? LucideIcons.pinOff : LucideIcons.pin, tab.pinned ? l.browserUnpin : l.browserPin),
            tile('mute', tab.muted ? LucideIcons.volume2 : LucideIcons.volumeX, tab.muted ? l.browserUnmute : l.browserMute),
            tile('close', LucideIcons.x, l.remoteCloseTab, color: t.danger),
          ]),
        ),
      );
    },
  );
}

class _TabRow extends StatelessWidget {
  const _TabRow({super.key, required this.tab, required this.selecting, required this.selected, required this.onTap, required this.onLongPress, required this.onMenu, required this.onClose});
  final BrowserTab tab;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMenu;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final states = [
      if (tab.active) l.browserActive,
      if (tab.pinned) l.browserPinnedBadge,
      if (tab.audible && !tab.muted) l.browserAudible,
      if (tab.muted) l.browserMutedBadge,
    ];
    final badge = <IconData>[
      if (tab.pinned) LucideIcons.pin,
      if (tab.audible && !tab.muted) LucideIcons.volume2,
      if (tab.muted) LucideIcons.volumeX,
    ];
    final row = Semantics(
      container: true,
      button: true,
      selected: selecting ? selected : tab.active,
      label: [tab.label, if (tab.domain.isNotEmpty) tab.domain, ...states].join(', '),
      hint: selecting ? l.browserSelectHint : l.browserTabHint,
      excludeSemantics: true,
      customSemanticsActions: {
        CustomSemanticsAction(label: l.remoteCloseTab): onClose,
        CustomSemanticsAction(label: l.browserTabMenu): onMenu,
        if (!selecting) CustomSemanticsAction(label: l.browserSelect): onLongPress,
      },
      child: Material(
        color: selected ? t.accent.withValues(alpha: 0.16) : (tab.active && !selecting ? t.accent.withValues(alpha: 0.07) : Colors.transparent),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
              child: Row(children: [
                SizedBox(
                  width: 36,
                  height: 36,
                  child: selecting
                      ? Icon(selected ? LucideIcons.circleCheck : LucideIcons.circle, color: selected ? t.accent : t.textSecondary, size: 26)
                      : TabAvatar(tab: tab),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(tab.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: tt.titleMedium?.copyWith(fontSize: 15, fontWeight: tab.active ? FontWeight.w700 : FontWeight.w500, height: 1.25)),
                    const SizedBox(height: 2),
                    Row(children: [
                      if (tab.active) ...[StatusDot(color: t.accent, size: 7), const SizedBox(width: 6)],
                      Expanded(child: Text(tab.domain.isEmpty ? (tab.url ?? '') : tab.domain, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall)),
                      for (final b in badge) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(b, size: 14, color: t.textSecondary)),
                    ]),
                  ]),
                ),
                if (!selecting)
                  IconButton(tooltip: l.browserTabMenu, icon: Icon(LucideIcons.ellipsisVertical, color: t.textSecondary, size: 20), onPressed: onMenu)
                else
                  const SizedBox(width: 12),
              ]),
            ),
          ),
        ),
      ),
    );
    if (selecting) return row;
    return Dismissible(
      key: ValueKey('dismiss-${tab.id}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => onClose(),
      background: _SwipeBg(left: true, label: l.remoteCloseTab),
      secondaryBackground: _SwipeBg(left: false, label: l.remoteCloseTab),
      child: row,
    );
  }
}

class _SwipeBg extends StatelessWidget {
  const _SwipeBg({required this.left, required this.label});
  final bool left;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        color: context.tokens.danger,
        alignment: left ? Alignment.centerLeft : Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: Icon(LucideIcons.x, color: Colors.white, semanticLabel: label),
      );
}

/// Favicon (`data:` PNG downscaled by the extension) or the domain's initial (color from the domain; AA with white text).
class TabAvatar extends StatelessWidget {
  const TabAvatar({super.key, required this.tab, this.size = 36});
  final BrowserTab tab;
  final double size;

  static const _colors = [Color(0xFF1D4ED8), Color(0xFFB3261E), Color(0xFF0F766E), Color(0xFF6D28D9), Color(0xFFB45309), Color(0xFFBE185D), Color(0xFF4338CA), Color(0xFF15803D)];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final f = tab.favicon;
    if (f != null) {
      return Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.17),
        decoration: BoxDecoration(color: t.isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7), borderRadius: BorderRadius.circular(size * 0.28)),
        child: Image.memory(f, fit: BoxFit.contain, gaplessPlayback: true, excludeFromSemantics: true, filterQuality: FilterQuality.medium),
      );
    }
    final key = tab.domain.isNotEmpty ? tab.domain : tab.label;
    final color = _colors[key.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff) % _colors.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.28)),
      child: Text(tab.letter, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.44)),
    );
  }
}

/// http/https URL (https:// is added if typed without a scheme); null if invalid.
String? normalizeTabUrl(String raw) {
  final s = raw.trim();
  if (s.isEmpty || RegExp(r'\s').hasMatch(s)) return null;
  final withScheme = s.contains('://') ? s : 'https://$s';
  final u = Uri.tryParse(withScheme);
  if (u == null || !(u.isScheme('http') || u.isScheme('https')) || u.host.isEmpty || u.host.startsWith('.')) return null;
  return u.toString();
}

class _NewTabDialog extends StatefulWidget {
  const _NewTabDialog();
  @override
  State<_NewTabDialog> createState() => _NewTabDialogState();
}

class _NewTabDialogState extends State<_NewTabDialog> {
  final _c = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _send() {
    final u = normalizeTabUrl(_c.text);
    if (u == null) return setState(() => _error = AppLocalizations.of(context).browserBadUrl);
    Navigator.pop(context, u);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.remoteNewTab),
      content: TextField(
        controller: _c,
        autofocus: true,
        autocorrect: false,
        keyboardType: TextInputType.url,
        maxLength: 4096,
        textInputAction: TextInputAction.go,
        decoration: InputDecoration(hintText: 'https://…', counterText: '', errorText: _error),
        onSubmitted: (_) => _send(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(onPressed: _send, child: Text(l.browserOpen)),
      ],
    );
  }
}

// ---- cards ----

/// Icon + text (+ optional "Try again") card.
class BrowserNote extends StatelessWidget {
  const BrowserNote({super.key, required this.icon, required this.text, this.title, this.onRetry, this.danger = false});
  final IconData icon;
  final String? title;
  final String text;
  final VoidCallback? onRetry;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: danger ? t.danger : t.textSecondary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (title != null) ...[Text(title!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)), const SizedBox(height: 3)],
                Text(text, style: TextStyle(color: t.textSecondary, height: 1.35)),
              ]),
            ),
          ]),
          if (onRetry != null) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: onRetry, child: Text(AppLocalizations.of(context).commonRetry))),
        ]),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text, this.copy = const []});
  final int n;
  final String text;

  /// Copyable snippets (command, about: URL, setting name).
  final List<String> copy;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: t.chipBackground, shape: BoxShape.circle, border: Border.all(color: t.separator)),
          child: Text('$n', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: const TextStyle(height: 1.35)),
            for (final c in copy)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Material(
                  color: t.isDark ? const Color(0xFF1C1C22) : const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(10),
                  child: Row(children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                        child: SelectableText(c, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.35)),
                      ),
                    ),
                    IconButton(
                      tooltip: '${l.commonCopy}: $c',
                      icon: const Icon(LucideIcons.copy, size: 18),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: c));
                        if (context.mounted) toast(context, l.commonCopied);
                      },
                    ),
                  ]),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Bridge not connected: setup steps on the PC (with copyable commands).
class BrowserSetupCard extends StatelessWidget {
  const BrowserSetupCard({super.key, this.onRetry});
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TCard(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(LucideIcons.unplug, color: t.textSecondary, size: 24),
            const SizedBox(width: 12),
            Expanded(child: Semantics(header: true, child: Text(l.browserSetupTitle, style: Theme.of(context).textTheme.titleMedium))),
          ]),
          const SizedBox(height: 6),
          Text(l.browserSetupIntro, style: TextStyle(color: t.textSecondary, height: 1.35)),
          _Step(n: 1, text: l.browserSetupStep1, copy: const [browserInstallCommand]),
          _Step(n: 2, text: l.browserSetupStep2, copy: const ['about:config', 'xpinstall.signatures.required']),
          _Step(n: 3, text: l.browserSetupStep3, copy: const ['about:addons']),
          _Step(n: 4, text: l.browserSetupStep4),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(LucideIcons.shieldAlert, size: 18, color: t.warning),
            const SizedBox(width: 8),
            Expanded(child: Text(l.browserSetupWarning, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.35))),
          ]),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: onRetry, icon: const Icon(LucideIcons.refreshCw, size: 18), label: Text(l.commonRetry))),
          ],
        ]),
      ),
    );
  }
}

/// Page content (11.3) permission not granted.
class BrowserPermissionCard extends StatelessWidget {
  const BrowserPermissionCard({super.key, this.onRetry});
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return BrowserNote(icon: LucideIcons.shieldQuestion, title: l.browserPermissionTitle, text: l.browserPermissionHint, onRetry: onRetry);
  }
}

// ---- reader view ----

class BrowserReaderScreen extends ConsumerStatefulWidget {
  const BrowserReaderScreen({super.key, required this.hostId, required this.tab, required this.content});
  final String hostId;
  final BrowserTab tab;

  /// Whether page content permission is granted, based on the status endpoint.
  final bool content;
  @override
  ConsumerState<BrowserReaderScreen> createState() => _BrowserReaderScreenState();
}

class _BrowserReaderScreenState extends ConsumerState<BrowserReaderScreen> {
  late bool _content = widget.content;
  Map? _article;
  Object? _error;
  bool _loading = false;
  double _font = 17;

  @override
  void initState() {
    super.initState();
    if (_content) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_content) _content = (await fetchBrowserStatus(ref, widget.hostId)).content;
      if (!mounted) return;
      if (_content) {
        final r = await browserRequest(context, ref, widget.hostId, 'GET', '$_base/tabs/${widget.tab.id}/reader');
        if (r == null) {
          if (mounted) Navigator.of(context).maybePop();
          return;
        }
        _article = r as Map;
      }
    } catch (e) {
      if (e is AgentError && e.code == 'agent.browser.permissionRequired') {
        _content = false;
      } else {
        _error = e;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _summarize() {
    final l = AppLocalizations.of(context);
    final a = _article;
    if (a == null) return;
    if (ref.read(claudeHostProvider) == null) return toast(context, l.dozzleNoClaudeHost);
    showNewSession(context, ref, prompt: browserSummaryPrompt(l, title: '${a['title'] ?? widget.tab.label}', url: widget.tab.url, text: '${a['text'] ?? ''}'));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final a = _article;
    final body = <Widget>[];
    if (_loading) {
      body.add(const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())));
    } else if (!_content) {
      body.add(BrowserPermissionCard(onRetry: _load));
    } else if (_error != null) {
      body.add(BrowserNote(icon: LucideIcons.bookX, text: agentErrorText(l, _error!), onRetry: _load));
    } else if (a != null) {
      final meta = [a['byline'], a['siteName'] ?? widget.tab.domain].whereType<String>().where((s) => s.trim().isNotEmpty).toSet().join(' · ');
      body.addAll([
        const SizedBox(height: 8),
        Semantics(header: true, child: Text('${a['title'] ?? widget.tab.label}', style: tt.headlineSmall?.copyWith(fontSize: _font + 7, fontWeight: FontWeight.w800, height: 1.25))),
        if (meta.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(meta, style: tt.bodyMedium?.copyWith(color: t.textSecondary))),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(onPressed: _summarize, icon: const Icon(LucideIcons.sparkles, size: 18), label: Text(l.browserSummarize)),
          ),
        ),
        if (a['truncated'] == true) Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.browserTruncated, style: tt.bodySmall)),
        for (final b in readerBlocks('${a['text'] ?? ''}')) _ReaderBlockView(block: b, font: _font),
      ]);
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: SelectionArea(
          child: CustomScrollView(slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: t.isDark ? const Color(0xCC000000) : t.background,
              title: Text(l.browserReader),
              leading: IconButton(tooltip: MaterialLocalizations.of(context).backButtonTooltip, icon: const Icon(LucideIcons.chevronLeft), onPressed: () => Navigator.of(context).maybePop()),
              actions: [
                if (a != null) ...[
                  IconButton(tooltip: l.browserFontSmaller, icon: const Icon(LucideIcons.aArrowDown), onPressed: _font <= 13 ? null : () => setState(() => _font -= 2)),
                  IconButton(tooltip: l.browserFontLarger, icon: const Icon(LucideIcons.aArrowUp), onPressed: _font >= 27 ? null : () => setState(() => _font += 2)),
                ],
              ],
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(TiphysTokens.gutter + 4, 0, TiphysTokens.gutter + 4, MediaQuery.paddingOf(context).bottom + 40),
              sliver: SliverList.list(children: body),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ReaderBlockView extends StatelessWidget {
  const _ReaderBlockView({required this.block, required this.font});
  final ReaderBlock block;
  final double font;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base = TextStyle(fontSize: font, height: 1.55, color: t.text);
    switch (block.kind) {
      case ReaderKind.heading:
        final scale = switch (block.level) { 1 => 1.4, 2 => 1.25, 3 => 1.12, _ => 1.0 };
        return Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 2),
          child: Semantics(header: true, child: Text(block.text, style: base.copyWith(fontSize: font * scale, fontWeight: FontWeight.w700, height: 1.3))),
        );
      case ReaderKind.bullet:
      case ReaderKind.numbered:
        return Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: font * 1.6, child: Text(block.kind == ReaderKind.bullet ? '•' : block.marker, style: base.copyWith(color: t.textSecondary))),
            Expanded(child: Text(block.text, style: base)),
          ]),
        );
      case ReaderKind.paragraph:
        return Padding(padding: const EdgeInsets.only(top: 12), child: Text(block.text, style: base));
    }
  }
}

// ---- page remote ----

class BrowserPageScreen extends ConsumerStatefulWidget {
  const BrowserPageScreen({super.key, required this.hostId, required this.tab, required this.content});
  final String hostId;
  final BrowserTab tab;
  final bool content;
  @override
  ConsumerState<BrowserPageScreen> createState() => _BrowserPageScreenState();
}

class _BrowserPageScreenState extends ConsumerState<BrowserPageScreen> {
  late bool _content = widget.content;
  Map? _media;
  int? _percent;
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _tab => '$_base/tabs/${widget.tab.id}';

  /// Page action; a permission error opens a card, others a short notification.
  Future<Map?> _call(String op, Map<String, Object> body) async {
    final l = AppLocalizations.of(context);
    try {
      final r = await browserRequest(context, ref, widget.hostId, 'POST', '$_tab/$op', body);
      return r is Map ? r : null;
    } catch (e) {
      if (e is AgentError && e.code == 'agent.browser.permissionRequired') {
        if (mounted) setState(() => _content = false);
      } else if (mounted) {
        toast(context, agentErrorText(l, e));
      }
      return null;
    }
  }

  Future<void> _mediaAct(String action, {double? seconds, double? rate}) async {
    final r = await _call('media', {'action': action, 'seconds': ?seconds, 'rate': ?rate});
    if (r != null && mounted) setState(() => _media = r);
  }

  Future<void> _scroll(double f) async {
    final r = await _call('scroll', {'fraction': f});
    if (r != null && mounted) setState(() => _percent = (r['percent'] as num?)?.toInt());
  }

  Future<void> _send() async {
    final l = AppLocalizations.of(context);
    final s = _text.text;
    if (s.isEmpty) return;
    final r = await _call('text', {'text': s});
    if (r != null && mounted) {
      _text.clear();
      toast(context, l.browserTextSent);
    }
  }

  Future<void> _retry() async {
    final l = AppLocalizations.of(context);
    try {
      final s = await fetchBrowserStatus(ref, widget.hostId);
      if (mounted) setState(() => _content = s.content);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: l.browserPageControls,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Row(children: [
            TabAvatar(tab: widget.tab, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.tab.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium)),
          ]),
        ),
        if (!_content)
          BrowserPermissionCard(onRetry: _retry)
        else ...[
          SectionLabel(l.browserMediaTitle),
          BrowserMediaCard(state: _media, onAction: _mediaAct),
          SectionLabel(l.browserScrollTitle),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_percent != null) ...[
                Semantics(
                  label: l.browserScrollPercent(_percent!),
                  child: ExcludeSemantics(
                    child: Row(children: [
                      Expanded(child: LinearProgressIndicator(value: _percent! / 100, minHeight: 6, borderRadius: BorderRadius.circular(3))),
                      const SizedBox(width: 10),
                      Text('%$_percent', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Wrap(alignment: WrapAlignment.spaceEvenly, spacing: 4, runSpacing: 4, children: [
                IconButton(tooltip: l.remoteTop, icon: const Icon(LucideIcons.arrowUpToLine), onPressed: () => _scroll(-10)),
                IconButton(tooltip: l.remoteScrollUp, icon: const Icon(LucideIcons.arrowUp), onPressed: () => _scroll(-0.85)),
                IconButton(tooltip: l.remoteScrollDown, icon: const Icon(LucideIcons.arrowDown), onPressed: () => _scroll(0.85)),
                IconButton(tooltip: l.browserBottom, icon: const Icon(LucideIcons.arrowDownToLine), onPressed: () => _scroll(10)),
              ]),
            ]),
          ),
          SectionLabel(l.browserTextTitle),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: _text,
                minLines: 1,
                maxLines: 5,
                maxLength: 10000,
                decoration: InputDecoration(hintText: l.browserTextHint, counterText: ''),
              ),
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: _send, icon: const Icon(LucideIcons.send, size: 18), label: Text(l.remoteSend))),
            ]),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 0), child: Text(l.browserPageHint, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ],
    );
  }
}

/// Video/audio on the page: play/pause, ±10 s, speed. [state]: the last action's response (kind, paused, currentTime,
/// duration, rate); null if none yet.
class BrowserMediaCard extends StatelessWidget {
  const BrowserMediaCard({super.key, required this.state, required this.onAction});
  final Map? state;
  final Future<void> Function(String action, {double? seconds, double? rate}) onAction;

  static const rates = [0.5, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = state;
    final paused = s?['paused'] != false;
    final rate = (s?['rate'] as num?)?.toDouble();
    String time(Object? v) {
      final n = (v as num?)?.round();
      if (n == null) return '–';
      return '${n ~/ 60}:${(n % 60).toString().padLeft(2, '0')}';
    }

    return TCard(
      child: Column(children: [
        Text(
          s == null ? l.browserMediaHint : '${s['kind'] == 'audio' ? l.browserMediaAudio : l.browserMediaVideo} · ${time(s['currentTime'])} / ${time(s['duration'])}',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton(tooltip: l.mediaBack10, iconSize: 28, icon: const Icon(LucideIcons.rotateCcw), onPressed: () => onAction('seek', seconds: -10)),
          Semantics(
            container: true,
            button: true,
            label: s == null ? '${l.mediaPlay} / ${l.mediaPause}' : (paused ? l.mediaPlay : l.mediaPause),
            excludeSemantics: true,
            child: Material(
              color: t.isDark ? t.tabActive : const Color(0xFF111114),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => onAction('toggle'),
                child: SizedBox(width: 60, height: 60, child: Icon(paused ? LucideIcons.play : LucideIcons.pause, size: 26, color: t.isDark ? Colors.black : Colors.white)),
              ),
            ),
          ),
          IconButton(tooltip: l.mediaForward10, iconSize: 28, icon: const Icon(LucideIcons.rotateCw), onPressed: () => onAction('seek', seconds: 10)),
        ]),
        const SizedBox(height: 8),
        Semantics(
          label: l.browserRate,
          container: true,
          child: Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 6, children: [
            for (final r in rates)
              ChoiceChip(
                label: Text('${r == r.roundToDouble() ? r.toStringAsFixed(0) : '$r'}×'),
                selected: rate == r,
                showCheckmark: false,
                onSelected: (_) => onAction('rate', rate: r),
              ),
          ]),
        ),
      ]),
    );
  }
}
