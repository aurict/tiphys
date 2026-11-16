// Mobile view screen (11.4): the focused window's accessibility tree with real widgets on the phone — a small preview
// on top (same stream if opened from the live screen, a thumbnail every 5 s if opened from the panel), search, tool/menu
// bars as horizontal chips, open menus as cards, tabs as a segmented control, fields as TextField (send = /text; a
// password field starts empty and asks for confirmation before sending), slider/spinner (/value), list rows (select),
// links, headings/labels as context text, web page content as a separate section. Long press = context actions (the
// widget's actions + focus). For apps that expose no tree, the live screen + remote strip is suggested. If opened from
// the live screen, the view follows when focus moves to another window. On exit the agent is told to close the view.
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
import '../system/agent_providers.dart';
import 'browser_screen.dart' show BrowserNote;
import 'desktop_data.dart';
import 'live_screen.dart';
import 'live_stream.dart';
import 'mobile_view.dart';

/// Opens the mobile view. [live]: opened from the live screen (preview from the same stream, follows focus; "live
/// screen" goes back).
Future<void> openMobileView(BuildContext context, String hostId, {required String address, String? title, LiveController? live}) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(
      builder: (_) => MobileViewScreen(hostId: hostId, address: address, title: title, live: live),
    ));

class MobileViewScreen extends ConsumerStatefulWidget {
  const MobileViewScreen({super.key, required this.hostId, required this.address, this.title, this.live});
  final String hostId;
  final String address;
  final String? title;
  final LiveController? live;
  @override
  ConsumerState<MobileViewScreen> createState() => _MobileViewScreenState();
}

class _MobileViewScreenState extends ConsumerState<MobileViewScreen> {
  late final UiViewController _c;
  late final AppLifecycleListener _life;
  final _search = TextEditingController();
  bool _preview = true;

  /// Last drawn window: search is cleared when it changes (the old window's filter is meaningless in the new window).
  late String _shown = widget.address;

  @override
  void initState() {
    super.initState();
    final factory = ref.read(agentClientFactoryProvider);
    final host = ref.read(profileProvider).host(widget.hostId)!;
    _c = UiViewController(
      client: () => factory(host),
      token: () async => mounted ? (await ref.read(controlProvider.notifier).ensure(context, widget.hostId))?.token : null,
      address: widget.address,
    )..addListener(_changed);
    widget.live?.addListener(_onLive);
    _life = AppLifecycleListener(onStateChange: (s) {
      if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) _c.pause();
      if (s == AppLifecycleState.resumed) _c.resume();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.start());
  }

  void _changed() {
    if (_c.address != _shown) {
      _shown = _c.address;
      _search.clear();
    }
    if (mounted) setState(() {});
  }

  void _onLive() {
    final a = widget.live?.focus?.address;
    if (a != null && a.isNotEmpty) _c.follow(a);
  }

  @override
  void dispose() {
    _life.dispose();
    widget.live?.removeListener(_onLive);
    _c.removeListener(_changed);
    _c.dispose();
    _search.dispose();
    super.dispose();
  }

  String get _title {
    final f = widget.live?.focus;
    final s = _c.snap?.title ?? '';
    return s.isNotEmpty ? s : (f?.address == _c.address && (f?.title ?? '').isNotEmpty ? f!.title : (widget.title ?? ''));
  }

  void _toLive() {
    if (widget.live != null) {
      Navigator.of(context).pop();
    } else {
      unawaited(openLiveScreen(context, widget.hostId, window: _c.address, title: _title));
    }
  }

  /// Sends the action; errors are shown in a short notification.
  Future<bool> _send(UiNode n, String kind, Map<String, Object?> body) async {
    final l = AppLocalizations.of(context);
    HapticFeedback.selectionClick();
    try {
      await _c.send(n, kind, body);
      return true;
    } catch (e) {
      if (mounted) toast(context, e is AgentError && e.code == 'agent.control.sessionRequired' ? l.desktopControlEnded : agentErrorText(l, e));
      return false;
    }
  }

  /// Tap: with no action, a selectable row gets selected; otherwise the default (first) action.
  Future<void> _press(UiNode n) =>
      _send(n, 'act', n.actions.isEmpty && n.selectable ? {'op': 'select'} : {'action': n.actions.isEmpty ? 'click' : n.actions.first});

  /// Text into a field; confirmation first for a password field. True if sent.
  Future<bool> _setText(UiNode n, String text) async {
    final l = AppLocalizations.of(context);
    if (n.password && !await confirmDialog(context, message: l.uiPasswordConfirm(n.label.isEmpty ? l.uiPasswordSend : n.label), confirmLabel: l.uiPasswordSend)) return false;
    if (!mounted || !await _send(n, 'text', {'text': text, if (n.password) 'confirm': true})) return false;
    if (mounted) toast(context, l.browserSent);
    return true;
  }

  Future<void> _menu(UiNode n) async {
    final l = AppLocalizations.of(context);
    HapticFeedback.mediumImpact();
    final picked = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) {
        Widget tile(IconData icon, String title, Map<String, Object?> body) =>
            ListTile(leading: Icon(icon), title: Text(title), minTileHeight: 48, onTap: () => Navigator.pop(c, body));
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
                child: Text(n.label.isEmpty ? l.uiUnnamed : n.label, style: Theme.of(c).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(n.role, style: Theme.of(c).textTheme.bodySmall)),
              for (final a in n.actions) tile(LucideIcons.pointer, uiActionLabel(l, a), {'action': a}),
              if (n.selectable) tile(LucideIcons.circleCheck, l.uiSelect, {'op': 'select'}),
              tile(LucideIcons.focus, l.uiFocus, {'op': 'focus'}),
            ]),
          ),
        );
      },
    );
    if (picked != null && mounted) await _send(n, 'act', picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final snap = _c.snap;
    final slivers = <Widget>[
      SliverAppBar(
        pinned: true,
        backgroundColor: t.isDark ? Colors.black : t.background,
        leading: IconButton(tooltip: MaterialLocalizations.of(context).backButtonTooltip, icon: const Icon(LucideIcons.chevronLeft), onPressed: () => Navigator.of(context).maybePop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.uiTitle),
          if (_title.isNotEmpty) Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          IconButton(
            tooltip: _preview ? l.uiHidePreview : l.uiShowPreview,
            isSelected: _preview,
            icon: const Icon(LucideIcons.eyeOff),
            selectedIcon: const Icon(LucideIcons.eye),
            onPressed: () => setState(() => _preview = !_preview),
          ),
          IconButton(tooltip: l.uiOpenLive, icon: const Icon(LucideIcons.monitorPlay), onPressed: _toLive),
          IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.rotateCw), onPressed: _c.refresh),
        ],
      ),
    ];
    Widget pad(Widget w) => SliverPadding(padding: const EdgeInsets.symmetric(horizontal: TiphysTokens.gutter), sliver: SliverToBoxAdapter(child: w));
    const spinner = SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())));
    if (_preview) slivers.add(pad(_Preview(hostId: widget.hostId, address: _c.address, live: widget.live)));

    if (_c.loading) {
      slivers.add(spinner);
    } else if (_c.cancelled) {
      slivers.add(pad(BrowserNote(icon: LucideIcons.lock, text: l.uiNeedsControl, onRetry: _c.start)));
    } else if (_c.error case final e?) {
      final code = e is AgentError ? e.code : '';
      slivers.add(pad(switch (code) {
        'agent.ui.unsupported' => _UnsupportedCard(onLive: _toLive),
        'agent.ui.helperMissing' => BrowserNote(icon: LucideIcons.packageX, title: l.uiHelperMissingTitle, text: l.uiHelperMissingText, onRetry: _c.start),
        'agent.control.sessionRequired' => BrowserNote(icon: LucideIcons.circleAlert, danger: true, text: l.desktopControlEnded, onRetry: _c.start),
        _ => BrowserNote(icon: LucideIcons.circleAlert, danger: true, text: agentErrorText(l, e), onRetry: _c.start),
      }));
    } else if (snap != null) {
      final sections = uiSections(snap, query: _search.text);
      slivers.add(pad(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: l.uiSearch, prefixIcon: const Icon(LucideIcons.search, size: 18), isDense: true),
        ),
      )));
      if (snap.partial) slivers.add(pad(_Banner(text: l.uiPartial)));
      if (sections.isEmpty) slivers.add(pad(BrowserNote(icon: _search.text.trim().isEmpty ? LucideIcons.appWindow : LucideIcons.searchX, text: _search.text.trim().isEmpty ? l.uiEmpty : l.uiNoMatch)));
      final actions = _Actions(press: _press, menu: _menu, setText: _setText, setValue: (n, v) => _send(n, 'value', {'value': v}), entryOf: snap.entryOf);
      slivers.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: TiphysTokens.gutter),
        sliver: SliverList.builder(
          itemCount: sections.length,
          itemBuilder: (c, i) => _SectionView(key: ValueKey('${snap.address}/${sections[i].kind.name}/${sections[i].node?.id ?? sections[i].items.firstOrNull?.id ?? i}'), section: sections[i], actions: actions),
        ),
      ));
    }
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 40)));
    return Scaffold(backgroundColor: Colors.transparent, body: AmbientBackground(child: CustomScrollView(slivers: slivers)));
  }
}

/// Action name in the context menu (AT-SPI names are translated; unknown names as is).
String uiActionLabel(AppLocalizations l, String a) => switch (a.toLowerCase()) {
      'click' => l.uiActClick,
      'press' => l.uiActPress,
      'activate' => l.uiActActivate,
      'toggle' => l.uiActToggle,
      'jump' => l.uiActJump,
      'expand or contract' || 'expand' || 'collapse' => l.uiActExpand,
      'switch' => l.uiActSwitch,
      'open' => l.uiActOpen,
      _ => a,
    };

class _Actions {
  const _Actions({required this.press, required this.menu, required this.setText, required this.setValue, required this.entryOf});
  final Future<void> Function(UiNode) press;
  final Future<void> Function(UiNode) menu;
  final Future<bool> Function(UiNode, String) setText;
  final Future<void> Function(UiNode, double) setValue;

  /// Text field of a combo box (address bar); otherwise null.
  final UiNode? Function(UiNode combo) entryOf;
}

class _Preview extends ConsumerWidget {
  const _Preview({required this.hostId, required this.address, this.live});
  final String hostId;
  final String address;
  final LiveController? live;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = live;
    final Widget body;
    if (c != null) {
      body = IgnorePointer(child: ListenableBuilder(listenable: c, builder: (_, _) => LiveCanvas(live: c, touchpad: false)));
    } else {
      final b = ref.watch(desktopThumbProvider((hostId, address))).value;
      body = b == null ? const Center(child: Icon(LucideIcons.appWindow, color: Color(0xFF8E8E93), size: 32)) : Image.memory(b, fit: BoxFit.contain, gaplessPlayback: true);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Semantics(
        image: true,
        label: l.uiPreview,
        excludeSemantics: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ColoredBox(color: Colors.black, child: SizedBox(height: 150, width: double.infinity, child: body)),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(color: t.warning.withValues(alpha: t.isDark ? 0.18 : 0.14), borderRadius: BorderRadius.circular(14)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(LucideIcons.triangleAlert, size: 18, color: t.isDark ? t.warning : const Color(0xFF8A5300)),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(color: t.text, height: 1.35, fontSize: 13.5))),
          ]),
        ),
      ),
    );
  }
}

class _UnsupportedCard extends StatelessWidget {
  const _UnsupportedCard({required this.onLive});
  final VoidCallback onLive;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(LucideIcons.squareDashedMousePointer, color: t.textSecondary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.uiUnsupportedTitle, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 3),
                Text(l.uiUnsupportedText, style: TextStyle(color: t.textSecondary, height: 1.35)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(onPressed: onLive, icon: const Icon(LucideIcons.monitorPlay, size: 18), label: Text(l.uiOpenLive), style: FilledButton.styleFrom(minimumSize: const Size(44, 48))),
          ),
        ]),
      ),
    );
  }
}

// ---- sections ----

class _SectionView extends StatelessWidget {
  const _SectionView({super.key, required this.section, required this.actions});
  final UiSection section;
  final _Actions actions;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = section;
    Widget card(List<UiNode> items, {int base = 0}) => TCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          radius: TiphysTokens.radiusList,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final n in items) _NodeView(key: ValueKey(n.id), node: n, actions: actions, indent: (n.depth - base).clamp(0, 4)),
          ]),
        );
    switch (s.kind) {
      case UiSectionKind.bar:
        final title = s.title.isNotEmpty ? s.title : (s.node?.role == 'menu bar' ? l.uiMenuBar : l.uiToolbar);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionLabel(title),
          if (s.chips.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [for (final n in s.chips) Padding(padding: const EdgeInsets.only(right: 8), child: _NodeChip(node: n, actions: actions))]),
            ),
          if (s.items.isNotEmpty) ...[const SizedBox(height: 10), card(s.items, base: s.items.first.depth)],
        ]);
      case UiSectionKind.menu:
        final m = s.node!;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TCard(
            padding: const EdgeInsets.only(bottom: 4),
            radius: TiphysTokens.radiusList,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _NodeView(node: m, actions: actions, header: true),
              Divider(height: 1, color: context.tokens.separator),
              for (final n in s.items) _NodeView(key: ValueKey(n.id), node: n, actions: actions, indent: (n.depth - m.depth - 1).clamp(0, 4)),
            ]),
          ),
        );
      case UiSectionKind.tabs:
        final sel = s.chips.where((n) => n.selected).firstOrNull;
        return Padding(
          padding: const EdgeInsets.only(top: 14),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: [
                for (final (i, n) in s.chips.indexed)
                  ButtonSegment(value: n.id, enabled: n.enabled, label: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 160), child: Text(n.label.isEmpty ? l.uiTab(i + 1) : n.label, maxLines: 1, overflow: TextOverflow.ellipsis))),
              ],
              selected: {?sel?.id},
              onSelectionChanged: (v) {
                if (v.isEmpty) return;
                actions.press(s.chips.firstWhere((n) => n.id == v.first));
              },
            ),
          ),
        );
      case UiSectionKind.document:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionLabel(s.title.isEmpty ? l.uiWebContent : '${l.uiWebContent} · ${s.title}'),
          card(s.items, base: s.node!.depth + 1),
        ]);
      case UiSectionKind.group:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (s.title.isNotEmpty) SectionLabel(s.title) else const SizedBox(height: 12),
          card(s.items, base: s.items.first.depth),
        ]);
    }
  }
}

IconData _roleIcon(String role) => switch (role) {
      'menu' || 'push button menu' => LucideIcons.chevronDown,
      'link' => LucideIcons.link,
      'combo box' => LucideIcons.chevronsUpDown,
      'toggle button' || 'switch' => LucideIcons.toggleRight,
      'check box' || 'check menu item' => LucideIcons.squareCheck,
      'radio button' || 'radio menu item' => LucideIcons.circleDot,
      'page tab' => LucideIcons.panelTop,
      _ => LucideIcons.pointer,
    };

/// Chip in a bar (button, toggle, menu). Pressed/checked toggles are highlighted.
class _NodeChip extends StatelessWidget {
  const _NodeChip({required this.node, required this.actions});
  final UiNode node;
  final _Actions actions;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final n = node;
    final on = n.checked || n.expanded || n.selected;
    final label = n.label.isEmpty ? l.uiUnnamed : n.label;
    final fg = !n.enabled ? t.textSecondary : (on ? t.onAccent : t.text);
    return Semantics(
      button: true,
      enabled: n.enabled,
      toggled: const {'toggle button', 'switch', 'check box'}.contains(n.role) ? n.checked : null,
      expanded: n.role == 'menu' ? n.expanded : null,
      label: label,
      onTap: n.enabled ? () => actions.press(n) : null,
      onLongPress: () => actions.menu(n),
      onLongPressHint: l.uiMoreActions,
      excludeSemantics: true,
      child: Material(
        color: on ? t.accent : t.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: on ? BorderSide.none : BorderSide(color: t.separator)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          focusColor: t.accent.withValues(alpha: 0.24),
          onTap: n.enabled ? () => actions.press(n) : null,
          onLongPress: () => actions.menu(n),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44, maxWidth: 220),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (n.role != 'button' && n.role != 'push button') ...[Icon(_roleIcon(n.role), size: 15, color: fg), const SizedBox(width: 6)],
                Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14))),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Single widget inside a card: by role a row, toggle, checkbox, field, slider, spinner, link or context text.
class _NodeView extends StatelessWidget {
  const _NodeView({super.key, required this.node, required this.actions, this.indent = 0, this.header = false});
  final UiNode node;
  final _Actions actions;
  final int indent;

  /// Heading of an open menu.
  final bool header;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final n = node;
    final label = n.label.isEmpty ? l.uiUnnamed : n.label;
    final left = 16.0 + indent * 16;
    final more = {CustomSemanticsAction(label: l.uiMoreActions): () => actions.menu(n)};
    final tap = n.enabled ? () => actions.press(n) : null;
    final title = Text(label, maxLines: 2, overflow: TextOverflow.ellipsis);

    if (header) {
      return Semantics(
        header: true,
        expanded: true,
        child: ListTile(
          contentPadding: EdgeInsets.only(left: left, right: 12),
          minTileHeight: 52,
          leading: Icon(LucideIcons.menu, color: t.accent, size: 20),
          title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          trailing: const Icon(LucideIcons.chevronUp, size: 18),
          onTap: tap,
          onLongPress: () => actions.menu(n),
        ),
      );
    }
    switch (n.role) {
      case 'label':
        return Padding(
          padding: EdgeInsets.fromLTRB(left, 8, 16, 4),
          child: Text(n.label, style: tt.bodySmall?.copyWith(color: t.textSecondary)),
        );
      case 'heading':
        return Semantics(
          header: true,
          child: Padding(padding: EdgeInsets.fromLTRB(left, 12, 16, 4), child: Text(n.label, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
        );
      case 'entry' || 'text' || 'password text':
        return _TextNode(key: _textKey(n), node: n, label: n.label, onSend: (v) => actions.setText(n, v), indent: left);
      case 'combo box':
        final entry = actions.entryOf(n);
        if (entry != null) return _TextNode(key: _textKey(entry), node: entry, label: n.label.isNotEmpty ? n.label : entry.label, onSend: (v) => actions.setText(entry, v), indent: left);
      case 'slider' || 'spin button' when n.value != null:
        return _ValueNode(key: ValueKey('v${n.id}'), node: n, onSet: (v) => actions.setValue(n, v), indent: left);
    }
    final Widget? leading;
    Widget? trailing;
    var style = TextStyle(color: n.enabled ? t.text : t.textSecondary);
    switch (n.role) {
      case 'toggle button' || 'switch':
        leading = null;
        trailing = ExcludeSemantics(child: Switch(value: n.checked, onChanged: tap == null ? null : (_) => tap()));
      case 'check box' || 'check menu item':
        leading = ExcludeSemantics(child: Checkbox(value: n.checked, onChanged: tap == null ? null : (_) => tap()));
      case 'radio button' || 'radio menu item':
        leading = Icon(n.checked ? LucideIcons.circleDot : LucideIcons.circle, color: n.checked ? t.accent : t.textSecondary, size: 20);
      case 'link':
        leading = Icon(LucideIcons.link, color: t.accent, size: 18);
        style = style.copyWith(color: n.enabled ? t.accent : t.textSecondary, decoration: TextDecoration.underline, decorationColor: t.accent);
      case 'menu':
        leading = null;
        trailing = Icon(LucideIcons.chevronRight, size: 18, color: t.textSecondary);
      case 'list item' || 'tree item' || 'table cell':
        leading = n.role == 'tree item' ? Icon(n.expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 16, color: t.textSecondary) : null;
      case 'menu item':
        leading = null;
      default:
        // Buttons (and other pressable ones): with the accent color.
        leading = Icon(_roleIcon(n.role), color: n.enabled ? t.accent : t.textSecondary, size: 18);
        style = style.copyWith(color: n.enabled ? t.accent : t.textSecondary, fontWeight: FontWeight.w600);
    }
    final desc = n.desc.isNotEmpty && n.desc != n.name ? n.desc : null;
    return Semantics(
      checked: const {'check box', 'check menu item'}.contains(n.role) ? n.checked : null,
      toggled: const {'toggle button', 'switch'}.contains(n.role) ? n.checked : null,
      inMutuallyExclusiveGroup: n.role.startsWith('radio') ? true : null,
      expanded: n.role == 'tree item' ? n.expanded : null,
      selected: n.selectable ? n.selected : null,
      link: n.role == 'link' ? true : null,
      customSemanticsActions: more,
      child: Material(
        color: n.selected ? t.accent.withValues(alpha: 0.12) : Colors.transparent,
        child: ListTile(
          contentPadding: EdgeInsets.only(left: left, right: 12),
          minTileHeight: 48,
          enabled: n.enabled,
          leading: leading,
          title: DefaultTextStyle.merge(style: style, child: title),
          subtitle: desc == null ? null : Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: trailing,
          onTap: tap,
          onLongPress: () => actions.menu(n),
        ),
      ),
    );
  }
}

/// Field identity: window + path + role + name. If a sibling is added and the path shifts to another field, the
/// identity changes → new state, the draft is discarded (typed text doesn't go to another field). Generation isn't
/// in the key, so the draft isn't lost on every refresh; sending uses the node's own generation anyway.
Key _textKey(UiNode n) => ValueKey(('t', n.address, n.id, n.role, n.name));

/// Editable field: send (keyboard "send" or button) → /text. A password field is never prefilled, typed obscured,
/// asks for confirmation before sending and is cleared after sending. If the text on the PC changes while not
/// focused, the field updates.
class _TextNode extends StatefulWidget {
  const _TextNode({super.key, required this.node, required this.label, required this.onSend, required this.indent});
  final UiNode node;
  final String label;
  final Future<bool> Function(String) onSend;
  final double indent;
  @override
  State<_TextNode> createState() => _TextNodeState();
}

class _TextNodeState extends State<_TextNode> {
  late final _c = TextEditingController(text: widget.node.password ? '' : (widget.node.text ?? ''));
  final _focus = FocusNode();

  @override
  void didUpdateWidget(_TextNode old) {
    super.didUpdateWidget(old);
    final t = widget.node.text;
    if (!widget.node.password && t != null && t != old.node.text && !_focus.hasFocus) _c.text = t;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (await widget.onSend(_c.text) && widget.node.password && mounted) _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final n = widget.node;
    final multi = n.role == 'text';
    return Padding(
      padding: EdgeInsets.fromLTRB(widget.indent, 8, 12, 8),
      child: TextField(
        controller: _c,
        focusNode: _focus,
        enabled: n.enabled,
        obscureText: n.password,
        autocorrect: !n.password,
        enableSuggestions: !n.password,
        maxLength: 2000,
        minLines: 1,
        maxLines: multi ? 6 : 1,
        keyboardType: multi ? TextInputType.multiline : TextInputType.text,
        textInputAction: multi ? TextInputAction.newline : TextInputAction.send,
        onSubmitted: multi ? null : (_) => _send(),
        decoration: InputDecoration(
          labelText: widget.label.isEmpty ? (n.password ? l.uiPasswordSend : l.uiField) : widget.label,
          helperText: n.password ? l.uiPasswordHint : null,
          helperMaxLines: 2,
          prefixIcon: n.password ? const Icon(LucideIcons.keyRound, size: 18) : null,
          counterText: '',
          suffixIcon: IconButton(tooltip: n.password ? l.uiPasswordSend : l.remoteSend, icon: const Icon(LucideIcons.sendHorizontal, size: 18), onPressed: n.enabled ? _send : null),
        ),
      ),
    );
  }
}

/// Slider (sends on release) or spinner (− / +, by step).
class _ValueNode extends StatefulWidget {
  const _ValueNode({super.key, required this.node, required this.onSet, required this.indent});
  final UiNode node;
  final Future<void> Function(double) onSet;
  final double indent;
  @override
  State<_ValueNode> createState() => _ValueNodeState();
}

class _ValueNodeState extends State<_ValueNode> {
  double? _drag;

  @override
  void didUpdateWidget(_ValueNode old) {
    super.didUpdateWidget(old);
    if (old.node.value?.now != widget.node.value?.now) _drag = null;
  }

  static String _fmt(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final n = widget.node;
    final v = n.value!;
    final lo = v.min, hi = v.max > v.min ? v.max : v.min + 1;
    final now = (_drag ?? v.now).clamp(lo, hi).toDouble();
    final label = n.label.isEmpty ? l.uiUnnamed : n.label;
    final head = Row(children: [
      Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis)),
      Text(_fmt(now), style: TextStyle(color: t.textSecondary, fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
    if (n.role == 'spin button') {
      final step = v.step > 0 ? v.step : 1.0;
      return Padding(
        padding: EdgeInsets.fromLTRB(widget.indent, 4, 8, 4),
        child: Row(children: [
          Expanded(child: head),
          IconButton(tooltip: l.uiDecrease, icon: const Icon(LucideIcons.minus), onPressed: n.enabled && now > lo ? () => widget.onSet((now - step).clamp(lo, hi).toDouble()) : null),
          IconButton(tooltip: l.uiIncrease, icon: const Icon(LucideIcons.plus), onPressed: n.enabled && now < hi ? () => widget.onSet((now + step).clamp(lo, hi).toDouble()) : null),
        ]),
      );
    }
    final steps = v.step > 0 ? ((hi - lo) / v.step).round() : 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(widget.indent, 8, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ExcludeSemantics(child: head),
        Slider(
          value: now,
          min: lo,
          max: hi,
          divisions: steps > 0 && steps <= 200 ? steps : null,
          label: _fmt(now),
          semanticFormatterCallback: (x) => '$label ${_fmt(x)}',
          onChanged: n.enabled ? (x) => setState(() => _drag = x) : null,
          onChangeEnd: n.enabled ? widget.onSet : null,
        ),
      ]),
    );
  }
}
