// Shared pieces for settings forms: page scaffold, text field, choice rows, confirm dialog.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'surfaces.dart';

/// Settings subpages: header with back button + scrollable content + optional save button.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.children, this.onSave, this.saving = false, this.actions, this.onRefresh, this.backEnabled = true, this.bottomBar});
  final String title;
  final List<Widget> children;
  final Future<void> Function()? onSave;
  final bool saving;
  final List<Widget>? actions;

  /// false: the back arrow does nothing (an operation whose result would be lost is in flight).
  final bool backEnabled;

  /// Pull to refresh (optional).
  final Future<void> Function()? onRefresh;

  /// Pinned under the list (e.g. the action bar of a multi-select).
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      bottomNavigationBar: bottomBar,
      body: AmbientBackground(
        child: _refreshable(CustomScrollView(physics: onRefresh == null ? null : const AlwaysScrollableScrollPhysics(), slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: context.tokens.isDark ? const Color(0xCC000000) : context.tokens.background,
            title: Text(title),
            leading: IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              icon: const Icon(LucideIcons.chevronLeft),
              onPressed: backEnabled ? () => context.canPop() ? context.pop() : context.go('/settings') : null,
            ),
            actions: [
              ...?actions,
              if (onSave != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TextButton(
                    onPressed: saving ? null : onSave,
                    child: saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l.commonSave),
                  ),
                ),
            ],
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(TiphysTokens.gutter, 4, TiphysTokens.gutter, MediaQuery.paddingOf(context).bottom + 40),
            sliver: SliverList.list(children: children),
          ),
        ])),
      ),
    );
  }

  Widget _refreshable(Widget scroll) => onRefresh == null ? scroll : RefreshIndicator(onRefresh: onRefresh!, child: scroll);
}

/// Labeled text field inside a card.
class FieldCard extends StatelessWidget {
  const FieldCard({super.key, required this.children, this.title});
  final List<Widget> children;
  final String? title;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null) SectionLabel(title!),
        TCard(
          radius: TiphysTokens.radiusList,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
          child: Column(children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 10), child: c)]),
        ),
      ]);
}

class TField extends StatelessWidget {
  const TField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.validator,
    this.keyboardType,
    this.obscure = false,
    this.mono = false,
    this.maxLines = 1,
    this.enabled = true,
    this.helper,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final String? Function(String)? validator;
  final TextInputType? keyboardType;
  final bool obscure;
  final bool mono;
  final int maxLines;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        enabled: enabled,
        autofocus: autofocus,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: !obscure && !mono,
        // Ligatures off: so "!=" in code doesn't render as ≠.
        style: mono
            ? const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, fontFeatures: [FontFeature.disable('calt'), FontFeature.disable('liga')])
            : null,
        decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3),
        validator: validator == null ? null : (v) => validator!(v ?? ''),
        autovalidateMode: AutovalidateMode.onUserInteraction,
      );
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, required this.value, required this.onChanged, this.subtitle, this.icon, this.iconBackground});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;
  final Color? iconBackground;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: GroupedRow(
          title: title,
          subtitle: subtitle,
          icon: icon,
          iconBackground: iconBackground,
          onTap: () => onChanged(!value),
          trailing: Switch(value: value, onChanged: onChanged),
        ),
      );
}

/// One of several options (like a radio) — iOS-style rows with a checkmark.
class ChoiceSection<T> extends StatelessWidget {
  const ChoiceSection({super.key, this.title, required this.options, required this.value, required this.onChanged});
  final String? title;
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => GroupedSection(title: title, children: [
        for (final (v, label) in options)
          Semantics(
            inMutuallyExclusiveGroup: true,
            checked: v == value,
            child: GroupedRow(
              title: label,
              onTap: () => onChanged(v),
              trailing: v == value ? Icon(LucideIcons.check, size: 20, color: context.tokens.accent) : const SizedBox(width: 20),
            ),
          ),
      ]);
}

Future<bool> confirmDialog(BuildContext context, {required String message, String? confirmLabel, bool destructive = false}) async {
  final l = AppLocalizations.of(context);
  final t = context.tokens;
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      content: Text(message, style: Theme.of(c).textTheme.bodyLarge),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.commonCancel)),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          style: TextButton.styleFrom(foregroundColor: destructive ? t.danger : t.accent),
          child: Text(confirmLabel ?? l.commonConfirm),
        ),
      ],
    ),
  );
  return r ?? false;
}

void toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(message)));

// Validators
String? Function(String) requiredV(AppLocalizations l) => (v) => v.trim().isEmpty ? l.commonRequired : null;
String? Function(String) idV(AppLocalizations l) =>
    (v) => RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(v) ? null : l.hostIdHint;
String? Function(String) urlV(AppLocalizations l) => (v) {
      final u = Uri.tryParse(v.trim());
      return u != null && (u.isScheme('http') || u.isScheme('https')) && u.host.isNotEmpty ? null : 'https://…';
    };
String? Function(String) intV(int min, int max) => (v) {
      final n = int.tryParse(v);
      return n != null && n >= min && n <= max ? null : '$min–$max';
    };

/// Id suggestion: name → kebab-case (Turkish letters are simplified).
String slugify(String s) {
  const map = {'ç': 'c', 'ğ': 'g', 'ı': 'i', 'İ': 'i', 'ö': 'o', 'ş': 's', 'ü': 'u', 'Ç': 'c', 'Ğ': 'g', 'Ö': 'o', 'Ş': 's', 'Ü': 'u'};
  final out = s.split('').map((c) => map[c] ?? c).join().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  final trimmed = out.replaceAll(RegExp(r'^-+|-+$'), '');
  return trimmed.length > 63 ? trimmed.substring(0, 63) : trimmed;
}
