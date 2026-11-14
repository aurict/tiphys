// Görünüm, güvenlik, bildirimler, ana ekran kartları.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../lock/lock_gate.dart';
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
    return SettingsPage(title: l.settingsNotifications, children: [
      const PushSection(),
      GroupedSection(title: 'Claude', children: [
        SwitchRow(title: l.notifyClaudeDone, value: c.notifyDone, onChanged: (v) => setC(c.copyWith(notifyDone: v))),
        SwitchRow(title: l.notifyClaudeWaiting, value: c.notifyWaiting, onChanged: (v) => setC(c.copyWith(notifyWaiting: v))),
        SwitchRow(title: l.notifyClaudeError, value: c.notifyError, onChanged: (v) => setC(c.copyWith(notifyError: v))),
      ]),
      GroupedSection(title: l.tabSystem, children: [
        SwitchRow(title: l.notifySiteDown, value: n.siteDown, onChanged: (v) => setN(n.copyWith(siteDown: v))),
        SwitchRow(title: l.notifyPcOffline, value: n.pcOffline, onChanged: (v) => setN(n.copyWith(pcOffline: v))),
        SwitchRow(title: l.notifyServiceDown, value: n.serviceDown, onChanged: (v) => setN(n.copyWith(serviceDown: v))),
        SwitchRow(title: l.notifyGrafana, value: n.grafanaAlerts, onChanged: (v) => setN(n.copyWith(grafanaAlerts: v))),
      ]),
      ChoiceSection<int>(
        title: l.notifyDiskFull,
        value: n.diskFullPercent,
        options: [for (final v in const [80, 90, 95]) (v, '%$v')],
        onChanged: (v) => setN(n.copyWith(diskFullPercent: v)),
      ),
      ChoiceSection<int>(
        title: l.notifyLongCommand,
        value: n.longCommandSeconds,
        options: [
          (0, l.commonOff),
          for (final v in const [30, 60, 300]) (v, l.durationSeconds(v)),
        ],
        onChanged: (v) => setN(n.copyWith(longCommandSeconds: v)),
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
        _ => l.homeCardsQuickAccess,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final app = ref.watch(profileProvider.select((p) => p.app));
    final order = [...app.cards, ...allHomeCards.where((c) => !app.cards.contains(c))];
    void save(List<String> cards) =>
        ref.read(profileProvider.notifier).update((p) => p.copyWith(app: p.app.copyWith(cards: cards)));
    return SettingsPage(title: l.settingsHome, children: [
      SectionLabel(l.settingsHomeHint),
      TCard(
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
            save(list.where(app.cards.contains).toList());
          },
          children: [
            for (var i = 0; i < order.length; i++)
              ListTile(
                key: ValueKey(order[i]),
                title: Text(_cardName(l, order[i]), style: Theme.of(context).textTheme.titleMedium),
                leading: Switch(
                  value: app.cards.contains(order[i]),
                  onChanged: (on) => save(on
                      ? order.where((c) => app.cards.contains(c) || c == order[i]).toList()
                      : app.cards.where((c) => c != order[i]).toList()),
                ),
                trailing: ReorderableDragStartListener(
                  index: i,
                  child: Padding(padding: const EdgeInsets.all(8), child: Icon(LucideIcons.gripVertical, color: t.textSecondary)),
                ),
              ),
          ],
        ),
      ),
    ]);
  }
}
