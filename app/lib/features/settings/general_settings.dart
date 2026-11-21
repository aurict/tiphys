// Appearance, security, notifications, home screen cards.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/links.dart';
import '../../core/platform.dart';
import '../../core/profile/model.dart';
import '../../core/util/open_url.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../lock/lock_gate.dart';
import '../system/clipboard_sync.dart';
import '../home/shortcuts.dart';
import 'push_section.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final app = ref.watch(profileProvider.select((p) => p.app));
    void set(AppSettings a) => ref.read(profileProvider.notifier).update((p) => p.copyWith(app: a));
    return SettingsPage(title: l.settingsAppearance, children: [
      ChoiceSection<ThemePref>(
        title: l.appearanceTheme,
        value: app.theme,
        options: [
          (ThemePref.system, l.appearanceThemeSystem),
          (ThemePref.light, l.appearanceThemeLight),
          (ThemePref.dark, l.appearanceThemeDark),
        ],
        onChanged: (v) => set(app.copyWith(theme: v)),
      ),
      ChoiceSection<LanguagePref>(
        title: l.appearanceLanguage,
        value: app.language,
        options: [
          (LanguagePref.system, l.appearanceLanguageSystem),
          (LanguagePref.tr, l.appearanceLanguageTr),
          (LanguagePref.en, l.appearanceLanguageEn),
        ],
        onChanged: (v) => set(app.copyWith(language: v)),
      ),
    ]);
  }
}

class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});
  @override
  ConsumerState<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends ConsumerState<SecurityScreen> {
  bool? _hasPin;

  @override
  void initState() {
    super.initState();
    ref.read(appLockProvider).hasPin().then((v) => mounted ? setState(() => _hasPin = v) : null);
  }

  Future<void> _setPin() async {
    final l = AppLocalizations.of(context);
    final a = TextEditingController(), b = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(_hasPin == true ? l.securityPinChange : l.securityPinSet),
        content: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TField(controller: a, label: l.securityPinNew, obscure: true, keyboardType: TextInputType.number, autofocus: true,
                validator: (v) => RegExp(r'^\d{6,12}$').hasMatch(v) ? null : l.securityPinShort),
            const SizedBox(height: 12),
            TField(controller: b, label: l.securityPinRepeat, obscure: true, keyboardType: TextInputType.number,
                validator: (v) => v == a.text ? null : l.profilePassphraseMismatch),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.commonCancel)),
          TextButton(onPressed: () => formKey.currentState!.validate() ? Navigator.pop(c, true) : null, child: Text(l.commonSave)),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(appLockProvider).setPin(a.text);
      ref.invalidate(lockRequiredProvider);
      if (mounted) setState(() => _hasPin = true);
    }
    a.dispose();
    b.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final lock = ref.watch(profileProvider.select((p) => p.app.lock));
    void set(LockSettings s) {
      ref.read(profileProvider.notifier).update((p) => p.copyWith(app: p.app.copyWith(lock: s)));
      ref.invalidate(lockRequiredProvider);
    }

    return SettingsPage(title: l.settingsSecurity, children: [
      GroupedSection(children: [
        SwitchRow(
          title: l.securityBiometric,
          icon: LucideIcons.fingerprint,
          iconBackground: t.success,
          value: lock.biometric,
          onChanged: (v) => set(lock.copyWith(biometric: v)),
        ),
        SwitchRow(
          title: l.securityPin,
          icon: LucideIcons.lock,
          iconBackground: t.accent,
          value: lock.pin,
          onChanged: (v) => set(lock.copyWith(pin: v)),
        ),
        if (lock.pin)
          GroupedRow(
            title: _hasPin == true ? l.securityPinChange : l.securityPinSet,
            icon: LucideIcons.keyRound,
            iconBackground: const Color(0xFF6C6C70),
            onTap: _setPin,
          ),
      ]),
      ChoiceSection<int>(
        title: l.securityAutoLock,
        value: lock.autoLockSeconds,
        options: [for (final s in const [0, 30, 60, 300, 900]) (s, l.securityAutoLockSeconds(s))],
        onChanged: (v) => set(lock.copyWith(autoLockSeconds: v)),
      ),
      GroupedSection(title: l.vaultTitle, footer: l.vaultSecurityFooter, children: [
        GroupedRow(title: l.vaultTitle, subtitle: l.vaultSubtitle, icon: LucideIcons.keySquare, iconBackground: const Color(0xFF5E5CE6), onTap: () => context.push('/vault')),
      ]),
    ]);
  }
}

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final p = ref.watch(profileProvider);
    final n = p.notifications;
    final c = p.claude;
    void setN(NotificationSettings v) => ref.read(profileProvider.notifier).update((p) => p.copyWith(notifications: v));
    void setC(ClaudeSettings v) => ref.read(profileProvider.notifier).update((p) => p.copyWith(claude: v));
    final agentHosts = p.hosts.where((h) => h.agent != null).toList();
    return SettingsPage(title: l.settingsNotifications, children: [
      const PushSection(),
      // Without ntfy (and always on iOS and desktops): the app polls the agents while it is open (live_events.dart).
      GroupedSection(title: l.liveNotifyTitle, footer: hasUnifiedPush ? l.liveNotifyHint : l.liveNotifyHintNoPush, children: [
        GroupedRow(
          title: l.liveNotifyDocs,
          icon: LucideIcons.bookOpen,
          iconBackground: const Color(0xFF5E5CE6),
          external: true,
          onTap: () => openExternal(kDocsNotifications),
        ),
      ]),
      GroupedSection(title: 'Claude', children: [
        SwitchRow(title: l.notifyClaudeDone, value: c.notifyDone, onChanged: (v) => setC(c.copyWith(notifyDone: v))),
        SwitchRow(title: l.notifyClaudeWaiting, value: c.notifyWaiting, onChanged: (v) => setC(c.copyWith(notifyWaiting: v))),
        SwitchRow(title: l.notifyClaudeError, value: c.notifyError, onChanged: (v) => setC(c.copyWith(notifyError: v))),
      ]),
      // Site outages go from Uptime Kuma straight to the ntfy app (the ntfy row above);
      // the disk threshold is set in each host's agent. Neither can be changed from here.
      GroupedSection(title: l.tabSystem, footer: l.notifyAgentSideHint, children: [
        SwitchRow(title: l.notifyPcOffline, value: n.pcOffline, onChanged: (v) => setN(n.copyWith(pcOffline: v))),
        SwitchRow(title: l.notifyServiceDown, value: n.serviceDown, onChanged: (v) => setN(n.copyWith(serviceDown: v))),
        SwitchRow(title: l.notifyGrafana, value: n.grafanaAlerts, onChanged: (v) => setN(n.copyWith(grafanaAlerts: v))),
        SwitchRow(title: l.notifyBackups, value: n.backupAlerts, onChanged: (v) => setN(n.copyWith(backupAlerts: v))),
        SwitchRow(title: l.notifyIncidents, subtitle: l.notifyIncidentsHint, value: n.incidents, onChanged: (v) => setN(n.copyWith(incidents: v))),
      ]),
      // Telegram newsletters (atlas): approval requests and failures; "sent" separately (daily, easy to mute).
      GroupedSection(title: 'Telegram', children: [
        SwitchRow(title: l.notifyTelegramAlerts, subtitle: l.notifyTelegramAlertsHint, value: n.telegramAlerts, onChanged: (v) => setN(n.copyWith(telegramAlerts: v))),
        SwitchRow(title: l.notifyTelegramSent, value: n.telegramSent, onChanged: (v) => setN(n.copyWith(telegramSent: v))),
      ]),
      ChoiceSection<int>(
        title: l.notifyLongCommand,
        value: n.longCommandSeconds,
        options: [
          (0, l.commonOff),
          for (final v in const [30, 60, 300]) (v, l.durationSeconds(v)),
        ],
        onChanged: (v) => setN(n.copyWith(longCommandSeconds: v)),
      ),
      // Clipboard sync: PC → phone silent notification (the agent setting must also be on), phone → PC on foreground.
      GroupedSection(title: l.toolsClipboard, footer: l.clipboardSyncHint, children: [
        SwitchRow(title: l.notifyClipboardFromPc, value: n.clipboardFromPc, onChanged: (v) => setN(n.copyWith(clipboardFromPc: v))),
        SwitchRow(title: l.clipboardSyncToPc, value: n.clipboardToPc, onChanged: (v) => setN(n.copyWith(clipboardToPc: v))),
      ]),
      if (n.clipboardToPc && agentHosts.length > 1)
        ChoiceSection<String?>(
          title: l.clipboardSyncHost,
          value: agentHosts.any((h) => h.id == n.clipboardHostId) ? n.clipboardHostId : null,
          options: [
            (null, l.clipboardHostAuto(clipboardHost(p.copyWith(notifications: n.copyWith(clipboardHostId: () => null)))?.name ?? '')),
            for (final h in agentHosts) (h.id, h.name),
          ],
          onChanged: (v) => setN(n.copyWith(clipboardHostId: () => v)),
        ),
    ]);
  }
}

class HomeCardsScreen extends ConsumerWidget {
  const HomeCardsScreen({super.key});

  String _cardName(AppLocalizations l, String id) => switch (id) {
        'infra' => l.homeCardsInfra,
        'claude' => l.homeCardsClaude,
        'system' => l.homeCardsSystem,
        'grafana' => l.homeCardsGrafana,
        'dozzle' => l.homeCardsDozzle,
        'events' => l.homeCardsEvents,
        'nowPlaying' => l.homeCardsNowPlaying,
        'security' => l.homeCardsSecurity,
        'screenMode' => l.homeCardsScreenMode,
        _ => l.homeCardsQuickAccess,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final app = ref.watch(profileProvider.select((p) => p.app));
    void update(AppSettings Function(AppSettings) f) => ref.read(profileProvider.notifier).update((p) => p.copyWith(app: f(p.app)));
    return SettingsPage(title: l.settingsHome, children: [
      SectionLabel(l.homeLayout),
      TCard(
        padding: EdgeInsets.zero,
        radius: TiphysTokens.radiusList,
        child: Column(children: [
          for (final (i, (v, title, desc)) in [
            (HomeLayout.cards, l.homeLayoutCards, l.homeLayoutCardsDesc),
            (HomeLayout.grid, l.homeLayoutGrid, l.homeLayoutGridDesc),
            (HomeLayout.focus, l.homeLayoutFocus, l.homeLayoutFocusDesc),
          ].indexed) ...[
            if (i > 0) Padding(padding: const EdgeInsets.only(left: 76), child: Divider(color: context.tokens.separator)),
            _LayoutOption(
              layout: v,
              title: title,
              description: desc,
              selected: app.layout == v,
              onTap: () => update((a) => a.copyWith(layout: v)),
            ),
          ],
        ]),
      ),
      SectionLabel(l.homeCardsTitle),
      _ReorderList(
        order: [...app.cards, ...allHomeCards.where((c) => !app.cards.contains(c))],
        enabled: app.cards,
        title: (id) => _cardName(l, id),
        onChanged: (cards) => update((a) => a.copyWith(cards: cards)),
      ),
      if (app.cards.contains('security')) ...[
        SectionLabel(l.secStyleTitle),
        TCard(
          padding: EdgeInsets.zero,
          radius: TiphysTokens.radiusList,
          child: Column(children: [
            for (final (i, (v, title, desc)) in [
              (SecurityStyle.shield, l.secStyleShield, l.secStyleShieldDesc),
              (SecurityStyle.rings, l.secStyleRings, l.secStyleRingsDesc),
              (SecurityStyle.bars, l.secStyleBars, l.secStyleBarsDesc),
            ].indexed) ...[
              if (i > 0) Padding(padding: const EdgeInsets.only(left: 76), child: Divider(color: context.tokens.separator)),
              _StyleOption(
                style: v,
                title: title,
                description: desc,
                selected: app.securityStyle == v,
                onTap: () => update((a) => a.copyWith(securityStyle: v)),
              ),
            ],
          ]),
        ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(l.homeCardsLayoutNote, style: Theme.of(context).textTheme.bodySmall),
      ),
      SectionLabel(l.homeShortcuts),
      _ReorderList(
        order: [...app.shortcuts.where(allShortcuts.contains), ...allShortcuts.where((c) => !app.shortcuts.contains(c))],
        enabled: app.shortcuts,
        title: (id) => shortcutLabel(l, id),
        icon: (id) => (shortcutIcon(id), shortcutColor(context.tokens, id)),
        subtitle: (id) => shortcutMissing(ref, l, id),
        onChanged: (s) => update((a) => a.copyWith(shortcuts: s)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(l.homeShortcutsFooter, style: Theme.of(context).textTheme.bodySmall),
      ),
    ]);
  }
}

/// List with on/off switches, sorted by drag handle (cards and shortcuts). [onChanged] gives only the enabled
/// ones in their new order.
class _ReorderList extends StatelessWidget {
  const _ReorderList({required this.order, required this.enabled, required this.title, required this.onChanged, this.icon, this.subtitle});
  final List<String> order;
  final List<String> enabled;
  final String Function(String id) title;
  final (IconData, Color) Function(String id)? icon;
  final String? Function(String id)? subtitle;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return TCard(
      padding: EdgeInsets.zero,
      radius: TiphysTokens.radiusList,
      child: ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorderItem: (a, b) {
          final list = [...order];
          final item = list.removeAt(a);
          list.insert(b, item);
          onChanged(list.where(enabled.contains).toList());
        },
        children: [
          for (var i = 0; i < order.length; i++)
            ListTile(
              key: ValueKey(order[i]),
              title: Row(children: [
                if (icon != null) ...[
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(color: icon!(order[i]).$2, borderRadius: BorderRadius.circular(9)),
                    child: Icon(icon!(order[i]).$1, size: 17, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title(order[i]), style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (subtitle?.call(order[i]) case final s?)
                      Text(s, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.warning), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ]),
                ),
              ]),
              leading: Switch(
                value: enabled.contains(order[i]),
                onChanged: (on) => onChanged(on
                    ? order.where((c) => enabled.contains(c) || c == order[i]).toList()
                    : enabled.where((c) => c != order[i]).toList()),
              ),
              trailing: ReorderableDragStartListener(
                index: i,
                child: Padding(padding: const EdgeInsets.all(8), child: Icon(LucideIcons.gripVertical, color: t.textSecondary)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Layout option: small diagram + name + one-line description; the selected one is checked (screen reader says
/// "selected").
class _LayoutOption extends StatelessWidget {
  const _LayoutOption({required this.layout, required this.title, required this.description, required this.selected, required this.onTap});
  final HomeLayout layout;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '$title, $description',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
              child: Row(children: [
                _LayoutSketch(layout: layout, selected: selected),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: tt.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(description, style: tt.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                const SizedBox(width: 8),
                Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    size: 22, color: selected ? t.accent : t.textSecondary),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small diagram of the layout (48×60): blocks on top and cards below.
class _LayoutSketch extends StatelessWidget {
  const _LayoutSketch({required this.layout, required this.selected});
  final HomeLayout layout;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = selected ? t.accent : t.textSecondary;
    Widget box(double h, {double? w, double alpha = 0.35}) =>
        Container(width: w, height: h, decoration: BoxDecoration(color: ink.withValues(alpha: alpha), borderRadius: BorderRadius.circular(2.5)));
    Widget row(List<Widget> c) => Row(children: [for (var i = 0; i < c.length; i++) ...[if (i > 0) const SizedBox(width: 3), Expanded(child: c[i])]]);
    const g = SizedBox(height: 3);
    final children = switch (layout) {
      HomeLayout.cards => [box(12, alpha: 0.55), g, row([box(9), box(9)]), g, row([box(6), box(6)]), g, box(8)],
      HomeLayout.grid => [box(7, alpha: 0.55), g, row([box(9), box(9), box(9)]), g, row([box(9), box(9), box(9)]), g, box(8)],
      HomeLayout.focus => [box(14, alpha: 0.55), g, box(4), g, box(4), g, box(4), g, box(6)],
    };
    return Container(
      width: 48,
      height: 60,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: t.chipBackground,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: selected ? t.accent : t.separator, width: selected ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

/// Security card style option: static mini-preview + name + one-line description (same look as [_LayoutOption]).
class _StyleOption extends StatelessWidget {
  const _StyleOption({required this.style, required this.title, required this.description, required this.selected, required this.onTap});
  final SecurityStyle style;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '$title, $description',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
              child: Row(children: [
                Container(
                  width: 48,
                  height: 60,
                  decoration: BoxDecoration(
                    color: t.chipBackground,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: selected ? t.accent : t.separator, width: selected ? 1.5 : 1),
                  ),
                  child: CustomPaint(painter: _StyleSketchPainter(style, selected ? t.accent : t.textSecondary)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: tt.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(description, style: tt.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                const SizedBox(width: 8),
                Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    size: 22, color: selected ? t.accent : t.textSecondary),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mini-preview (48×60) of a Security card style: a shield, three score rings or three bullet bars.
class _StyleSketchPainter extends CustomPainter {
  _StyleSketchPainter(this.style, this.ink);
  final SecurityStyle style;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = ink.withValues(alpha: 0.35);
    final strong = Paint()..color = ink.withValues(alpha: 0.7);
    switch (style) {
      case SecurityStyle.shield:
        final c = size.width / 2;
        final left = Path()
          ..moveTo(c, 11)
          ..lineTo(c - 14, 16)
          ..lineTo(c - 14, 31)
          ..quadraticBezierTo(c - 13, 43, c, 50)
          ..close();
        final right = Path()
          ..moveTo(c, 11)
          ..lineTo(c + 14, 16)
          ..lineTo(c + 14, 31)
          ..quadraticBezierTo(c + 13, 43, c, 50)
          ..close();
        canvas.drawPath(left, strong);
        canvas.drawPath(right, fill);
      case SecurityStyle.rings:
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < 3; i++) {
          final r = Rect.fromCenter(center: Offset(size.width / 2, 14.0 + 16 * i), width: 12, height: 12);
          canvas.drawArc(r, 0, 6.2832, false, ring..color = ink.withValues(alpha: 0.2));
          canvas.drawArc(r, -1.5708, 6.2832 * (0.9 - 0.2 * i), false, ring..color = ink.withValues(alpha: 0.75));
        }
      case SecurityStyle.bars:
        for (var i = 0; i < 3; i++) {
          final y = 13.0 + 15 * i;
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(7, y, 34, 5), const Radius.circular(2.5)), fill);
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(7 + 34 * (0.85 - 0.25 * i) - 1.5, y - 2, 3, 9), const Radius.circular(1.5)), strong);
        }
    }
  }

  @override
  bool shouldRepaint(_StyleSketchPainter o) => o.style != style || o.ink != ink;
}
