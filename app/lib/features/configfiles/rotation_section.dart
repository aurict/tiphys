// "Yenilenmesi gerekenler" (PLAN.md §13.3, C-2): the secrets of every host with the `configfiles` feature that have a
// rotation limit, overdue ones first, with their age against the limit. Tap → the file screen focused on the key; the
// timer button sets or clears the limit of one key (90 days suggested). Key names and ages only, never values.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'configfiles_data.dart';
import 'configfiles_screen.dart' show configFileRoute;

class RotationSection extends ConsumerWidget {
  const RotationSection({super.key, required this.showHost});

  /// More than one host is listed: rows say which host a file is on.
  final bool showHost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final async = ref.watch(rotationProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(l.cfRotationTitle),
      async.when(
        skipLoadingOnRefresh: true,
        loading: () => const TCard(child: Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))),
        error: (e, _) => TCard(child: Text(agentErrorText(l, e))),
        data: (feed) {
          final tracked = feed.withPolicy, untracked = feed.withoutPolicy;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (tracked.isEmpty)
              TCard(child: Text(l.cfRotationEmpty))
            else
              TCard(
                padding: EdgeInsets.zero,
                radius: TiphysTokens.radiusList,
                child: Column(children: [
                  for (var i = 0; i < tracked.length; i++) ...[
                    if (i > 0) Divider(color: t.separator, height: 1),
                    RotationRow(item: tracked[i], showHost: showHost),
                  ],
                ]),
              ),
            if (untracked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TCard(
                  padding: EdgeInsets.zero,
                  radius: TiphysTokens.radiusList,
                  child: Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                      leading: Icon(LucideIcons.timerOff, size: 20, color: t.textSecondary),
                      title: Text(l.cfRotationNoPolicy(untracked.length), style: Theme.of(context).textTheme.titleMedium),
                      childrenPadding: EdgeInsets.zero,
                      children: [
                        for (final i in untracked) ...[
                          Divider(color: t.separator, height: 1),
                          RotationRow(item: i, showHost: showHost),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            for (final MapEntry(key: id, value: e) in feed.errors.entries)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(l.cfRotationHostError(id, agentErrorText(l, e)), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.danger)),
              ),
          ]);
        },
      ),
    ]);
  }
}

class RotationRow extends ConsumerWidget {
  const RotationRow({super.key, required this.item, required this.showHost});
  final RotationItem item;
  final bool showHost;

  Future<void> _set(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final r = await showDialog<({int? days})>(context: context, builder: (_) => _LimitDialog(item: item));
    if (r == null || !context.mounted) return;
    try {
      await agentCall(ref, item.host.id, 'PUT', '/v1/secrets/meta', {
        'updates': [
          {'fileId': item.fileId, 'key': item.key, 'maxAgeDays': r.days},
        ],
      });
      ref.invalidate(rotationProvider);
      ref.invalidate(configFilesProvider(item.host.id));
      ref.invalidate(configFileProvider((item.host.id, item.fileId)));
      if (context.mounted) toast(context, l.cfRotationUpdated);
    } catch (e) {
      if (context.mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final over = item.overdue;
    final chip = !item.hasPolicy
        ? (item.ageDays == null ? l.cfRotationUnknownAge : l.cfRotationAgeOnly(item.ageDays!))
        : over
            ? l.cfRotationOverdue(item.overdueDays != null && item.overdueDays! > 0 ? item.overdueDays! : 0)
            : (item.overdueDays == null ? l.cfRotationAge(0, item.maxAgeDays!) : l.cfRotationLeft(-item.overdueDays!));
    final color = over ? t.danger : t.textSecondary;
    return InkWell(
      onTap: () => context.push(configFileRoute(item.host.id, item.fileId, key: item.key)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Padding(padding: const EdgeInsets.only(right: 10), child: Icon(over ? LucideIcons.triangleAlert : LucideIcons.lock, size: 18, color: over ? t.danger : t.accent)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.key, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: monoFamily, fontSize: 13.5, fontWeight: FontWeight.w700, color: t.text)),
              Text([if (showHost) item.host.name, item.file].join(' · '), overflow: TextOverflow.ellipsis, style: tt.bodySmall),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
                    child: Text(chip, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  if (item.hasPolicy && item.ageDays != null) Text(l.cfRotationAge(item.ageDays!, item.maxAgeDays!), style: tt.bodySmall),
                ]),
              ),
            ]),
          ),
          IconButton(tooltip: l.cfRotationSetTooltip, icon: const Icon(LucideIcons.timer, size: 20), onPressed: () => _set(context, ref)),
        ]),
      ),
    );
  }
}

/// Set or clear the rotation limit of one key. Returns `(days: n)` or `(days: null)` for "no reminder"; null = cancelled.
class _LimitDialog extends StatefulWidget {
  const _LimitDialog({required this.item});
  final RotationItem item;
  @override
  State<_LimitDialog> createState() => _LimitDialogState();
}

class _LimitDialogState extends State<_LimitDialog> {
  late final _days = TextEditingController(text: widget.item.maxAgeDays?.toString() ?? '');

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  int? get _parsed => int.tryParse(_days.text.trim());
  bool get _valid => _days.text.trim().isEmpty || (_parsed != null && _parsed! >= 1 && _parsed! <= 3650);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.cfMaxAgeTitle),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.item.key, style: TextStyle(fontFamily: monoFamily, fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        TextField(
          controller: _days,
          autofocus: true,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: l.cfMaxAgeDays, errorText: _valid ? null : l.cfMaxAgeInvalid, helperText: l.cfMaxAgeHelp, helperMaxLines: 3),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          ActionChip(label: Text(l.cfMaxAgeSuggest(suggestedMaxAgeDays)), onPressed: () => setState(() => _days.text = '$suggestedMaxAgeDays')),
          if (_days.text.isNotEmpty) ActionChip(label: Text(l.cfMaxAgeClear), onPressed: () => setState(_days.clear)),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(onPressed: _valid ? () => Navigator.pop(context, (days: _parsed)) : null, child: Text(l.commonSave)),
      ],
    );
  }
}
