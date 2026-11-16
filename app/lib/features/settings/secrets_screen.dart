// Keys and passwords: the state of every secret the profile references (saved / missing).
// Values are never shown; only a new value can be entered or deleted.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/push/push_service.dart' show pcControlSecretId;
import '../../core/vault/vault.dart' show vaultSecretId;
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../ssh/ssh_keys_section.dart';

/// Where the secret is used (e.g. "atlas · SSH").
Map<String, List<String>> secretUsages(Profile p) {
  final m = <String, List<String>>{};
  void add(String ref, String where) => m.putIfAbsent(secretIdOf(ref), () => []).add(where);
  for (final h in p.hosts) {
    if (h.ssh != null) add(h.ssh!.auth.ref, '${h.name} · SSH');
    if (h.agent != null) add(h.agent!.tokenRef, '${h.name} · agent');
  }
  for (final g in p.integrations.grafana) {
    if (g.tokenRef != null) add(g.tokenRef!, g.name);
  }
  for (final d in p.integrations.dozzle) {
    if (d.passwordRef != null) add(d.passwordRef!, d.name);
  }
  return m;
}

class SecretsScreen extends ConsumerWidget {
  const SecretsScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, String id, {required bool multiline}) async {
    final l = AppLocalizations.of(context);
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(id, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TField(controller: c, label: l.secretValue, obscure: !multiline, mono: true, maxLines: multiline ? 6 : 1, autofocus: true),
          const SizedBox(height: 8),
          Text(l.secretStoredSafely, style: Theme.of(d).textTheme.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(l.commonCancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(l.commonSave)),
        ],
      ),
    );
    if (ok == true && c.text.isNotEmpty) {
      await ref.read(secretStoreProvider).write(id, c.text);
      ref.invalidate(secretIdsProvider);
    }
    c.dispose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final p = ref.watch(profileProvider);
    final stored = ref.watch(secretIdsProvider).value ?? const <String>{};
    final usages = secretUsages(p);
    final keyIds = p.keys.map((k) => k.id).toSet();
    // The password vault is a single secret entry; not shown here (overwriting/deleting it would lose the whole vault).
    final ids = {...usages.keys, ...stored}.where((id) => !keyIds.contains(id) && id != vaultSecretId && id != pcControlSecretId).toList()..sort();
    return SettingsPage(title: l.settingsKeys, children: [
      const SshKeysSection(),
      if (ids.isNotEmpty)
        GroupedSection(title: l.keysTokens, footer: l.secretStoredSafely, children: [
          for (final id in ids)
            GroupedRow(
              title: id,
              subtitle: usages[id]?.join(', ') ?? l.secretUnused,
              icon: stored.contains(id) ? LucideIcons.check : LucideIcons.circleAlert,
              iconBackground: stored.contains(id) ? t.success : t.warning,
              trailingText: stored.contains(id) ? null : l.secretNeedsValue,
              onTap: () => _edit(context, ref, id, multiline: false),
              trailing: stored.contains(id) && !usages.containsKey(id)
                  ? IconButton(
                      tooltip: l.commonDelete,
                      icon: Icon(LucideIcons.trash2, color: t.danger, size: 20),
                      onPressed: () async {
                        await ref.read(secretStoreProvider).delete(id);
                        ref.invalidate(secretIdsProvider);
                      },
                    )
                  : null,
            ),
        ])
      else
        Padding(padding: const EdgeInsets.all(24), child: Text(l.keysEmpty, textAlign: TextAlign.center)),
    ]);
  }
}
